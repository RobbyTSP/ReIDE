all: libhighlighter.so ide

libhighlighter.so: src/lib.rs Cargo.toml
	cargo build --release
	cp target/release/libhighlighter.so ./libhighlighter.so

ide: ide.pas font.pas libhighlighter.so
	fpc -O2 ide.pas -Fl. -k"-rpath=."

clean:
	rm -f ide ide.o ide.or font.o font.ppu libhighlighter.so
	cargo clean

.PHONY: all clean
