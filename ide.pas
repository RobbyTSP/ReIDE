program CustomIDE;

{$mode objfpc}{$H+}
{$linklib c}
{$linklib X11}

uses
  xlib, x, xutil, keysym,
  baseunix, unix,
  classes, sysutils, math,
  font;

const
  libhighlighter = 'highlighter';

// Rust highlighter bindings
function detect_language(filename: PChar): Cardinal; cdecl; external libhighlighter name 'detect_language';
function get_language_icon(lang_id: Cardinal): PChar; cdecl; external libhighlighter name 'get_language_icon';
procedure tokenize_line(lang_id: Cardinal; line: PChar; colors: PByte; max_len: Cardinal); cdecl; external libhighlighter name 'tokenize_line';
function detect_language_from_content(content: PChar): Cardinal; cdecl; external libhighlighter name 'detect_language_from_content';

// libc terminal helpers
function posix_openpt(flags: Integer): Integer; cdecl; external 'c' name 'posix_openpt';
function grantpt(fd: Integer): Integer; cdecl; external 'c' name 'grantpt';
function unlockpt(fd: Integer): Integer; cdecl; external 'c' name 'unlockpt';
function ptsname(fd: Integer): PChar; cdecl; external 'c' name 'ptsname';
function setenv(name, value: PChar; overwrite: Integer): Integer; cdecl; external 'c' name 'setenv';

var
  // Window metrics (variables for resizability)
  WINDOW_WIDTH: Integer = 1024;
  WINDOW_HEIGHT: Integer = 768;
  
  TAB_BAR_HEIGHT: Integer = 40;
  EDITOR_HEIGHT: Integer = 480;
  SEPARATOR_HEIGHT: Integer = 6;
  TERMINAL_HEIGHT: Integer = 242; // Remainder (768 - 40 - 480 - 6)

  // Layout positions
  EDITOR_Y: Integer = 40;
  TERMINAL_Y: Integer = 526; // (40 + 480 + 6)

const
  // Colors (ARGB / XRGB format)
  COLOR_BG_DARK     = $141414; // Editor & window background
  COLOR_TAB_BG      = $0D0D0D; // Deep dark tab bar
  COLOR_TAB_ACTIVE  = $1E1E1E; // Muted dark for active tab
  COLOR_TERM_BG     = $080808; // Pure dark for terminal
  COLOR_TEXT_MUTED  = $5A5A5A; // Gutter / line numbers
  COLOR_CURSOR      = $A0A0A0;
  COLOR_SELECTION   = $264F78;

  // Token colors (from Rust libhighlighter token categories)
  COLOR_TOKEN_DEFAULT    = $D4D4D4; // Light gray
  COLOR_TOKEN_KEYWORD    = $569CD6; // Light blue
  COLOR_TOKEN_IDENTIFIER = $E0E0E0; // Soft white
  COLOR_TOKEN_COMMENT    = $6A9955; // Muted green
  COLOR_TOKEN_STRING     = $CE9178; // Apricot/orange
  COLOR_TOKEN_NUMBER     = $B5CEA8; // Light green/yellow
  COLOR_TOKEN_TYPE       = $4EC9B0; // Mint green
  COLOR_TOKEN_VARIABLE   = $9CDCFE; // Light blue-cyan

  // Token color IDs from Rust
  COL_DEFAULT    = 0;
  COL_KEYWORD    = 1;
  COL_IDENTIFIER = 2;
  COL_COMMENT    = 3;
  COL_STRING     = 4;
  COL_NUMBER     = 5;
  COL_TYPE       = 6;
  COL_VARIABLE   = 7;

type
  TTab = record
    FileName: String;
    FullPath: String;
    LangId: Cardinal;
    Lines: TStringList;
    CursorCol: Integer;
    CursorRow: Integer;
    ScrollCol: Integer;
    ScrollRow: Integer;
    Modified: Boolean;
  end;

  TTerminal = record
    MasterFd: Integer;
    ChildPid: TPId;
    CursorX, CursorY: Integer;
    Grid: array[0..59, 0..249] of Char;
    Colors: array[0..59, 0..249] of Byte; // ANSI color index
    CurrentColor: Byte;
    AnsiState: Integer;
    AnsiParam: String;
  end;

var
  // X11 Handles
  Dis: PDisplay;
  Win: TWindow;
  GcHandle: TGC;
  Img: PXImage = nil;
  FrameBuffer: PDWORD = nil; // Screen buffer pixels
  
  ScreenHandle: Integer;
  VisualHandle: PVisual;
  DepthVal: Integer;

  // State
  Tabs: array[0..15] of TTab;
  ActiveTab: Integer = -1;
  TabCount: Integer = 0;
  
  FocusEditor: Boolean = True; // True: Editor, False: Terminal

  // Terminal PTY variables
  Terminals: array[0..3] of TTerminal;
  ActiveTerm: Integer = 0; // 0..3: PTY terminals, 4: Logs / Debugger panel
  TermCount: Integer = 0;

  TermRows: Integer = 15;
  TermCols: Integer = 124;

  // Command prompt state for opening/saving files
  PromptActive: Boolean = False;
  PromptMode: Integer = 0; // 0 = Open, 1 = Save As, 2 = Search, 3 = Unsaved Warning
  PromptText: String = '';
  ClosingTabIdx: Integer = -1;

  // Logging variables
  LogFilePath: String = '';
  Logs: array[0..49] of String;
  LogsCount: Integer = 0;

  // Plugin Manager variables
  PluginFiles: array[0..15] of String;
  PluginCount: Integer = 0;
  PluginMenuOpen: Boolean = False;
  ActivePluginIdx: Integer = -1;

procedure TriggerLiveLanguageDetection; forward;

// Log writer that pushes to ~/.reide/logs/ide.log and in-memory circular buffer
procedure AddLog(const Msg: String);
var
  f: TextFile;
  FormattedMsg: String;
  i: Integer;
begin
  FormattedMsg := FormatDateTime('yyyy-mm-dd hh:nn:ss', Now) + ' ' + Msg;

  // Write to memory circular list
  if LogsCount < 50 then
  begin
    Logs[LogsCount] := FormattedMsg;
    Inc(LogsCount);
  end
  else
  begin
    for i := 0 to 48 do
      Logs[i] := Logs[i + 1];
    Logs[49] := FormattedMsg;
  end;

  // Append to system logs file
  if LogFilePath <> '' then
  begin
    try
      AssignFile(f, LogFilePath);
      if FileExists(LogFilePath) then
        Append(f)
      else
        Rewrite(f);
      WriteLn(f, FormattedMsg);
      CloseFile(f);
    except
      // ignore
    end;
  end;
end;

// Scans ~/.reide/plugins/ for any raw .asm files
procedure ScanPlugins;
var
  SR: TSearchRec;
  PluginsFolder: String;
begin
  PluginCount := 0;
  PluginsFolder := GetEnvironmentVariable('HOME');
  if PluginsFolder = '' then PluginsFolder := '/home/robby';
  PluginsFolder += '/.reide/plugins/';
  
  if FindFirst(PluginsFolder + '*.asm', faAnyFile, SR) = 0 then
  begin
    repeat
      if (SR.Name <> '.') and (SR.Name <> '..') then
      begin
        PluginFiles[PluginCount] := SR.Name;
        Inc(PluginCount);
        if PluginCount >= 16 then Break;
      end;
    until FindNext(SR) <> 0;
    FindClose(SR);
  end;
  AddLog('[INFO] Scanned plugins folder, found ' + IntToStr(PluginCount) + ' assembly plugins');
end;

// Compiles and runs the selected assembly plugin as a Unix stdout pipe filter
procedure RunAssemblyPlugin(Idx: Integer);
var
  PluginsFolder, BaseName, AsmPath, ObjPath, BinPath: String;
  Cmd: String;
  Res: Integer;
  TempInPath, TempOutPath: String;
  SList: TStringList;
begin
  if (ActiveTab < 0) or (ActiveTab >= TabCount) then Exit;
  if (Idx < 0) or (Idx >= PluginCount) then Exit;

  PluginsFolder := GetEnvironmentVariable('HOME');
  if PluginsFolder = '' then PluginsFolder := '/home/robby';
  PluginsFolder += '/.reide/plugins/';

  BaseName := ChangeFileExt(PluginFiles[Idx], '');
  AsmPath := PluginsFolder + PluginFiles[Idx];
  ObjPath := PluginsFolder + BaseName + '.o';
  BinPath := PluginsFolder + BaseName;

  // Compile if missing or if the source file is newer
  if (not FileExists(BinPath)) or (FileAge(AsmPath) > FileAge(BinPath)) then
  begin
    AddLog('[INFO] Compiling assembly plugin: ' + PluginFiles[Idx]);
    Cmd := 'nasm -f elf64 -o ' + ObjPath + ' ' + AsmPath + ' && ld -o ' + BinPath + ' ' + ObjPath;
    Res := fpsystem(Cmd);
    if Res <> 0 then
    begin
      AddLog('[ERROR] Assembly compilation failed with exit code: ' + IntToStr(Res));
      Exit;
    end;
    AddLog('[INFO] Compilation successful: ' + BinPath);
  end;

  // Execute binary using temporary stdin/stdout redirection files
  TempInPath := '/tmp/reide_plugin_in.txt';
  TempOutPath := '/tmp/reide_plugin_out.txt';

  try
    Tabs[ActiveTab].Lines.SaveToFile(TempInPath);
    
    Cmd := BinPath + ' < ' + TempInPath + ' > ' + TempOutPath;
    Res := fpsystem(Cmd);
    if Res <> 0 then
    begin
      AddLog('[ERROR] Assembly plugin run failed with exit code: ' + IntToStr(Res));
      Exit;
    end;

    SList := TStringList.Create;
    try
      SList.LoadFromFile(TempOutPath);
      Tabs[ActiveTab].Lines.Clear;
      Tabs[ActiveTab].Lines.AddStrings(SList);
      Tabs[ActiveTab].Modified := True;
      AddLog('[INFO] Executed plugin: ' + BaseName + ' on ' + Tabs[ActiveTab].FileName);
      TriggerLiveLanguageDetection;
    finally
      SList.Free;
    end;
  except
    on E: Exception do
      AddLog('[ERROR] Plugin filtering failed: ' + E.Message);
  end;

  DeleteFile(TempInPath);
  DeleteFile(TempOutPath);
end;

// Helper to fill rectangle in our virtual framebuffer
procedure FillRect(X, Y, W, H: Integer; Color: DWORD);
var
  i, j: Integer;
  RowPtr: PDWORD;
begin
  if X < 0 then begin W += X; X := 0; end;
  if Y < 0 then begin H += Y; Y := 0; end;
  if X + W > WINDOW_WIDTH then W := WINDOW_WIDTH - X;
  if Y + H > WINDOW_HEIGHT then H := WINDOW_HEIGHT - Y;
  if (W <= 0) or (H <= 0) then Exit;

  for j := Y to Y + H - 1 do
  begin
    RowPtr := FrameBuffer + (j * WINDOW_WIDTH) + X;
    for i := 0 to W - 1 do
      RowPtr[i] := Color;
  end;
end;

// Draws string using our custom assembly routine
procedure DrawString(X, Y: Integer; const S: String; Color: DWORD);
var
  i: Integer;
  CharX: Integer;
begin
  for i := 1 to Length(S) do
  begin
    CharX := X + (i - 1) * FONT_WIDTH;
    DrawCharASM(FrameBuffer, WINDOW_WIDTH * 4, CharX, Y, Byte(S[i]), Color);
  end;
end;

// ANSI Terminal coloring mappings
function GetTermColorVal(AnsiCode: Byte): DWORD;
begin
  case AnsiCode of
    0, 30: Result := $303030; // Black
    31: Result := $F44747; // Red
    32: Result := $6A9955; // Green
    33: Result := $DCDCAA; // Yellow
    34: Result := $569CD6; // Blue
    35: Result := $C586C0; // Magenta
    36: Result := $4EC9B0; // Cyan
    37, 7: Result := $D4D4D4; // Light Gray
    90: Result := $808080; // Gray
    91: Result := $FF6666; // Light Red
    92: Result := $B5CEA8; // Light Green
    93: Result := $F5F5B5; // Light Yellow
    94: Result := $9CDCFE; // Light Blue
    95: Result := $FF99FF; // Light Magenta
    96: Result := $9EEFEF; // Light Cyan
    97: Result := $FFFFFF; // White
    else Result := $D4D4D4;
  end;
end;

// Clear terminal grid
procedure ClearTerminal(Idx: Integer);
var
  r, c: Integer;
begin
  for r := 0 to TermRows - 1 do
    for c := 0 to TermCols - 1 do
    begin
      Terminals[Idx].Grid[r, c] := ' ';
      Terminals[Idx].Colors[r, c] := 7;
    end;
  Terminals[Idx].CursorX := 0;
  Terminals[Idx].CursorY := 0;
  Terminals[Idx].CurrentColor := 7;
  Terminals[Idx].AnsiState := 0;
  Terminals[Idx].AnsiParam := '';
end;

// Scroll terminal down by 1 line
procedure ScrollTerminal(Idx: Integer);
var
  r, c: Integer;
begin
  for r := 0 to TermRows - 2 do
    for c := 0 to TermCols - 1 do
    begin
      Terminals[Idx].Grid[r, c] := Terminals[Idx].Grid[r + 1, c];
      Terminals[Idx].Colors[r, c] := Terminals[Idx].Colors[r + 1, c];
    end;
  for c := 0 to TermCols - 1 do
  begin
    Terminals[Idx].Grid[TermRows - 1, c] := ' ';
    Terminals[Idx].Colors[TermRows - 1, c] := 7;
  end;
  if Terminals[Idx].CursorY > 0 then Dec(Terminals[Idx].CursorY);
end;

// Write single byte to terminal emulation grid
procedure WriteTerminalChar(Idx: Integer; Ch: Char);
var
  val: Integer;
begin
  if Terminals[Idx].AnsiState = 1 then // ESC received
  begin
    if Ch = '[' then
    begin
      Terminals[Idx].AnsiState := 2;
      Terminals[Idx].AnsiParam := '';
    end
    else
      Terminals[Idx].AnsiState := 0;
    Exit;
  end;

  if Terminals[Idx].AnsiState = 2 then // parsing ANSI code [
  begin
    if Ch in ['0'..'9', ';'] then
    begin
      Terminals[Idx].AnsiParam += Ch;
    end
    else
    begin
      // Terminating character of escape sequence
      if Ch = 'm' then
      begin
        // Color formatting
        val := StrToIntDef(Terminals[Idx].AnsiParam, 0);
        if val = 0 then
          Terminals[Idx].CurrentColor := 7
        else if (val >= 30) and (val <= 37) then
          Terminals[Idx].CurrentColor := val
        else if (val >= 90) and (val <= 97) then
          Terminals[Idx].CurrentColor := val;
      end
      else if Ch = 'J' then
      begin
        if Terminals[Idx].AnsiParam = '2' then ClearTerminal(Idx);
      end
      else if Ch = 'H' then
      begin
        Terminals[Idx].CursorX := 0;
        Terminals[Idx].CursorY := 0;
      end;
      Terminals[Idx].AnsiState := 0;
    end;
    Exit;
  end;

  if Ch = #27 then
  begin
    Terminals[Idx].AnsiState := 1;
    Exit;
  end;

  if Ch = #10 then // line feed
  begin
    Inc(Terminals[Idx].CursorY);
    if Terminals[Idx].CursorY >= TermRows then
      ScrollTerminal(Idx);
    Exit;
  end;

  if Ch = #13 then // carriage return
  begin
    Terminals[Idx].CursorX := 0;
    Exit;
  end;

  if Ch = #8 then // backspace
  begin
    if Terminals[Idx].CursorX > 0 then Dec(Terminals[Idx].CursorX);
    Exit;
  end;

  if Ch = #7 then // beep, ignore
    Exit;

  // Normal character
  if Terminals[Idx].CursorX >= TermCols then
  begin
    Terminals[Idx].CursorX := 0;
    Inc(Terminals[Idx].CursorY);
    if Terminals[Idx].CursorY >= TermRows then
      ScrollTerminal(Idx);
  end;

  Terminals[Idx].Grid[Terminals[Idx].CursorY, Terminals[Idx].CursorX] := Ch;
  Terminals[Idx].Colors[Terminals[Idx].CursorY, Terminals[Idx].CursorX] := Terminals[Idx].CurrentColor;
  Inc(Terminals[Idx].CursorX);
end;

procedure WriteStringToTerminal(Idx: Integer; const S: String);
var
  i: Integer;
begin
  for i := 1 to Length(S) do
    WriteTerminalChar(Idx, S[i]);
end;

// Read available output from shell PTY
procedure UpdateTerminalPTY(Idx: Integer);
var
  Buf: array[0..4095] of Char;
  BytesRead: Integer;
  i: Integer;
begin
  if Terminals[Idx].MasterFd = -1 then Exit;
  repeat
    BytesRead := fpRead(Terminals[Idx].MasterFd, Buf, SizeOf(Buf));
    if BytesRead > 0 then
    begin
      for i := 0 to BytesRead - 1 do
        WriteTerminalChar(Idx, Buf[i]);
    end;
  until BytesRead <= 0;
end;

// Initialize shell in PTY
procedure InitPTY(Idx: Integer);
var
  Pid: TPId;
  SlaveName: PChar;
  SlaveFd: Integer;
  Flags: Integer;
begin
  Terminals[Idx].MasterFd := posix_openpt(O_RDWR or O_NOCTTY);
  if Terminals[Idx].MasterFd < 0 then
  begin
    AddLog('[ERROR] PTY open failed for Shell ' + IntToStr(Idx + 1));
    Exit;
  end;
  grantpt(Terminals[Idx].MasterFd);
  unlockpt(Terminals[Idx].MasterFd);
  SlaveName := ptsname(Terminals[Idx].MasterFd);

  Pid := fpFork();
  if Pid < 0 then
  begin
    AddLog('[ERROR] Fork failed for Shell ' + IntToStr(Idx + 1));
    Exit;
  end;

  if Pid = 0 then // Child
  begin
    fpSetSid();
    SlaveFd := fpOpen(SlaveName, O_RDWR);
    if SlaveFd >= 0 then
    begin
      fpDup2(SlaveFd, 0);
      fpDup2(SlaveFd, 1);
      fpDup2(SlaveFd, 2);
      fpClose(SlaveFd);
      fpClose(Terminals[Idx].MasterFd);

      setenv('TERM', 'xterm-color', 1);
      fpExecve('/bin/bash', nil, nil);
      Halt(1);
    end;
  end;

  // Parent
  Terminals[Idx].ChildPid := Pid;
  Flags := fpFcntl(Terminals[Idx].MasterFd, F_GETFL);
  fpFcntl(Terminals[Idx].MasterFd, F_SETFL, Flags or O_NONBLOCK);
  
  ClearTerminal(Idx);
  AddLog('[INFO] Initialized shell PTY tab ' + IntToStr(Idx + 1));
end;

// Monitors shell processes and auto-respawns them if they exit
procedure CheckTerminalStatus(Idx: Integer);
var
  Status: Integer;
  Res: TPId;
begin
  if Terminals[Idx].MasterFd = -1 then Exit;
  Res := fpWaitPid(Terminals[Idx].ChildPid, @Status, WNOHANG);
  if Res = Terminals[Idx].ChildPid then
  begin
    AddLog('[WARNING] Shell tab ' + IntToStr(Idx + 1) + ' exited. Auto-respawning PTY...');
    fpClose(Terminals[Idx].MasterFd);
    Terminals[Idx].MasterFd := -1;
    InitPTY(Idx);
    WriteStringToTerminal(Idx, #13#10'[Shell exited. Auto-respawned.]'#13#10);
  end;
end;

procedure OpenFileInTab(const Path: String);
var
  NormPath: String;
begin
  NormPath := ExpandFileName(Path);
  
  // Check if tab limit reached
  if TabCount >= 16 then
  begin
    AddLog('[WARNING] Open file failed: Tab limit (16) reached');
    Exit;
  end;

  Tabs[TabCount].FileName := ExtractFileName(NormPath);
  Tabs[TabCount].FullPath := NormPath;
  Tabs[TabCount].LangId := detect_language(PChar(NormPath));
  Tabs[TabCount].Lines := TStringList.Create;
  Tabs[TabCount].Modified := False;
  
  if FileExists(NormPath) then
  begin
    Tabs[TabCount].Lines.LoadFromFile(NormPath);
    AddLog('[INFO] Opened existing file: ' + NormPath);
  end
  else
  begin
    Tabs[TabCount].Lines.Add(''); // Empty file fallback
    AddLog('[INFO] Created new workspace buffer: ' + NormPath);
  end;

  Tabs[TabCount].CursorCol := 0;
  Tabs[TabCount].CursorRow := 0;
  Tabs[TabCount].ScrollCol := 0;
  Tabs[TabCount].ScrollRow := 0;

  ActiveTab := TabCount;
  Inc(TabCount);
  TriggerLiveLanguageDetection;
end;

procedure SaveActiveFile;
begin
  if (ActiveTab < 0) or (ActiveTab >= TabCount) then Exit;
  try
    Tabs[ActiveTab].Lines.SaveToFile(Tabs[ActiveTab].FullPath);
    Tabs[ActiveTab].Modified := False;
    AddLog('[INFO] Saved active tab: ' + Tabs[ActiveTab].FullPath);
  except
    on E: Exception do
      AddLog('[ERROR] Saving file failed: ' + E.Message);
  end;
end;

procedure CloseTab(Idx: Integer);
var
  i: Integer;
  ClosedName: String;
begin
  if (Idx < 0) or (Idx >= TabCount) then Exit;
  ClosedName := Tabs[Idx].FileName;
  Tabs[Idx].Lines.Free;
  for i := Idx to TabCount - 2 do
    Tabs[i] := Tabs[i + 1];
  Dec(TabCount);
  
  if TabCount = 0 then
    ActiveTab := -1
  else if ActiveTab >= TabCount then
    ActiveTab := TabCount - 1
  else if ActiveTab < 0 then
    ActiveTab := 0;

  AddLog('[INFO] Closed tab: ' + ClosedName);
end;

// Save current active session workspace list
procedure SaveSession;
var
  f: TextFile;
  i: Integer;
begin
  try
    AssignFile(f, '.session_files');
    Rewrite(f);
    for i := 0 to TabCount - 1 do
    begin
      WriteLn(f, Tabs[i].FullPath);
      WriteLn(f, Format('%d %d %d %d', [Tabs[i].CursorRow, Tabs[i].CursorCol, Tabs[i].ScrollRow, Tabs[i].ScrollCol]));
    end;
    CloseFile(f);
    AddLog('[INFO] Workspace session saved successfully');
  except
    on E: Exception do
      AddLog('[ERROR] Saving session failed: ' + E.Message);
  end;
end;

// Restore previous session workspace
procedure LoadSession;
var
  f: TextFile;
  Path, PosLine: String;
  Row, Col, SRow, SCol: Integer;
  FList: TStringList;
begin
  if not FileExists('.session_files') then Exit;
  try
    AssignFile(f, '.session_files');
    Reset(f);
    while not Eof(f) do
    begin
      ReadLn(f, Path);
      if Eof(f) then Break;
      ReadLn(f, PosLine);
      if Trim(Path) = '' then Continue;
      
      OpenFileInTab(Path);
      
      FList := TStringList.Create;
      try
        FList.Delimiter := ' ';
        FList.DelimitedText := PosLine;
        if FList.Count >= 4 then
        begin
          Row := StrToIntDef(FList[0], 0);
          Col := StrToIntDef(FList[1], 0);
          SRow := StrToIntDef(FList[2], 0);
          SCol := StrToIntDef(FList[3], 0);
          
          if ActiveTab < TabCount then
          begin
            Tabs[ActiveTab].CursorRow := Min(Row, Tabs[ActiveTab].Lines.Count - 1);
            if Tabs[ActiveTab].CursorRow < 0 then Tabs[ActiveTab].CursorRow := 0;
            Tabs[ActiveTab].CursorCol := Min(Col, Length(Tabs[ActiveTab].Lines[Tabs[ActiveTab].CursorRow]));
            Tabs[ActiveTab].ScrollRow := SRow;
            Tabs[ActiveTab].ScrollCol := SCol;
            Tabs[ActiveTab].Modified := False;
          end;
        end;
      finally
        FList.Free;
      end;
    end;
    CloseFile(f);
    AddLog('[INFO] Workspace session restored successfully');
  except
    on E: Exception do
      AddLog('[ERROR] Restoring session failed: ' + E.Message);
  end;
end;

function GetLangIconGlyph(LangId: Cardinal): Byte;
begin
  case LangId of
    1: Result := 1; // Pascal
    2: Result := 2; // Rust
    3: Result := 3; // ASM
    4: Result := 4; // Makefile
    5: Result := 6; // C
    6: Result := 7; // Python
    7: Result := 8; // JS/TS
    8: Result := 9; // Go
    9: Result := 10; // HTML
    10: Result := 11; // CSS
    11: Result := 12; // Shell
    12: Result := 13; // Markdown
    13: Result := 14; // JSON
    14: Result := 15; // YAML/TOML
    else Result := 16; // Plain text
  end;
end;

procedure TriggerLiveLanguageDetection;
var
  Sample: String;
  i, LineCount: Integer;
  DetectedLang: Cardinal;
begin
  if (ActiveTab < 0) or (ActiveTab >= TabCount) then Exit;
  
  Sample := '';
  LineCount := Min(4, Tabs[ActiveTab].Lines.Count);
  for i := 0 to LineCount - 1 do
  begin
    Sample += Tabs[ActiveTab].Lines[i] + #10;
  end;
  
  DetectedLang := detect_language_from_content(PChar(Sample));
  if DetectedLang <> Tabs[ActiveTab].LangId then
  begin
    Tabs[ActiveTab].LangId := DetectedLang;
    AddLog('[INFO] Auto-detected active tab language changed to ID: ' + IntToStr(DetectedLang));
  end;
end;

procedure FindText(const Query: String);
var
  RowIdx, StartRow, i: Integer;
  Line: String;
  FoundCol: Integer;
  SearchStartCol: Integer;
begin
  if (ActiveTab < 0) or (ActiveTab >= TabCount) or (Query = '') then Exit;

  AddLog('[INFO] Searching document for query: "' + Query + '"');
  StartRow := Tabs[ActiveTab].CursorRow;
  for i := 0 to Tabs[ActiveTab].Lines.Count - 1 do
  begin
    RowIdx := (StartRow + i) mod Tabs[ActiveTab].Lines.Count;
    Line := Tabs[ActiveTab].Lines[RowIdx];
    
    if (i = 0) then
      SearchStartCol := Tabs[ActiveTab].CursorCol + 2
    else
      SearchStartCol := 1;

    if SearchStartCol <= Length(Line) then
    begin
      FoundCol := Pos(Query, Copy(Line, SearchStartCol, Length(Line) - SearchStartCol + 1));
      if FoundCol > 0 then
      begin
        Tabs[ActiveTab].CursorRow := RowIdx;
        Tabs[ActiveTab].CursorCol := (SearchStartCol - 1) + (FoundCol - 1);
        Tabs[ActiveTab].ScrollRow := Max(0, Tabs[ActiveTab].CursorRow - (EDITOR_HEIGHT div FONT_HEIGHT) div 2);
        Tabs[ActiveTab].ScrollCol := Max(0, Tabs[ActiveTab].CursorCol - ((WINDOW_WIDTH - 48) div FONT_WIDTH) div 2);
        AddLog('[INFO] Match found at row ' + IntToStr(RowIdx + 1) + ', col ' + IntToStr(Tabs[ActiveTab].CursorCol + 1));
        Exit;
      end;
    end
    else if (i > 0) or (SearchStartCol = 1) then
    begin
      FoundCol := Pos(Query, Line);
      if FoundCol > 0 then
      begin
        Tabs[ActiveTab].CursorRow := RowIdx;
        Tabs[ActiveTab].CursorCol := FoundCol - 1;
        Tabs[ActiveTab].ScrollRow := Max(0, Tabs[ActiveTab].CursorRow - (EDITOR_HEIGHT div FONT_HEIGHT) div 2);
        Tabs[ActiveTab].ScrollCol := Max(0, Tabs[ActiveTab].CursorCol - ((WINDOW_WIDTH - 48) div FONT_WIDTH) div 2);
        AddLog('[INFO] Match found at row ' + IntToStr(RowIdx + 1) + ', col ' + IntToStr(FoundCol));
        Exit;
      end;
    end;
  end;
  AddLog('[WARNING] Search query not found: "' + Query + '"');
end;

// Safely resizes the framebuffer when X11 window bounds change
procedure ResizeWindowBuffers(NewW, NewH: Integer);
begin
  if (NewW <= 10) or (NewH <= 10) then Exit; // Guard against zero/tiny minimize bounds
  if (NewW = WINDOW_WIDTH) and (NewH = WINDOW_HEIGHT) and (Img <> nil) then Exit;

  AddLog('[INFO] Resizing layout viewports to ' + IntToStr(NewW) + 'x' + IntToStr(NewH));

  if Img <> nil then
  begin
    Img^.data := nil; // Prevent XDestroyImage from freeing our FrameBuffer manually
    XDestroyImage(Img);
    Img := nil;
  end;

  if FrameBuffer <> nil then
  begin
    FreeMem(FrameBuffer);
    FrameBuffer := nil;
  end;

  WINDOW_WIDTH := NewW;
  WINDOW_HEIGHT := NewH;

  // Adapt component heights
  TERMINAL_HEIGHT := 220; // Fixed terminal height
  if WINDOW_HEIGHT - TAB_BAR_HEIGHT - SEPARATOR_HEIGHT - 100 < TERMINAL_HEIGHT then
    TERMINAL_HEIGHT := Max(80, WINDOW_HEIGHT - TAB_BAR_HEIGHT - SEPARATOR_HEIGHT - 100);

  EDITOR_HEIGHT := WINDOW_HEIGHT - TAB_BAR_HEIGHT - SEPARATOR_HEIGHT - TERMINAL_HEIGHT;
  EDITOR_Y := TAB_BAR_HEIGHT;
  TERMINAL_Y := TAB_BAR_HEIGHT + EDITOR_HEIGHT + SEPARATOR_HEIGHT;

  TermRows := Max(1, Min(58, (TERMINAL_HEIGHT - 24) div FONT_HEIGHT));
  TermCols := Max(1, Min(248, (WINDOW_WIDTH - 16) div FONT_WIDTH));

  FrameBuffer := PDWORD(AllocMem(WINDOW_WIDTH * WINDOW_HEIGHT * 4));
  Img := XCreateImage(Dis, VisualHandle, DepthVal, ZPixmap, 0, PChar(FrameBuffer),
                      WINDOW_WIDTH, WINDOW_HEIGHT, 32, 0);
end;

procedure RenderIDE;
var
  i, j, x, y: Integer;
  TabWidth, TabX: Integer;
  ActiveHighlightColor: DWORD;
  TabTitle: String;
  LineText: String;
  TokenColors: array[0..1023] of Byte;
  LineColorVal: DWORD;
  GutterWidth: Integer;
  VisibleLines: Integer;
  CharIndex: Integer;
  LineIdx: Integer;
  CursorScrX, CursorScrY: Integer;
  R, C: Integer;
  FocusColor: DWORD;
  TermTabX, TermTabWidth: Integer;
  PromptBoxX, PromptBoxY: Integer;
  LogsStartIdx, LogsIdx, LogsLineColor: DWORD;
  ItemY: Integer;
  ItemColor: DWORD;
begin
  if (FrameBuffer = nil) or (Img = nil) then Exit;
  // 1. Clear background
  FillRect(0, 0, WINDOW_WIDTH, WINDOW_HEIGHT, COLOR_BG_DARK);

  // 2. Render Tab Bar
  FillRect(0, 0, WINDOW_WIDTH, TAB_BAR_HEIGHT, COLOR_TAB_BG);
  TabX := 0;
  TabWidth := 140;
  
  for i := 0 to TabCount - 1 do
  begin
    // Check active
    if i = ActiveTab then
      FillRect(TabX, 0, TabWidth, TAB_BAR_HEIGHT, COLOR_TAB_ACTIVE)
    else
      FillRect(TabX, 0, TabWidth, TAB_BAR_HEIGHT, COLOR_TAB_BG);

    // Draw bottom border / separator line for tab bar
    FillRect(TabX, TAB_BAR_HEIGHT - 1, TabWidth, 1, $252526);

    // Draw active highlight colored bar at the top of the tab
    ActiveHighlightColor := $569CD6; // Default Blue
    case Tabs[i].LangId of
      1: ActiveHighlightColor := $C586C0; // Pascal (purple)
      2: ActiveHighlightColor := $CE9178; // Rust (orange/rust)
      3: ActiveHighlightColor := $4EC9B0; // ASM (cyan)
      4: ActiveHighlightColor := $DCDCAA; // Makefile (yellow)
      5: ActiveHighlightColor := $FF9900; // C (apricot)
      6: ActiveHighlightColor := $3572A5; // Python (blue)
      7: ActiveHighlightColor := $F1E05A; // JS (yellow)
      8: ActiveHighlightColor := $00ADD8; // Go (light blue)
      9: ActiveHighlightColor := $E34C26; // HTML (red)
      10: ActiveHighlightColor := $563D7C; // CSS (indigo)
      11: ActiveHighlightColor := $89E051; // Shell (green)
    end;
    
    if i = ActiveTab then
      FillRect(TabX, 0, TabWidth, 3, ActiveHighlightColor);

    // Draw language icon (custom glyphs 1..16)
    DrawCharASM(FrameBuffer, WINDOW_WIDTH * 4, TabX + 8, 12, GetLangIconGlyph(Tabs[i].LangId), ActiveHighlightColor);

    // Draw tab text
    TabTitle := Tabs[i].FileName;
    if Tabs[i].Modified then
      TabTitle := '*' + TabTitle; // Prepend asterisk if modified

    if Length(TabTitle) > 11 then
      TabTitle := Copy(TabTitle, 1, 8) + '...';
    DrawString(TabX + 24, 12, TabTitle, $D4D4D4);

    // Draw close button 'x' (X=TabX+TabWidth-14)
    DrawCharASM(FrameBuffer, WINDOW_WIDTH * 4, TabX + TabWidth - 14, 12, Byte('x'), $808080);

    // Draw vertical tab separator
    FillRect(TabX + TabWidth - 1, 0, 1, TAB_BAR_HEIGHT, $252526);
    
    TabX += TabWidth;
  end;

  // Render Top Menu Bar on the right side of the tab bar
  FillRect(WINDOW_WIDTH - 454, 0, 454, TAB_BAR_HEIGHT, $181818);
  FillRect(WINDOW_WIDTH - 454, TAB_BAR_HEIGHT - 1, 454, 1, $252526);

  // [ Plugins ]
  FillRect(WINDOW_WIDTH - 444, 8, 100, 24, $2D2D2D);
  FillRect(WINDOW_WIDTH - 444, 8, 100, 1, $808080);
  FillRect(WINDOW_WIDTH - 444, 31, 100, 1, $808080);
  FillRect(WINDOW_WIDTH - 444, 8, 1, 24, $808080);
  FillRect(WINDOW_WIDTH - 345, 8, 1, 24, $808080);
  DrawString(WINDOW_WIDTH - 432, 12, 'Plugins', $E0E0E0);

  // [ New ]
  FillRect(WINDOW_WIDTH - 324, 8, 55, 24, $2D2D2D);
  DrawString(WINDOW_WIDTH - 312, 12, 'New', $E0E0E0);

  // [ Open ]
  FillRect(WINDOW_WIDTH - 264, 8, 55, 24, $2D2D2D);
  DrawString(WINDOW_WIDTH - 252, 12, 'Open', $E0E0E0);

  // [ Save ]
  FillRect(WINDOW_WIDTH - 204, 8, 55, 24, $2D2D2D);
  DrawString(WINDOW_WIDTH - 192, 12, 'Save', $E0E0E0);

  // [ Save As ]
  FillRect(WINDOW_WIDTH - 144, 8, 90, 24, $2D2D2D);
  DrawString(WINDOW_WIDTH - 132, 12, 'Save As', $E0E0E0);

  // 3. Render Editor Pane
  if (ActiveTab >= 0) and (ActiveTab < TabCount) then
  begin
    GutterWidth := 48;
    VisibleLines := EDITOR_HEIGHT div FONT_HEIGHT;
    
    // Draw Gutter background
    FillRect(0, EDITOR_Y, GutterWidth, EDITOR_HEIGHT, $1A1A1A);
    // Draw Gutter border
    FillRect(GutterWidth - 1, EDITOR_Y, 1, EDITOR_HEIGHT, $2D2D2D);

    for i := 0 to VisibleLines - 1 do
    begin
      LineIdx := Tabs[ActiveTab].ScrollRow + i;
      if LineIdx >= Tabs[ActiveTab].Lines.Count then Break;

      // Draw line number
      DrawString(8, EDITOR_Y + i * FONT_HEIGHT + 4, Format('%3d', [LineIdx + 1]), COLOR_TEXT_MUTED);

      LineText := Tabs[ActiveTab].Lines[LineIdx];
      
      // Syntax highlighting tokenization
      FillChar(TokenColors, SizeOf(TokenColors), 0);
      tokenize_line(Tabs[ActiveTab].LangId, PChar(LineText), @TokenColors[0], Length(LineText));

      for j := 1 to Length(LineText) do
      begin
        CharIndex := Tabs[ActiveTab].ScrollCol + (j - 1);
        if CharIndex >= Length(LineText) then Break;
        
        case TokenColors[CharIndex] of
          COL_KEYWORD: LineColorVal := COLOR_TOKEN_KEYWORD;
          COL_IDENTIFIER: LineColorVal := COLOR_TOKEN_IDENTIFIER;
          COL_COMMENT: LineColorVal := COLOR_TOKEN_COMMENT;
          COL_STRING: LineColorVal := COLOR_TOKEN_STRING;
          COL_NUMBER: LineColorVal := COLOR_TOKEN_NUMBER;
          COL_TYPE: LineColorVal := COLOR_TOKEN_TYPE;
          COL_VARIABLE: LineColorVal := COLOR_TOKEN_VARIABLE;
          else LineColorVal := COLOR_TOKEN_DEFAULT;
        end;

        x := GutterWidth + (j - 1) * FONT_WIDTH;
        y := EDITOR_Y + i * FONT_HEIGHT + 4;
        DrawCharASM(FrameBuffer, WINDOW_WIDTH * 4, x, y, Byte(LineText[CharIndex + 1]), LineColorVal);
      end;
    end;

    // Draw Editor Cursor
    if FocusEditor and (not PromptActive) then
    begin
      CursorScrX := GutterWidth + (Tabs[ActiveTab].CursorCol - Tabs[ActiveTab].ScrollCol) * FONT_WIDTH;
      CursorScrY := EDITOR_Y + (Tabs[ActiveTab].CursorRow - Tabs[ActiveTab].ScrollRow) * FONT_HEIGHT + 4;
      if (CursorScrX >= GutterWidth) and (CursorScrX < WINDOW_WIDTH) and
         (CursorScrY >= EDITOR_Y) and (CursorScrY < EDITOR_Y + EDITOR_HEIGHT) then
      begin
        FillRect(CursorScrX, CursorScrY, 2, FONT_HEIGHT, COLOR_CURSOR);
      end;
    end;
  end
  else
  begin
    DrawString(WINDOW_WIDTH div 2 - 180, EDITOR_Y + EDITOR_HEIGHT div 2 - 8, 'No files open. Click [New] or [Open] to start.', $808080);
  end;

  // 4. Render Split Bar Separator
  FillRect(0, EDITOR_Y + EDITOR_HEIGHT, WINDOW_WIDTH, SEPARATOR_HEIGHT, $2D2D2D);
  if FocusEditor then
    FocusColor := $3C3C3C
  else
    FocusColor := $569CD6;
  FillRect(0, EDITOR_Y + EDITOR_HEIGHT + 2, WINDOW_WIDTH, 2, FocusColor);

  // 5. Render Terminal/Logs Pane
  FillRect(0, TERMINAL_Y, WINDOW_WIDTH, TERMINAL_HEIGHT, COLOR_TERM_BG);
  FillRect(0, TERMINAL_Y, WINDOW_WIDTH, 20, $121212);
  
  // Render Terminal Tabs
  TermTabWidth := 100;
  for i := 0 to TermCount - 1 do
  begin
    TermTabX := i * TermTabWidth;
    if (i = ActiveTerm) and (ActiveTerm <> 4) then
    begin
      FillRect(TermTabX, TERMINAL_Y, TermTabWidth, 20, COLOR_TERM_BG);
      FillRect(TermTabX, TERMINAL_Y, TermTabWidth, 2, $00FF00);
    end
    else
    begin
      FillRect(TermTabX, TERMINAL_Y, TermTabWidth, 20, $0F0F0F);
    end;
    FillRect(TermTabX + TermTabWidth - 1, TERMINAL_Y, 1, 20, $252526);
    DrawCharASM(FrameBuffer, WINDOW_WIDTH * 4, TermTabX + 4, TERMINAL_Y + 2, 5, $00FF00); // prompt icon
    DrawString(TermTabX + 16, TERMINAL_Y + 2, 'Shell ' + IntToStr(i + 1), $D4D4D4);
  end;

  // Render "Logs" debugger tab
  TermTabX := TermCount * TermTabWidth;
  if ActiveTerm = 4 then
  begin
    FillRect(TermTabX, TERMINAL_Y, TermTabWidth, 20, COLOR_TERM_BG);
    FillRect(TermTabX, TERMINAL_Y, TermTabWidth, 2, $FF9900); // Orange highlight for logs
  end
  else
  begin
    FillRect(TermTabX, TERMINAL_Y, TermTabWidth, 20, $0F0F0F);
  end;
  FillRect(TermTabX + TermTabWidth - 1, TERMINAL_Y, 1, 20, $252526);
  DrawCharASM(FrameBuffer, WINDOW_WIDTH * 4, TermTabX + 4, TERMINAL_Y + 2, 4, $FF9900); // gear icon
  DrawString(TermTabX + 16, TERMINAL_Y + 2, 'Logs', $D4D4D4);

  // Draw [+] Add Terminal Tab Button
  if TermCount < 4 then
  begin
    TermTabX := (TermCount + 1) * TermTabWidth;
    FillRect(TermTabX, TERMINAL_Y, 40, 20, $0D0D0D);
    FillRect(TermTabX + 39, TERMINAL_Y, 1, 20, $252526);
    DrawString(TermTabX + 16, TERMINAL_Y + 2, '+', $808080);
  end;

  DrawString(WINDOW_WIDTH - 80, TERMINAL_Y + 2, 'Terminal', $5A5A5A);
  
  if ActiveTerm = 4 then
  begin
    // Render Debugger Logs Circular Buffer
    LogsStartIdx := Max(0, LogsCount - TermRows);
    for R := 0 to TermRows - 1 do
    begin
      LogsIdx := LogsStartIdx + R;
      if LogsIdx >= LogsCount then Break;

      LogsLineColor := $D4D4D4; // light gray
      if Pos('[WARNING]', Logs[LogsIdx]) > 0 then LogsLineColor := $FF9900
      else if Pos('[ERROR]', Logs[LogsIdx]) > 0 then LogsLineColor := $F44747
      else if Pos('[INFO]', Logs[LogsIdx]) > 0 then LogsLineColor := $6A9955;

      DrawString(8, TERMINAL_Y + 24 + R * FONT_HEIGHT, Logs[LogsIdx], LogsLineColor);
    end;
  end
  else
  begin
    // Render active shell terminal grid
    for R := 0 to TermRows - 1 do
    begin
      for C := 0 to TermCols - 1 do
      begin
        x := 8 + C * FONT_WIDTH;
        y := TERMINAL_Y + 24 + R * FONT_HEIGHT;
        if (Terminals[ActiveTerm].Grid[R, C] <> ' ') and (Terminals[ActiveTerm].Grid[R, C] <> #0) then
        begin
          DrawCharASM(FrameBuffer, WINDOW_WIDTH * 4, x, y, Byte(Terminals[ActiveTerm].Grid[R, C]), GetTermColorVal(Terminals[ActiveTerm].Colors[R, C]));
        end;
      end;
    end;

    // Draw Terminal Cursor
    if (not FocusEditor) and (not PromptActive) then
    begin
      x := 8 + Terminals[ActiveTerm].CursorX * FONT_WIDTH;
      y := TERMINAL_Y + 24 + Terminals[ActiveTerm].CursorY * FONT_HEIGHT;
      if (x >= 0) and (x < WINDOW_WIDTH - 8) and (y >= TERMINAL_Y + 20) and (y < WINDOW_HEIGHT) then
        FillRect(x, y, 8, 2, $00FF00);
    end;
  end;

  // 6. Render Prompt Dialog (centered dynamically)
  if PromptActive then
  begin
    PromptBoxX := (WINDOW_WIDTH - 624) div 2;
    PromptBoxY := (WINDOW_HEIGHT - 120) div 2;

    if PromptMode = 3 then
    begin
      // Close tab confirmation warning dialog
      FillRect(PromptBoxX, PromptBoxY, 624, 120, $1E1E1E);
      FillRect(PromptBoxX, PromptBoxY, 624, 2, $F44747);
      FillRect(PromptBoxX, PromptBoxY + 118, 624, 2, $F44747);
      FillRect(PromptBoxX, PromptBoxY, 2, 120, $F44747);
      FillRect(PromptBoxX + 622, PromptBoxY, 2, 120, $F44747);

      DrawString(PromptBoxX + 20, PromptBoxY + 20, 'Unsaved Changes in: ' + Tabs[ClosingTabIdx].FileName, $D4D4D4);
      DrawString(PromptBoxX + 20, PromptBoxY + 40, 'Do you want to save changes before closing?', $808080);
      
      // Save button
      FillRect(PromptBoxX + 20, PromptBoxY + 75, 100, 24, $2D2D2D);
      DrawString(PromptBoxX + 50, PromptBoxY + 79, 'Save', $00FF00);

      // Close Anyway
      FillRect(PromptBoxX + 140, PromptBoxY + 75, 120, 24, $2D2D2D);
      DrawString(PromptBoxX + 150, PromptBoxY + 79, 'Close Anyway', $F44747);

      // Cancel
      FillRect(PromptBoxX + 280, PromptBoxY + 75, 100, 24, $2D2D2D);
      DrawString(PromptBoxX + 305, PromptBoxY + 79, 'Cancel', $E0E0E0);
    end
    else
    begin
      FillRect(PromptBoxX, PromptBoxY, 624, 100, $1E1E1E);
      FillRect(PromptBoxX, PromptBoxY, 624, 2, $569CD6);
      FillRect(PromptBoxX, PromptBoxY + 98, 624, 2, $569CD6);
      FillRect(PromptBoxX, PromptBoxY, 2, 100, $569CD6);
      FillRect(PromptBoxX + 622, PromptBoxY, 2, 100, $569CD6);

      if PromptMode = 0 then
        DrawString(PromptBoxX + 20, PromptBoxY + 20, 'Enter File Path to Open/Create:', $D4D4D4)
      else if PromptMode = 1 then
        DrawString(PromptBoxX + 20, PromptBoxY + 20, 'Enter File Path to Save As:', $D4D4D4)
      else
        DrawString(PromptBoxX + 20, PromptBoxY + 20, 'Search Document:', $D4D4D4);

      FillRect(PromptBoxX + 20, PromptBoxY + 50, 584, 24, $0D0D0D);
      DrawString(PromptBoxX + 30, PromptBoxY + 54, PromptText, $D4D4D4);
      FillRect(PromptBoxX + 30 + Length(PromptText) * FONT_WIDTH, PromptBoxY + 54, 2, 16, COLOR_CURSOR);
    end;
  end;

  // Render Plugin List Dropdown Menu
  if PluginMenuOpen then
  begin
    PromptBoxX := WINDOW_WIDTH - 444;
    PromptBoxY := TAB_BAR_HEIGHT;
    // Draw background
    FillRect(PromptBoxX, PromptBoxY, 150, PluginCount * 24 + 10, $1E1E1E);
    // Draw borders (always grey for the outer list dropdown)
    FillRect(PromptBoxX, PromptBoxY, 150, 1, $808080);
    FillRect(PromptBoxX, PromptBoxY + PluginCount * 24 + 9, 150, 1, $808080);
    FillRect(PromptBoxX, PromptBoxY, 1, PluginCount * 24 + 10, $808080);
    FillRect(PromptBoxX + 149, PromptBoxY, 1, PluginCount * 24 + 10, $808080);

    for i := 0 to PluginCount - 1 do
    begin
      ItemY := PromptBoxY + 5 + i * 24;
      
      // Determine outline color for this specific plugin item
      if i = ActivePluginIdx then
        ItemColor := $F44747 // Red
      else
        ItemColor := $569CD6; // Blue

      // Draw item box outline border
      FillRect(PromptBoxX + 5, ItemY, 140, 1, ItemColor);
      FillRect(PromptBoxX + 5, ItemY + 19, 140, 1, ItemColor);
      FillRect(PromptBoxX + 5, ItemY, 1, 20, ItemColor);
      FillRect(PromptBoxX + 144, ItemY, 1, 20, ItemColor);

      TabTitle := ChangeFileExt(PluginFiles[i], '');
      if Length(TabTitle) > 14 then
        TabTitle := Copy(TabTitle, 1, 11) + '...';
      DrawString(PromptBoxX + 12, ItemY + 2, TabTitle, $D4D4D4);
    end;
  end;
end;

procedure FlushFrameBuffer;
begin
  if (FrameBuffer = nil) or (Img = nil) then Exit;
  XPutImage(Dis, Win, GcHandle, Img, 0, 0, 0, 0, WINDOW_WIDTH, WINDOW_HEIGHT);
  XFlush(Dis);
end;

procedure HandleEditorKeyPress(Key: TKeySym; const Text: String);
var
  LineText: String;
  CursorCol: Integer;
  CursorRow: Integer;
begin
  if (ActiveTab < 0) or (ActiveTab >= TabCount) then Exit;
  
  CursorCol := Tabs[ActiveTab].CursorCol;
  CursorRow := Tabs[ActiveTab].CursorRow;
  LineText := Tabs[ActiveTab].Lines[CursorRow];

  case Key of
    XK_Left:
      begin
        if CursorCol > 0 then
          Dec(Tabs[ActiveTab].CursorCol)
        else if CursorRow > 0 then
        begin
          Dec(Tabs[ActiveTab].CursorRow);
          Tabs[ActiveTab].CursorCol := Length(Tabs[ActiveTab].Lines[Tabs[ActiveTab].CursorRow]);
        end;
      end;
    XK_Right:
      begin
        if CursorCol < Length(LineText) then
          Inc(Tabs[ActiveTab].CursorCol)
        else if CursorRow < Tabs[ActiveTab].Lines.Count - 1 then
        begin
          Inc(Tabs[ActiveTab].CursorRow);
          Tabs[ActiveTab].CursorCol := 0;
        end;
      end;
    XK_Up:
      begin
        if CursorRow > 0 then
        begin
          Dec(Tabs[ActiveTab].CursorRow);
          if Tabs[ActiveTab].CursorCol > Length(Tabs[ActiveTab].Lines[Tabs[ActiveTab].CursorRow]) then
            Tabs[ActiveTab].CursorCol := Length(Tabs[ActiveTab].Lines[Tabs[ActiveTab].CursorRow]);
        end;
      end;
    XK_Down:
      begin
        if CursorRow < Tabs[ActiveTab].Lines.Count - 1 then
        begin
          Inc(Tabs[ActiveTab].CursorRow);
          if Tabs[ActiveTab].CursorCol > Length(Tabs[ActiveTab].Lines[Tabs[ActiveTab].CursorRow]) then
            Tabs[ActiveTab].CursorCol := Length(Tabs[ActiveTab].Lines[Tabs[ActiveTab].CursorRow]);
        end;
      end;
    XK_BackSpace:
      begin
        if CursorCol > 0 then
        begin
          Delete(LineText, CursorCol, 1);
          Tabs[ActiveTab].Lines[CursorRow] := LineText;
          Dec(Tabs[ActiveTab].CursorCol);
        end
        else if CursorRow > 0 then
        begin
          Dec(Tabs[ActiveTab].CursorRow);
          Tabs[ActiveTab].CursorCol := Length(Tabs[ActiveTab].Lines[Tabs[ActiveTab].CursorRow]);
          Tabs[ActiveTab].Lines[Tabs[ActiveTab].CursorRow] := Tabs[ActiveTab].Lines[Tabs[ActiveTab].CursorRow] + LineText;
          Tabs[ActiveTab].Lines.Delete(CursorRow);
        end;
        Tabs[ActiveTab].Modified := True;
      end;
    XK_Delete:
      begin
        if CursorCol < Length(LineText) then
        begin
          Delete(LineText, CursorCol + 1, 1);
          Tabs[ActiveTab].Lines[CursorRow] := LineText;
        end
        else if CursorRow < Tabs[ActiveTab].Lines.Count - 1 then
        begin
          Tabs[ActiveTab].Lines[CursorRow] := LineText + Tabs[ActiveTab].Lines[CursorRow + 1];
          Tabs[ActiveTab].Lines.Delete(CursorRow + 1);
        end;
        Tabs[ActiveTab].Modified := True;
      end;
    XK_Return:
      begin
        Tabs[ActiveTab].Lines[CursorRow] := Copy(LineText, 1, CursorCol);
        Tabs[ActiveTab].Lines.Insert(CursorRow + 1, Copy(LineText, CursorCol + 1, Length(LineText) - CursorCol));
        Inc(Tabs[ActiveTab].CursorRow);
        Tabs[ActiveTab].CursorCol := 0;
        Tabs[ActiveTab].Modified := True;
      end;
    else
      if (Text <> '') and (Ord(Text[1]) >= 32) and (Ord(Text[1]) <= 126) then
      begin
        Insert(Text, LineText, CursorCol + 1);
        Tabs[ActiveTab].Lines[CursorRow] := LineText;
        Inc(Tabs[ActiveTab].CursorCol);
        Tabs[ActiveTab].Modified := True;
      end;
  end;

  CursorCol := Tabs[ActiveTab].CursorCol;
  CursorRow := Tabs[ActiveTab].CursorRow;
  
  if CursorRow < Tabs[ActiveTab].ScrollRow then
    Tabs[ActiveTab].ScrollRow := CursorRow;
  if CursorRow >= Tabs[ActiveTab].ScrollRow + (EDITOR_HEIGHT div FONT_HEIGHT) then
    Tabs[ActiveTab].ScrollRow := CursorRow - (EDITOR_HEIGHT div FONT_HEIGHT) + 1;

  if CursorCol < Tabs[ActiveTab].ScrollCol then
    Tabs[ActiveTab].ScrollCol := CursorCol;
  if CursorCol >= Tabs[ActiveTab].ScrollCol + ((WINDOW_WIDTH - 48) div FONT_WIDTH) then
    Tabs[ActiveTab].ScrollCol := CursorCol - ((WINDOW_WIDTH - 48) div FONT_WIDTH) + 1;

  TriggerLiveLanguageDetection;
  if ActivePluginIdx <> -1 then
    RunAssemblyPlugin(ActivePluginIdx);
end;

procedure HandleKeyPress(var Event: TXEvent);
var
  Key: TKeySym;
  Buf: array[0..31] of Char;
  Count: Integer;
  InputStr: String;
begin
  Count := XLookupString(@Event.xkey, Buf, SizeOf(Buf) - 1, @Key, nil);
  Buf[Count] := #0;
  InputStr := StrPas(Buf);

  if PromptActive then
  begin
    if Key = XK_Escape then
      PromptActive := False
    else if Key = XK_Return then
    begin
      if Trim(PromptText) <> '' then
      begin
        if PromptMode = 0 then
          OpenFileInTab(PromptText)
        else if (PromptMode = 1) and (ActiveTab >= 0) and (ActiveTab < TabCount) then
        begin
          Tabs[ActiveTab].FullPath := ExpandFileName(PromptText);
          Tabs[ActiveTab].FileName := ExtractFileName(Tabs[ActiveTab].FullPath);
          Tabs[ActiveTab].LangId := detect_language(PChar(Tabs[ActiveTab].FullPath));
          SaveActiveFile;
        end
        else if PromptMode = 2 then
        begin
          FindText(PromptText);
        end;
      end;
      PromptActive := False;
    end
    else if Key = XK_BackSpace then
    begin
      if Length(PromptText) > 0 then
        Delete(PromptText, Length(PromptText), 1);
    end
    else if (Count > 0) and (Ord(Buf[0]) >= 32) and (Ord(Buf[0]) <= 126) then
    begin
      PromptText += InputStr;
    end;
    Exit;
  end;

  // Check Global Hotkeys
  if (Event.xkey.state and ControlMask) <> 0 then
  begin
    if Key = XK_s then
    begin
      SaveActiveFile;
      Exit;
    end;
    if Key = XK_o then
    begin
      PromptActive := True;
      PromptMode := 0;
      PromptText := '';
      Exit;
    end;
    if Key = XK_n then
    begin
      OpenFileInTab('untitled_' + IntToStr(TabCount + 1) + '.pas');
      Exit;
    end;
    if Key = XK_a then
    begin
      if (ActiveTab >= 0) and (ActiveTab < TabCount) then
      begin
        Tabs[ActiveTab].Lines.Clear;
        Tabs[ActiveTab].Lines.Add('');
        Tabs[ActiveTab].CursorCol := 0;
        Tabs[ActiveTab].CursorRow := 0;
        Tabs[ActiveTab].ScrollCol := 0;
        Tabs[ActiveTab].ScrollRow := 0;
        Tabs[ActiveTab].Modified := True;
        AddLog('[INFO] Cleared active tab content (Ctrl+A)');
        TriggerLiveLanguageDetection;
      end;
      Exit;
    end;
    if Key = XK_f then
    begin
      PromptActive := True;
      PromptMode := 2;
      PromptText := '';
      Exit;
    end;
    if Key = XK_q then
    begin
      SaveSession;
      AddLog('[INFO] ReIDE shut down cleanly via hotkey');
      XCloseDisplay(Dis);
      Halt(0);
    end;
  end;

  // Standard Focus handlers
  if FocusEditor then
    HandleEditorKeyPress(Key, InputStr)
  else
  begin
    if (ActiveTerm >= 0) and (ActiveTerm < 4) and (Terminals[ActiveTerm].MasterFd <> -1) then
    begin
      if Key = XK_Return then
        fpWrite(Terminals[ActiveTerm].MasterFd, PChar(#13), 1)
      else if Key = XK_BackSpace then
        fpWrite(Terminals[ActiveTerm].MasterFd, PChar(#127), 1)
      else if Count > 0 then
        fpWrite(Terminals[ActiveTerm].MasterFd, PChar(InputStr), Count);
    end;
  end;
end;

procedure HandleButtonPress(var Event: TXEvent);
var
  ClickX, ClickY: Integer;
  TermTabWidth: Integer;
  TermTabIdx: Integer;
  TabIdx: Integer;
  RelativeX: Integer;
  PromptBoxX, PromptBoxY: Integer;
  ClickedIdx: Integer;
begin
  ClickX := Event.xbutton.x;
  ClickY := Event.xbutton.y;

  // Intercept warning dialog clicks (adapted for center dialog position)
  if PromptActive and (PromptMode = 3) then
  begin
    PromptBoxX := (WINDOW_WIDTH - 624) div 2;
    PromptBoxY := (WINDOW_HEIGHT - 120) div 2;

    if (ClickY >= PromptBoxY + 75) and (ClickY < PromptBoxY + 99) then
    begin
      // Save button
      if (ClickX >= PromptBoxX + 20) and (ClickX < PromptBoxX + 120) then
      begin
        ActiveTab := ClosingTabIdx;
        SaveActiveFile;
        CloseTab(ClosingTabIdx);
        PromptActive := False;
      end
      // Close Anyway button
      else if (ClickX >= PromptBoxX + 140) and (ClickX < PromptBoxX + 260) then
      begin
        CloseTab(ClosingTabIdx);
        PromptActive := False;
      end
      // Cancel button
      else if (ClickX >= PromptBoxX + 280) and (ClickX < PromptBoxX + 380) then
      begin
        PromptActive := False;
      end;
    end;
    Exit;
  end;

  // Handle dropdown menu selection clicks if open
  if PluginMenuOpen then
  begin
    PromptBoxX := WINDOW_WIDTH - 444;
    PromptBoxY := TAB_BAR_HEIGHT;
    
    // Check if click was inside the dropdown menu panel
    if (ClickX >= PromptBoxX) and (ClickX < PromptBoxX + 150) and
       (ClickY >= PromptBoxY) and (ClickY < PromptBoxY + PluginCount * 24 + 10) then
    begin
      ClickedIdx := (ClickY - PromptBoxY - 5) div 24;
      if (ClickedIdx >= 0) and (ClickedIdx < PluginCount) then
      begin
        if ActivePluginIdx = ClickedIdx then
        begin
          ActivePluginIdx := -1;
          AddLog('[INFO] Deactivated plugin filter');
        end
        else
        begin
          ActivePluginIdx := ClickedIdx;
          AddLog('[INFO] Activated plugin filter: ' + PluginFiles[ActivePluginIdx]);
          RunAssemblyPlugin(ActivePluginIdx);
        end;
      end;
      PluginMenuOpen := False;
      Exit;
    end;
    // Clicked outside the menu, close it
    PluginMenuOpen := False;
  end;

  if ClickY < TAB_BAR_HEIGHT then
  begin
    // Check Menu buttons first
    // [ Plugins ]
    if (ClickX >= WINDOW_WIDTH - 444) and (ClickX < WINDOW_WIDTH - 344) then
    begin
      ScanPlugins; // Re-scan folder on click to find new plugins dynamically
      if PluginCount > 0 then
        PluginMenuOpen := not PluginMenuOpen
      else
        AddLog('[INFO] No plugins found to display');
    end
    // [ New ]
    else if (ClickX >= WINDOW_WIDTH - 324) and (ClickX < WINDOW_WIDTH - 269) then
    begin
      OpenFileInTab('untitled_' + IntToStr(TabCount + 1) + '.pas');
    end
    // [ Open ]
    else if (ClickX >= WINDOW_WIDTH - 264) and (ClickX < WINDOW_WIDTH - 209) then
    begin
      PromptActive := True;
      PromptMode := 0;
      PromptText := '';
    end
    // [ Save ]
    else if (ClickX >= WINDOW_WIDTH - 204) and (ClickX < WINDOW_WIDTH - 149) then
    begin
      SaveActiveFile;
    end
    // [ Save As ]
    else if (ClickX >= WINDOW_WIDTH - 144) and (ClickX < WINDOW_WIDTH - 54) then
    begin
      if (ActiveTab >= 0) and (ActiveTab < TabCount) then
      begin
        PromptActive := True;
        PromptMode := 1;
        PromptText := Tabs[ActiveTab].FullPath;
      end;
    end
    // Check File Tabs
    else
    begin
      TabIdx := ClickX div 140;
      if TabIdx < TabCount then
      begin
        RelativeX := ClickX - (TabIdx * 140);
        // If click is on the far right 'x' area (X=120..138)
        if (RelativeX >= 120) and (RelativeX <= 138) then
        begin
          if Tabs[TabIdx].Modified then
          begin
            PromptActive := True;
            PromptMode := 3;
            ClosingTabIdx := TabIdx;
          end
          else
          begin
            CloseTab(TabIdx);
          end;
        end
        else
        begin
          ActiveTab := TabIdx;
          FocusEditor := True;
        end;
      end;
    end;
  end
  else if ClickY < EDITOR_Y + EDITOR_HEIGHT then
  begin
    FocusEditor := True;
  end;

  // Terminal/Logs tab click check
  if (ClickY >= TERMINAL_Y) and (ClickY < TERMINAL_Y + 20) then
  begin
    TermTabWidth := 100;
    TermTabIdx := ClickX div TermTabWidth;
    if TermTabIdx < TermCount then
    begin
      ActiveTerm := TermTabIdx;
      FocusEditor := False;
    end
    else if TermTabIdx = TermCount then
    begin
      ActiveTerm := 4; // Select "Logs" tab
      FocusEditor := False;
    end
    else if (TermTabIdx = TermCount + 1) and (TermCount < 4) and (ClickX < ((TermCount + 1) * TermTabWidth) + 40) then
    begin
      InitPTY(TermCount);
      ActiveTerm := TermCount;
      Inc(TermCount);
      FocusEditor := False;
    end;
  end
  else if ClickY >= TERMINAL_Y + 20 then
  begin
    FocusEditor := False;
  end;
end;

var
  Event: TXEvent;
  WaitStruct: TTimeVal;
  ReadFds: TFDSet;
  SelectRes: Integer;
  i: Integer;
  MaxFd: Integer;
  HomeDir: String;
  LogsFolder: String;
  PluginsFolder: String;

begin
  // Set up logs folder and file paths
  HomeDir := GetEnvironmentVariable('HOME');
  if HomeDir = '' then HomeDir := '/home/robby';
  LogsFolder := HomeDir + '/.reide/logs';
  PluginsFolder := HomeDir + '/.reide/plugins';
  
  if ForceDirectories(LogsFolder) then
  begin
    LogFilePath := LogsFolder + '/ide.log';
    AddLog('[INFO] ReIDE logging initialized inside ' + LogFilePath);
  end
  else
  begin
    WriteLn('Failed to create logs folder at: ' + LogsFolder);
  end;

  // Automatically create the plugins folder
  if ForceDirectories(PluginsFolder) then
  begin
    AddLog('[INFO] ReIDE plugins folder set up at ' + PluginsFolder);
  end;

  // Open default display first to allow visual queries
  Dis := XOpenDisplay(nil);
  if Dis = nil then
  begin
    AddLog('[ERROR] Cannot open X11 Display');
    Halt(1);
  end;

  ScreenHandle := DefaultScreen(Dis);
  VisualHandle := DefaultVisual(Dis, ScreenHandle);
  DepthVal := DefaultDepth(Dis, ScreenHandle);

  // Initialize first terminal PTY tab
  InitPTY(0);
  ActiveTerm := 0;
  TermCount := 1;

  if ParamCount > 0 then
  begin
    for i := 1 to ParamCount do
      OpenFileInTab(ParamStr(i));
  end
  else
  begin
    LoadSession;
  end;

  // Scan plugins initially
  ScanPlugins;

  Win := XCreateSimpleWindow(Dis, RootWindow(Dis, ScreenHandle), 100, 100, WINDOW_WIDTH, WINDOW_HEIGHT, 1,
                           BlackPixel(Dis, ScreenHandle), BlackPixel(Dis, ScreenHandle));
  
  XSelectInput(Dis, Win, ExposureMask or KeyPressMask or ButtonPressMask or StructureNotifyMask);
  XStoreName(Dis, Win, 'ReIDE');
  XMapWindow(Dis, Win);

  // Trigger initial resize & buffer allocation
  ResizeWindowBuffers(WINDOW_WIDTH, WINDOW_HEIGHT);

  GcHandle := XCreateGC(Dis, Win, 0, nil);

  AddLog('[INFO] ReIDE window and visual pipeline instantiated successfully');

  // Main Event Loop
  while True do
  begin
    while XPending(Dis) > 0 do
    begin
      XNextEvent(Dis, @Event);
      if Event._type = Expose then
      begin
        RenderIDE;
        FlushFrameBuffer;
      end
      else if Event._type = ConfigureNotify then
      begin
        ResizeWindowBuffers(Event.xconfigure.width, Event.xconfigure.height);
        RenderIDE;
        FlushFrameBuffer;
      end
      else if Event._type = KeyPress then
      begin
        HandleKeyPress(Event);
        RenderIDE;
        FlushFrameBuffer;
      end
      else if Event._type = ButtonPress then
      begin
        HandleButtonPress(Event);
        RenderIDE;
        FlushFrameBuffer;
      end;
    end;

    // Check PTY status and update buffer for all active terminal tabs
    for i := 0 to TermCount - 1 do
    begin
      UpdateTerminalPTY(i);
      CheckTerminalStatus(i);
    end;

    RenderIDE;
    FlushFrameBuffer;

    fpFD_ZERO(ReadFds);
    fpFD_SET(ConnectionNumber(Dis), ReadFds);
    MaxFd := ConnectionNumber(Dis);
    
    for i := 0 to TermCount - 1 do
    begin
      if Terminals[i].MasterFd <> -1 then
      begin
        fpFD_SET(Terminals[i].MasterFd, ReadFds);
        if Terminals[i].MasterFd > MaxFd then
          MaxFd := Terminals[i].MasterFd;
      end;
    end;

    WaitStruct.tv_sec := 0;
    WaitStruct.tv_usec := 20000;

    SelectRes := fpSelect(MaxFd + 1, @ReadFds, nil, nil, @WaitStruct);
  end;

  SaveSession;
  XDestroyImage(Img);
  XCloseDisplay(Dis);
end.
