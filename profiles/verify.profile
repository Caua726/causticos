# verify — the desktop, plus the fixtures kernel/fs/fat32.cst's self-test reads.
#
# The regression suite runs against THIS profile, so the kernel it exercises is
# the same binary the desktop profile ships — the suite is selected at boot by
# the `smoke` word on the kernel command line, not by a compile-time switch that
# would make the tested kernel a different one from the delivered kernel.
#
# Sizes below are load-bearing. fat32.cst checks hello.txt is exactly 27 bytes
# (HELLO_EXPECTED_SIZE) and bigfile.bin exactly 1200 (BIGFILE_EXPECTED_SIZE,
# verified as 600 'A' then 600 'B', spanning 3 clusters at 512 B each). The other
# two fixtures are only looked up and read, not content-checked: the long name
# proves LFN matching, /docs/readme.md proves walking into a non-root cluster.

include desktop

# Overrides base's Portuguese greeting — last write wins, which is exactly the
# rule this relies on. 27 bytes, and the self-test says so if it is not.
text /hello.txt Hello from causticos FAT32!

file profiles/fixtures/bigfile.bin /bigfile.bin

# Quoted: the path itself contains spaces, and proving that a name like this
# round-trips through LFN encoding is the entire point of the fixture.
text "/long-name-with-spaces and mixed case.txt" LFN content here

dir /docs
text /docs/readme.md # Docs readme\n\nInside docs subdir.

# The in-system test harnesses. They run from a terminal on the booted machine,
# which is the only place some of them can run at all — a TLS handshake against
# a real server is not something the host can stand in for.
bin runall
bin nett
bin linkt
bin netdt
bin pingt
bin tcpt
bin httpt
bin cryptot
bin x509t
bin tlst
bin appt

# u64t is `opt` because it currently cannot be built: the compiler segfaults on
# tests/u64t.cst whenever --cache is passed, from a cold cache, and only on this
# one file. mkroot reports the skip rather than dropping it silently, and the
# line starts working again the moment the compiler does.
opt bin u64t
