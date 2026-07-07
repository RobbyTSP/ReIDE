program TestX11;
uses
  xlib, x, xutil;

var
  d: PDisplay;
  w: TWindow;
  s: Integer;
  e: TXEvent;

begin
  d := XOpenDisplay(nil);
  if d = nil then
  begin
    WriteLn('Cannot open display');
    Halt(1);
  end;
  s := DefaultScreen(d);
  w := XCreateSimpleWindow(d, RootWindow(d, s), 10, 10, 640, 480, 1,
                           BlackPixel(d, s), WhitePixel(d, s));
  XSelectInput(d, w, ExposureMask or KeyPressMask);
  XMapWindow(d, w);
  WriteLn('X11 Window opened successfully!');
  XCloseDisplay(d);
end.
