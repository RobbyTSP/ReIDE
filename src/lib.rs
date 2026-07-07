use std::ffi::CStr;
use std::os::raw::c_char;
use std::fs::File;
use std::io::{BufRead, BufReader};

// Language IDs
const LANG_PLAIN: u32 = 0;
const LANG_PASCAL: u32 = 1;
const LANG_RUST: u32 = 2;
const LANG_ASM: u32 = 3;
const LANG_MAKEFILE: u32 = 4;
const LANG_C: u32 = 5;
const LANG_PYTHON: u32 = 6;
const LANG_JS_TS: u32 = 7;
const LANG_GO: u32 = 8;
const LANG_HTML_XML: u32 = 9;
const LANG_CSS: u32 = 10;
const LANG_SHELL: u32 = 11;
const LANG_MARKDOWN: u32 = 12;
const LANG_JSON: u32 = 13;
const LANG_YAML_TOML: u32 = 14;

// Color IDs (match colors in Pascal side)
const COL_DEFAULT: u8 = 0;
const COL_KEYWORD: u8 = 1;
const COL_IDENTIFIER: u8 = 2; // general variables/identifiers
const COL_COMMENT: u8 = 3;
const COL_STRING: u8 = 4;
const COL_NUMBER: u8 = 5;
const COL_TYPE: u8 = 6;
const COL_VARIABLE: u8 = 7; // specifically declared variables (like registers or let bindings)

#[no_mangle]
pub unsafe extern "C" fn detect_language(filename: *const c_char) -> u32 {
    if filename.is_null() {
        return LANG_PLAIN;
    }
    let c_str = CStr::from_ptr(filename);
    let path_str = match c_str.to_str() {
        Ok(s) => s,
        Err(_) => return LANG_PLAIN,
    };
    let name = path_str.to_lowercase();

    // Check extension first
    let ext_lang = if name.ends_with(".pas") || name.ends_with(".pp") || name.ends_with(".p") {
        Some(LANG_PASCAL)
    } else if name.ends_with(".rs") {
        Some(LANG_RUST)
    } else if name.ends_with(".asm") || name.ends_with(".s") || name.ends_with(".inc") {
        Some(LANG_ASM)
    } else if name.ends_with("makefile") || name.ends_with(".mk") {
        Some(LANG_MAKEFILE)
    } else if name.ends_with(".c") || name.ends_with(".h") || name.ends_with(".cpp") || name.ends_with(".hpp") || name.ends_with(".cc") {
        Some(LANG_C)
    } else if name.ends_with(".py") || name.ends_with(".pyw") {
        Some(LANG_PYTHON)
    } else if name.ends_with(".js") || name.ends_with(".jsx") || name.ends_with(".ts") || name.ends_with(".tsx") {
        Some(LANG_JS_TS)
    } else if name.ends_with(".go") {
        Some(LANG_GO)
    } else if name.ends_with(".html") || name.ends_with(".htm") || name.ends_with(".xml") {
        Some(LANG_HTML_XML)
    } else if name.ends_with(".css") {
        Some(LANG_CSS)
    } else if name.ends_with(".sh") || name.ends_with(".bash") || name.ends_with(".zsh") {
        Some(LANG_SHELL)
    } else if name.ends_with(".md") || name.ends_with(".markdown") {
        Some(LANG_MARKDOWN)
    } else if name.ends_with(".json") {
        Some(LANG_JSON)
    } else if name.ends_with(".yaml") || name.ends_with(".yml") || name.ends_with(".toml") || name.ends_with(".ini") || name.ends_with(".conf") {
        Some(LANG_YAML_TOML)
    } else {
        None
    };

    if let Some(l) = ext_lang {
        return l;
    }

    // Try reading first line for shebang
    if let Ok(file) = File::open(path_str) {
        let mut reader = BufReader::new(file);
        let mut first_line = String::new();
        if reader.read_line(&mut first_line).is_ok() {
            if first_line.starts_with("#!") {
                let lower = first_line.to_lowercase();
                if lower.contains("python") {
                    return LANG_PYTHON;
                } else if lower.contains("sh") || lower.contains("bash") || lower.contains("zsh") {
                    return LANG_SHELL;
                } else if lower.contains("node") {
                    return LANG_JS_TS;
                } else if lower.contains("perl") {
                    return LANG_PYTHON; // Fallback highlight
                }
            }
        }
    }

    LANG_PLAIN
}

#[no_mangle]
pub unsafe extern "C" fn get_language_icon(lang_id: u32) -> *const c_char {
    match lang_id {
        LANG_PASCAL => "P\0".as_ptr() as *const c_char,
        LANG_RUST => "R\0".as_ptr() as *const c_char,
        LANG_ASM => "A\0".as_ptr() as *const c_char,
        LANG_MAKEFILE => "M\0".as_ptr() as *const c_char,
        LANG_C => "C\0".as_ptr() as *const c_char,
        LANG_PYTHON => "Y\0".as_ptr() as *const c_char,
        LANG_JS_TS => "J\0".as_ptr() as *const c_char,
        LANG_GO => "G\0".as_ptr() as *const c_char,
        LANG_HTML_XML => "H\0".as_ptr() as *const c_char,
        LANG_CSS => "S\0".as_ptr() as *const c_char,
        LANG_SHELL => "B\0".as_ptr() as *const c_char,
        LANG_MARKDOWN => "D\0".as_ptr() as *const c_char,
        LANG_JSON => "N\0".as_ptr() as *const c_char,
        LANG_YAML_TOML => "K\0".as_ptr() as *const c_char,
        _ => "T\0".as_ptr() as *const c_char,
    }
}

// Tokenize line of code. Color categories: Keyword (1), Variable (2/7), Comment (3), String (4), Number (5), Type (6).
#[no_mangle]
pub unsafe extern "C" fn tokenize_line(
    lang_id: u32,
    line: *const c_char,
    colors: *mut u8,
    max_len: u32,
) {
    if line.is_null() || colors.is_null() || max_len == 0 {
        return;
    }

    let c_str = CStr::from_ptr(line);
    let bytes = c_str.to_bytes();
    let len = bytes.len().min(max_len as usize);

    std::slice::from_raw_parts_mut(colors, max_len as usize)[..max_len as usize].fill(COL_DEFAULT);
    let colors_slice = std::slice::from_raw_parts_mut(colors, len);

    let mut i = 0;
    while i < len {
        let c = bytes[i];

        // 1. Comments
        // Pascal { ... } or (* ... *)
        if lang_id == LANG_PASCAL && c == b'{' {
            while i < len {
                colors_slice[i] = COL_COMMENT;
                if bytes[i] == b'}' {
                    i += 1;
                    break;
                }
                i += 1;
            }
            continue;
        }
        if lang_id == LANG_PASCAL && c == b'(' && i + 1 < len && bytes[i + 1] == b'*' {
            colors_slice[i] = COL_COMMENT;
            colors_slice[i + 1] = COL_COMMENT;
            i += 2;
            while i < len {
                colors_slice[i] = COL_COMMENT;
                if bytes[i] == b'*' && i + 1 < len && bytes[i + 1] == b')' {
                    colors_slice[i + 1] = COL_COMMENT;
                    i += 2;
                    break;
                }
                i += 1;
            }
            continue;
        }
        // HTML / XML <!-- ... -->
        if lang_id == LANG_HTML_XML && c == b'<' && i + 3 < len && &bytes[i..i+4] == b"<!--" {
            while i < len {
                colors_slice[i] = COL_COMMENT;
                if i + 2 < len && &bytes[i..i+3] == b"-->" {
                    colors_slice[i] = COL_COMMENT;
                    colors_slice[i+1] = COL_COMMENT;
                    colors_slice[i+2] = COL_COMMENT;
                    i += 3;
                    break;
                }
                i += 1;
            }
            continue;
        }

        // C, JS, Rust, Go standard block comments /* ... */
        if (lang_id == LANG_RUST || lang_id == LANG_C || lang_id == LANG_JS_TS || lang_id == LANG_GO) && c == b'/' && i + 1 < len && bytes[i + 1] == b'*' {
            colors_slice[i] = COL_COMMENT;
            colors_slice[i + 1] = COL_COMMENT;
            i += 2;
            while i < len {
                colors_slice[i] = COL_COMMENT;
                if bytes[i] == b'*' && i + 1 < len && bytes[i + 1] == b'/' {
                    colors_slice[i + 1] = COL_COMMENT;
                    i += 2;
                    break;
                }
                i += 1;
            }
            continue;
        }

        // Line comments: // for Pascal, Rust, C, JS, Go
        if (lang_id == LANG_RUST || lang_id == LANG_C || lang_id == LANG_JS_TS || lang_id == LANG_GO || lang_id == LANG_PASCAL)
            && c == b'/' && i + 1 < len && bytes[i + 1] == b'/' {
            while i < len {
                colors_slice[i] = COL_COMMENT;
                i += 1;
            }
            break;
        }

        // Line comments: # for Python, Makefile, Shell, YAML/TOML
        if (lang_id == LANG_PYTHON || lang_id == LANG_MAKEFILE || lang_id == LANG_SHELL || lang_id == LANG_YAML_TOML) && c == b'#' {
            while i < len {
                colors_slice[i] = COL_COMMENT;
                i += 1;
            }
            break;
        }

        // Line comments: ; for Assembly
        if lang_id == LANG_ASM && c == b';' {
            while i < len {
                colors_slice[i] = COL_COMMENT;
                i += 1;
            }
            break;
        }

        // 2. Strings & Character Literals
        if c == b'\'' || c == b'"' || (c == b'`' && (lang_id == LANG_JS_TS || lang_id == LANG_GO)) {
            let quote = c;
            colors_slice[i] = COL_STRING;
            i += 1;
            let mut escaped = false;
            while i < len {
                colors_slice[i] = COL_STRING;
                if escaped {
                    escaped = false;
                } else if bytes[i] == b'\\' {
                    escaped = true;
                } else if bytes[i] == quote {
                    i += 1;
                    break;
                }
                i += 1;
            }
            continue;
        }

        // 3. Numbers
        if c.is_ascii_digit() || (c == b'$' && lang_id == LANG_PASCAL) || (c == b'0' && i + 1 < len && bytes[i + 1] == b'x') {
            while i < len && (bytes[i].is_ascii_alphanumeric() || bytes[i] == b'.' || bytes[i] == b'$') {
                colors_slice[i] = COL_NUMBER;
                i += 1;
            }
            continue;
        }

        // 4. Identifiers and Keywords
        if c.is_ascii_alphabetic() || c == b'_' {
            let start = i;
            while i < len && (bytes[i].is_ascii_alphanumeric() || bytes[i] == b'_') {
                i += 1;
            }
            let word = &bytes[start..i];
            let word_str = std::str::from_utf8(word).unwrap_or("");

            let color = get_word_color(lang_id, word_str);
            for idx in start..i {
                colors_slice[idx] = color;
            }
            continue;
        }

        colors_slice[i] = COL_DEFAULT;
        i += 1;
    }
}

fn get_word_color(lang_id: u32, word: &str) -> u8 {
    let lower = word.to_lowercase();
    match lang_id {
        LANG_PASCAL => {
            match lower.as_str() {
                "program" | "unit" | "uses" | "begin" | "end" | "var" | "procedure" |
                "function" | "if" | "then" | "else" | "for" | "to" | "do" | "while" |
                "repeat" | "until" | "const" | "type" | "interface" | "implementation" |
                "nil" | "true" | "false" | "and" | "or" | "not" | "xor" | "shl" | "shr" |
                "div" | "mod" | "asm" | "record" | "object" | "class" | "constructor" |
                "destructor" | "out" | "result" | "exit" | "halt" | "try" | "except" |
                "finally" | "case" | "of" => COL_KEYWORD,
                
                "integer" | "string" | "boolean" | "char" | "real" | "pointer" | "longint" |
                "cardinal" | "word" | "byte" | "double" | "single" | "text" | "twindow" |
                "pdisplay" | "txevent" | "dword" => COL_TYPE,

                "self" => COL_VARIABLE,
                _ => COL_IDENTIFIER,
            }
        }
        LANG_RUST => {
            match word {
                "fn" | "let" | "mut" | "pub" | "use" | "mod" | "struct" | "enum" | "impl" |
                "trait" | "for" | "in" | "if" | "else" | "match" | "return" | "unsafe" |
                "const" | "static" | "crate" | "self" | "Self" | "true" | "false" | "as" |
                "where" | "type" | "loop" | "while" | "break" | "continue" | "ref" | "extern" => COL_KEYWORD,
                
                "u8" | "u16" | "u32" | "u64" | "u128" | "usize" |
                "i8" | "i16" | "i32" | "i64" | "i128" | "isize" |
                "f32" | "f64" | "bool" | "char" | "str" | "Option" | "Result" | "String" | "Vec" => COL_TYPE,
                _ => COL_IDENTIFIER,
            }
        }
        LANG_C => {
            match word {
                "if" | "else" | "for" | "while" | "do" | "switch" | "case" | "default" |
                "break" | "continue" | "return" | "goto" | "sizeof" | "typedef" | "struct" |
                "union" | "enum" | "const" | "static" | "extern" | "volatile" | "inline" |
                "register" | "restrict" => COL_KEYWORD,
                
                "int" | "char" | "float" | "double" | "void" | "short" | "long" | "signed" |
                "unsigned" | "size_t" | "int8_t" | "int16_t" | "int32_t" | "int64_t" |
                "uint8_t" | "uint16_t" | "uint32_t" | "uint64_t" | "bool" => COL_TYPE,
                _ => COL_IDENTIFIER,
            }
        }
        LANG_PYTHON => {
            match word {
                "def" | "class" | "return" | "if" | "elif" | "else" | "for" | "while" |
                "break" | "continue" | "import" | "from" | "as" | "in" | "is" | "not" |
                "and" | "or" | "try" | "except" | "finally" | "raise" | "assert" | "global" |
                "nonlocal" | "lambda" | "pass" | "with" | "yield" | "del" | "None" |
                "True" | "False" => COL_KEYWORD,
                
                "int" | "str" | "float" | "bool" | "list" | "dict" | "tuple" | "set" |
                "object" | "type" => COL_TYPE,
                _ => COL_IDENTIFIER,
            }
        }
        LANG_JS_TS => {
            match word {
                "function" | "class" | "let" | "const" | "var" | "return" | "if" | "else" |
                "for" | "while" | "do" | "switch" | "case" | "default" | "break" | "continue" |
                "import" | "export" | "from" | "as" | "default" | "new" | "this" | "super" |
                "try" | "catch" | "finally" | "throw" | "typeof" | "instanceof" | "in" |
                "of" | "true" | "false" | "null" | "undefined" | "async" | "await" | "yield" => COL_KEYWORD,
                
                "number" | "string" | "boolean" | "any" | "void" | "unknown" | "never" |
                "Array" | "Object" | "Promise" | "Map" | "Set" => COL_TYPE,
                _ => COL_IDENTIFIER,
            }
        }
        LANG_GO => {
            match word {
                "func" | "package" | "import" | "const" | "var" | "type" | "struct" |
                "interface" | "return" | "if" | "else" | "for" | "range" | "switch" |
                "case" | "default" | "break" | "continue" | "fallthrough" | "go" | "chan" |
                "select" | "defer" | "map" | "goto" => COL_KEYWORD,
                
                "int" | "int8" | "int16" | "int32" | "int64" |
                "uint" | "uint8" | "uint16" | "uint32" | "uint64" | "uintptr" |
                "float32" | "float64" | "complex64" | "complex128" |
                "string" | "bool" | "byte" | "rune" | "error" => COL_TYPE,
                _ => COL_IDENTIFIER,
            }
        }
        LANG_SHELL => {
            match word {
                "if" | "then" | "elif" | "else" | "fi" | "for" | "while" | "until" | "do" |
                "done" | "case" | "esac" | "in" | "function" | "return" | "exit" | "local" |
                "export" | "alias" | "echo" | "cd" | "pwd" => COL_KEYWORD,
                _ => COL_IDENTIFIER,
            }
        }
        LANG_ASM => {
            match lower.as_str() {
                "mov" | "add" | "sub" | "mul" | "div" | "jmp" | "je" | "jne" | "jg" | "jl" |
                "jge" | "jle" | "cmp" | "push" | "pop" | "call" | "ret" | "int" | "syscall" |
                "xor" | "and" | "or" | "shl" | "shr" | "nop" | "inc" | "dec" | "db" | "dw" |
                "dd" | "dq" | "equ" | "section" | "global" | "extern" | "lea" | "pushfq" | "popfq" => COL_KEYWORD,
                
                // Color standard x86_64 registers as variables
                "rax" | "rbx" | "rcx" | "rdx" | "rsi" | "rdi" | "rbp" | "rsp" |
                "r8" | "r9" | "r10" | "r11" | "r12" | "r13" | "r14" | "r15" |
                "eax" | "ebx" | "ecx" | "edx" | "esi" | "edi" | "ebp" | "esp" |
                "ax" | "bx" | "cx" | "dx" | "si" | "di" | "sp" | "bp" |
                "al" | "bl" | "cl" | "dl" | "ah" | "bh" | "ch" | "dh" |
                "rip" | "eip" => COL_VARIABLE,

                _ => COL_IDENTIFIER,
            }
        }
        LANG_MAKEFILE => {
            match word {
                "all" | "clean" | "ifeq" | "ifneq" | "else" | "endif" | "include" | "define" | "endef" => COL_KEYWORD,
                _ => COL_IDENTIFIER,
            }
        }
        LANG_MARKDOWN => {
            // Stylize markdown markers slightly
            if word.starts_with('#') || word == "link" || word == "image" {
                COL_KEYWORD
            } else {
                COL_IDENTIFIER
            }
        }
        LANG_JSON | LANG_YAML_TOML => {
            // Stylize keys in config files
            if word.chars().next().map_or(false, |ch| ch.is_ascii_alphabetic()) {
                COL_KEYWORD
            } else {
                COL_IDENTIFIER
            }
        }
        _ => COL_IDENTIFIER,
    }
}

#[no_mangle]
pub unsafe extern "C" fn detect_language_from_content(content: *const c_char) -> u32 {
    if content.is_null() {
        return LANG_PLAIN;
    }
    let c_str = CStr::from_ptr(content);
    let text = match c_str.to_str() {
        Ok(s) => s,
        Err(_) => return LANG_PLAIN,
    };
    
    // Check shebangs first
    if text.starts_with("#!") {
        let lower = text.to_lowercase();
        if lower.contains("python") { return LANG_PYTHON; }
        if lower.contains("sh") || lower.contains("bash") || lower.contains("zsh") { return LANG_SHELL; }
        if lower.contains("node") { return LANG_JS_TS; }
    }
    
    // Check key patterns in the content
    if text.contains("program ") || text.contains("unit ") || text.contains("uses ") || text.contains("procedure ") || text.contains("begin\n") || text.contains("begin\r") || text.contains("WriteLn(") {
        return LANG_PASCAL;
    }
    if text.contains("fn main(") || text.contains("use std::") || text.contains("impl ") || text.contains("pub struct ") || text.contains("println!") {
        return LANG_RUST;
    }
    if text.contains("#include <") || text.contains("int main(") || text.contains("void main(") || text.contains("printf(") {
        return LANG_C;
    }
    if text.contains("def ") || text.contains("import sys") || text.contains("print(") {
        return LANG_PYTHON;
    }
    if text.contains("package main") || text.contains("import (") || text.contains("func ") {
        return LANG_GO;
    }
    if text.contains("<!DOCTYPE html>") || text.contains("<html>") || text.contains("<head>") {
        return LANG_HTML_XML;
    }
    if text.contains("console.log(") || (text.contains("const ") && text.contains(" = require(")) || text.contains("function ") && (text.contains("{") || text.contains("}")) {
        return LANG_JS_TS;
    }
    if text.contains("section .text") || text.contains("global _start") || text.contains("mov rax,") || text.contains("mov eax,") {
        return LANG_ASM;
    }
    
    LANG_PLAIN
}
