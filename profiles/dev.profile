# dev — the desktop plus the toolchain, so the OS boots able to compile itself.
#
# Every line here is `opt`: the self-hosted compiler is produced by the bootstrap
# (four rounds, byte-identical), which is not part of the normal build. A tree
# that has never run it should still produce a working dev image — one without
# the compiler — rather than failing the build over a file it was never told to
# make. `mkroot --profile dev` reports what it skipped.

include desktop

# The compiler, and the standalone assembler + linker, so the OS has the whole
# toolchain: `caustic` one-shot, or caustic-as | caustic-ld staged.
opt file build/caustic.cse     /caustic.cse
opt file build/caustic-as.cse  /caustic-as.cse
opt file build/caustic-ld.cse  /caustic-ld.cse

# The compiler front-ends only make sense with a compiler present.
opt bin run
opt bin cc
opt bin make
opt bin objdump

# The compiler's own source tree, so it can rebuild itself on the device.
# --only .cst keeps the mirror to sources: object files and build output would
# multiply the image for nothing.
opt mirror $CAUSTIC_DIR/src                /src                --only *.cst
opt mirror $CAUSTIC_DIR/std                /std                --only *.cst
opt mirror $CAUSTIC_DIR/caustic-assembler  /caustic-assembler  --only *.cst
opt mirror $CAUSTIC_DIR/caustic-linker     /caustic-linker     --only *.cst

# A sample source so `run greet.cst` works out of the box.
opt file userspace/tests/greet.cst  /greet.cst
