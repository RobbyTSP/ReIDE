# ReIDE

ReIDE is an ultra-lightweight, high-performance, and adaptive dark-mode IDE built from the ground up utilizing **x86_64 Assembly**, **Free Pascal (FPC)**, and **Rust**. It runs directly on the X11 windowing system with zero heavy dependencies (no electron, no web-tech, no massive UI frameworks).

![License](https://img.shields.io/badge/license-AGPLv3-blue.svg)
![Language](https://img.shields.io/badge/language-Pascal%20%2F%20ASM%20%2F%20Rust-orange.svg)

---

## 🚀 Key Features

- **Hybrid Architecture**:
  - **Assembly (x86_64)**: Optimized register-based char/icon blitter (`font.pas`) with zero stack frame overhead.
  - **Free Pascal**: GUI framework, tab manager, X11 event loop, and Unix pseudo-terminal (PTY) shell spawner.
  - **Rust**: High-performance tokenizer, code syntax highlighter, and shebang-based language detector.
- **Universal Language Highlighting**: Dynamically parses shebang headers (`#!/bin/bash`, `#!/usr/bin/env python`) and file extensions to support 15+ languages (Pascal, Rust, ASM, C/C++, Python, Go, JS/TS, HTML, CSS, Markdown, JSON, YAML/TOML).
- **Responsive Layout & Buffer Resizing**: Listens to X11 `ConfigureNotify` events. Resizing the window reallocates the framebuffer on the fly, adjusts text scrolls, and scales the terminal dimensions dynamically.
- **Integrated PTY Shell Terminals**: Multiple concurrent terminal tabs at the bottom with standard ANSI escape color parsing and process monitoring (automatically respawns shells if they exit).
- **Live Debugger Panel**: Dedicated `"Logs"` tab displaying internal events (FFI calls, keys, window resizes) in real-time, backed up by file logs in `/home/USER/.reide/logs/ide.log`.
- **Session Persistence**: Saves and restores your workspace, active tabs, and cursor offsets automatically when you close and reopen the editor.
- **Top Utility Menu**: Interactive buttons `[ New ] [ Open ] [ Save ] [ Save As ]` for mouse-driven workflows.

---

## ⌨️ Keyboard Shortcuts

| Shortcut | Action |
| --- | --- |
| **`Ctrl + N`** | Instantly create a new untitled buffer in a new tab |
| **`Ctrl + O`** | Open / Create file path input prompt |
| **`Ctrl + S`** | Save current active file |
| **`Ctrl + A`** | Clear all text in the active tab (reset cursor to `0,0`) |
| **`Ctrl + F`** | Search text in active document (scrolls automatically) |
| **`Ctrl + Q`** | Safe Exit (saves session files & cursor positions) |

---

## 🛠️ Build & Installation

### Prerequisites

You need the Free Pascal Compiler, Cargo (Rust), and X11 development headers installed on your system.

**Debian / Ubuntu**:
```bash
sudo apt update
sudo apt install fpc cargo libx11-dev make
```

### Compilation

Compile the Rust shared library and FPC binary in one step using the provided Makefile:
```bash
make
```

### Running

To launch the IDE:
```bash
./ide
```

To open specific files directly in new tabs:
```bash
./ide main.pas src/lib.rs Makefile
```

---

## 📁 Project Structure

- `ide.pas` — Main loop, X11 layout, text buffers, mouse/keyboard handler, PTY shell manager, and settings.
- `font.pas` — Contains the 8x16 console bitmap font and the custom x86_64 assembly blitter routines (`DrawCharASM`).
- `src/lib.rs` — Rust FFI library for tokenization, language detection, and custom tab icons.
- `extract_font.py` — Utility script to extract system console fonts and format them as FPC arrays.
- `Makefile` — Build script orchestrating Cargo and FPC compilers.

---

## 📝 License

This project is licensed under the GNU Affero General Public License v3 (AGPLv3). See the [LICENSE](file:///home/robby/Pictures/IDEeditor/LICENSE) file for details.
