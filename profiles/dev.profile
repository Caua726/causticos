# dev — the desktop plus the toolchain, so the OS boots able to compile itself.
#
# The compiler, assembler and linker are `tool`s: cross-built from $CAUSTIC_DIR
# by `caustic-mk run build -- --profile dev`, and refused at packing time when
# they are older than their sources. The /src and /std mirrored below come from
# the same $CAUSTIC_DIR, so the compiler on the image is always the one built
# from the source beside it. scripts/bootstrap.sh proves it on the device: the
# shipped compiler rebuilds itself there, byte-identical, four rounds running.
#
# Nothing here is `opt`. A dev image without its compiler, or with a compiler
# that does not match its /std, is the failure this profile exists to rule out.
#
# Memory: the 64M default compiles small programs (`run /greet.cst`). Rebuilding
# the compiler itself takes about 121 MB at its low point — boot with 256M for
# that (`caustic-mk run run -- --profile dev -m 256M`).

include desktop

# The compiler, and the standalone assembler + linker, so the OS has the whole
# toolchain: `caustic` one-shot, or caustic-as | caustic-ld staged.
tool caustic-cse     /caustic.cse
tool caustic-as-cse  /caustic-as.cse
tool caustic-ld-cse  /caustic-ld.cse

# The compiler front-ends.
bin run
bin cc
bin make
bin objdump

# The compiler's own source tree, so it can rebuild itself on the device.
# --only .cst keeps the mirror to sources: object files and build output would
# multiply the image for nothing.
mirror $CAUSTIC_DIR/src                /src                --only *.cst
mirror $CAUSTIC_DIR/std                /std                --only *.cst
mirror $CAUSTIC_DIR/caustic-assembler  /caustic-assembler  --only *.cst
mirror $CAUSTIC_DIR/caustic-linker     /caustic-linker     --only *.cst

# A sample source so `run greet.cst` works out of the box.
file userspace/tests/greet.cst  /greet.cst
