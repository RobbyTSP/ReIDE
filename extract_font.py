import gzip
import os

def load_font():
    paths = [
        "/usr/share/consolefonts/default8x16.psfu.gz",
        "/usr/share/consolefonts/cp850-8x16.psfu.gz",
        "/usr/share/consolefonts/drdos8x16.psfu.gz"
    ]
    font_path = None
    for p in paths:
        if os.path.exists(p):
            font_path = p
            break
            
    if not font_path:
        raise FileNotFoundError("Could not find any standard console fonts.")

    print(f"Loading font from {font_path}")
    with gzip.open(font_path, "rb") as f:
        data = f.read()
    
    if data[0:2] == b"\x36\x04":
        mode = data[2]
        charsize = data[3]
        print(f"PSF1 font, charsize={charsize}, mode={mode}")
        headersize = 4
        num_chars = 512 if (mode & 0x01) else 256
        font_data = bytearray(data[headersize : headersize + num_chars * charsize])
    elif data[0:4] == b"\x72\xb5\x4a\x86":
        headersize = int.from_bytes(data[8:12], "little")
        num_chars = int.from_bytes(data[16:20], "little")
        charsize = int.from_bytes(data[20:24], "little")
        height = int.from_bytes(data[24:28], "little")
        width = int.from_bytes(data[28:32], "little")
        print(f"PSF2 font, headersize={headersize}, num_chars={num_chars}, charsize={charsize}, height={height}, width={width}")
        font_data = bytearray(data[headersize : headersize + num_chars * charsize])
    else:
        print("Unknown magic, using fallback")
        font_data = bytearray(256 * 16)
        charsize = 16
        
    return font_data, charsize

def main():
    font_bytes, charsize = load_font()
    
    chars = []
    for c in range(256):
        glyph = [0] * 16
        if c * charsize < len(font_bytes):
            for row in range(16):
                if row < charsize:
                    glyph[row] = font_bytes[c * charsize + row]
        chars.append(glyph)
        
    # Inject custom icons
    # Glyph 1: Pascal Icon (A clean 'P' in a bracket-like box)
    chars[1] = [
        0b00000000,
        0b01111110,
        0b10000001,
        0b10111101,
        0b10100101,
        0b10111101,
        0b10100001,
        0b10100001,
        0b10100001,
        0b10000001,
        0b01111110,
        0b00000000,
        0b00000000,
        0b00000000,
        0b00000000,
        0b00000000,
    ]
    # Glyph 2: Rust Icon (A clean 'R' inside gear-like teeth)
    chars[2] = [
        0b00000000,
        0b01010100,
        0b00111000,
        0b11010110,
        0b10111010,
        0b00101000,
        0b11111110,
        0b10100110,
        0b10100110,
        0b10111110,
        0b00101000,
        0b11010110,
        0b00111000,
        0b01010100,
        0b00000000,
        0b00000000,
    ]
    # Glyph 3: Assembly Icon (An 'A' with register-like arrow)
    chars[3] = [
        0b00000000,
        0b00111100,
        0b01000010,
        0b01000010,
        0b01111110,
        0b01000010,
        0b01000010,
        0b00000000,
        0b00011000,
        0b00001100,
        0b11111110,
        0b00001100,
        0b00011000,
        0b00000000,
        0b00000000,
        0b00000000,
    ]
    # Glyph 4: Makefile Icon (A clean 'M' inside gear-like frame)
    chars[4] = [
        0b00000000,
        0b01111110,
        0b10000001,
        0b10100011,
        0b10110111,
        0b10101011,
        0b10100011,
        0b10100011,
        0b10100011,
        0b10000001,
        0b01111110,
        0b00000000,
        0b00000000,
        0b00000000,
        0b00000000,
        0b00000000,
    ]
    # Glyph 5: Terminal Icon (A prompt '>_')
    chars[5] = [
        0b00000000,
        0b00000000,
        0b00000000,
        0b11000000,
        0b01100000,
        0b00110000,
        0b01100000,
        0b11000000,
        0b00000000,
        0b00000000,
        0b00001111,
        0b00001111,
        0b00000000,
        0b00000000,
        0b00000000,
        0b00000000,
    ]
    # Glyph 6: C/C++ Icon ('C' bracketed)
    chars[6] = [
        0b00000000,
        0b00111100,
        0b01100110,
        0b11000000,
        0b11000000,
        0b11000000,
        0b01100110,
        0b00111100,
        0b00000000,
        0b00000000,
        0b00000000,
        0b00000000,
        0b00000000,
        0b00000000,
        0b00000000,
        0b00000000,
    ]
    # Glyph 7: Python Icon ('Py' stylized)
    chars[7] = [
        0b00000000,
        0b00111100,
        0b01000110,
        0b01000110,
        0b00111100,
        0b00000100,
        0b00111100,
        0b01000100,
        0b01000100,
        0b00111100,
        0b00000000,
        0b00000000,
        0b00000000,
        0b00000000,
        0b00000000,
        0b00000000,
    ]
    # Glyph 8: JS/TS Icon ('JS' block)
    chars[8] = [
        0b00000000,
        0b01111110,
        0b01000010,
        0b01111010,
        0b00001010,
        0b01111010,
        0b01111110,
        0b00000000,
        0b00000000,
        0b00000000,
        0b00000000,
        0b00000000,
        0b00000000,
        0b00000000,
        0b00000000,
        0b00000000,
    ]
    # Glyph 9: Go Icon ('Go' letters)
    chars[9] = [
        0b00000000,
        0b00111100,
        0b01100110,
        0b11000000,
        0b11011100,
        0b11000100,
        0b01100110,
        0b00111100,
        0b00000000,
        0b00000000,
        0b00000000,
        0b00000000,
        0b00000000,
        0b00000000,
        0b00000000,
        0b00000000,
    ]
    # Glyph 10: HTML/XML Icon ('</>' tags)
    chars[10] = [
        0b00000000,
        0b00100100,
        0b01001000,
        0b10010000,
        0b01001000,
        0b00100100,
        0b00000000,
        0b00000000,
        0b00000000,
        0b00000000,
        0b00000000,
        0b00000000,
        0b00000000,
        0b00000000,
        0b00000000,
        0b00000000,
    ]
    # Glyph 11: CSS Icon (hash grid '#')
    chars[11] = [
        0b00000000,
        0b00100100,
        0b11111111,
        0b00100100,
        0b11111111,
        0b00100100,
        0b00000000,
        0b00000000,
        0b00000000,
        0b00000000,
        0b00000000,
        0b00000000,
        0b00000000,
        0b00000000,
        0b00000000,
        0b00000000,
    ]
    # Glyph 12: Shell Icon (Prompt '$')
    chars[12] = [
        0b00000000,
        0b00010000,
        0b00111100,
        0b01010000,
        0b00111100,
        0b00010100,
        0b00111100,
        0b00010000,
        0b00000000,
        0b00000000,
        0b00000000,
        0b00000000,
        0b00000000,
        0b00000000,
        0b00000000,
        0b00000000,
    ]
    # Glyph 13: Markdown Icon ('M↓')
    chars[13] = [
        0b00000000,
        0b11000110,
        0b11101110,
        0b10111010,
        0b10010010,
        0b00010000,
        0b00111000,
        0b00010000,
        0b00000000,
        0b00000000,
        0b00000000,
        0b00000000,
        0b00000000,
        0b00000000,
        0b00000000,
        0b00000000,
    ]
    # Glyph 14: JSON Icon (braces '{}')
    chars[14] = [
        0b00000000,
        0b00011000,
        0b00100100,
        0b00100000,
        0b00010000,
        0b00100000,
        0b00100100,
        0b00011000,
        0b00000000,
        0b00000000,
        0b00000000,
        0b00000000,
        0b00000000,
        0b00000000,
        0b00000000,
        0b00000000,
    ]
    # Glyph 15: YAML/TOML Config Icon ('Y')
    chars[15] = [
        0b00000000,
        0b11000011,
        0b01100110,
        0b00111100,
        0b00011000,
        0b00011000,
        0b00000000,
        0b00000000,
        0b00000000,
        0b00000000,
        0b00000000,
        0b00000000,
        0b00000000,
        0b00000000,
        0b00000000,
        0b00000000,
    ]
    # Glyph 16: Plain Text Document Icon (folded sheet)
    chars[16] = [
        0b00000000,
        0b01111100,
        0b01000100,
        0b01000100,
        0b01000100,
        0b01111100,
        0b00000000,
        0b00000000,
        0b00000000,
        0b00000000,
        0b00000000,
        0b00000000,
        0b00000000,
        0b00000000,
        0b00000000,
        0b00000000,
    ]

    with open("/home/robby/Pictures/IDEeditor/font.pas", "w") as out:
        out.write("unit font;\n\n{$ASMMODE intel}\n\n")
        out.write("interface\n\n")
        out.write("const\n")
        out.write("  FONT_WIDTH = 8;\n")
        out.write("  FONT_HEIGHT = 16;\n\n")
        out.write("var\n")
        out.write("  FontData: array[0..255, 0..15] of Byte = (\n")
        
        for c in range(256):
            out.write("    (")
            row_strs = [f"${chars[c][r]:02X}" for r in range(16)]
            out.write(", ".join(row_strs))
            if c < 255:
                out.write("),\n")
            else:
                out.write(")\n")
        out.write("  );\n\n")
        
        out.write("procedure DrawCharASM(Dest: Pointer; Pitch, X, Y: Integer; C: Byte; Color: LongWord);\n\n")
        
        out.write("implementation\n\n")
        
        out.write("procedure DrawCharASM(Dest: Pointer; Pitch, X, Y: Integer; C: Byte; Color: LongWord); assembler; nostackframe;\n")
        out.write("asm\n")
        out.write("    // Dest in rdi, Pitch in rsi, X in rdx, Y in rcx, C in r8b, Color in r9d\n")
        out.write("    // Calculate GlyphPtr: FontData + C * 16\n")
        out.write("    lea r10, [FontData]\n")
        out.write("    movzx r8d, r8b\n")
        out.write("    shl r8d, 4\n")
        out.write("    add r10, r8\n")
        out.write("    \n")
        out.write("    // Calculate target address: Dest + Y * Pitch + X * 4\n")
        out.write("    imul rcx, rsi\n")
        out.write("    add rdi, rcx\n")
        out.write("    shl rdx, 2\n")
        out.write("    add rdi, rdx\n")
        out.write("    \n")
        out.write("    xor rax, rax\n")
        out.write("  @row_loop:\n")
        out.write("    movzx edx, byte ptr [r10 + rax]\n")
        out.write("    \n")
        out.write("    test dl, $80\n")
        out.write("    jz @skip0\n")
        out.write("    mov dword ptr [rdi + 0], r9d\n")
        out.write("  @skip0:\n")
        out.write("    test dl, $40\n")
        out.write("    jz @skip1\n")
        out.write("    mov dword ptr [rdi + 4], r9d\n")
        out.write("  @skip1:\n")
        out.write("    test dl, $20\n")
        out.write("    jz @skip2\n")
        out.write("    mov dword ptr [rdi + 8], r9d\n")
        out.write("  @skip2:\n")
        out.write("    test dl, $10\n")
        out.write("    jz @skip3\n")
        out.write("    mov dword ptr [rdi + 12], r9d\n")
        out.write("  @skip3:\n")
        out.write("    test dl, $08\n")
        out.write("    jz @skip4\n")
        out.write("    mov dword ptr [rdi + 16], r9d\n")
        out.write("  @skip4:\n")
        out.write("    test dl, $04\n")
        out.write("    jz @skip5\n")
        out.write("    mov dword ptr [rdi + 20], r9d\n")
        out.write("  @skip5:\n")
        out.write("    test dl, $02\n")
        out.write("    jz @skip6\n")
        out.write("    mov dword ptr [rdi + 24], r9d\n")
        out.write("  @skip6:\n")
        out.write("    test dl, $01\n")
        out.write("    jz @skip7\n")
        out.write("    mov dword ptr [rdi + 28], r9d\n")
        out.write("  @skip7:\n")
        out.write("    \n")
        out.write("    add rdi, rsi\n")
        out.write("    inc rax\n")
        out.write("    cmp rax, 16\n")
        out.write("    jl @row_loop\n")
        out.write("    ret\n")
        out.write("end;\n\n")
        out.write("end.\n")

if __name__ == "__main__":
    main()
