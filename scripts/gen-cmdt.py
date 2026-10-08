#!/usr/bin/env python3
"""gen-cmdt.py — the cases userspace/tests/cmdt.cst runs, with GNU's answers.

Each case is a command line, its input and the files it needs; this script
runs the GNU tool on the host to get the output, exit code and files it should
leave, and writes everything to userspace/tests/cmdt.cases, which is committed:
the answers stay fixed, not whatever the host's sed happens to be today.

    python3 scripts/gen-cmdt.py            # regenerate userspace/tests/cmdt.cases

"%D" in arguments, file names, contents and expected text is the case's
directory (a fresh temporary one here, /cmdt/cN on CausticOS). A name in
`files` that ends in '/' is a directory to make; the others are made in the
order given, so a directory comes before what is in it. Programs there
have no working directory, so cases name every file by %D.

A case can carry `want=` when this system answers differently from GNU on
purpose; the reason goes next to it.
"""
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "userspace", "tests", "cmdt.cases")
GNU = {"sed": "/usr/bin/sed", "grep": "/usr/bin/grep", "expr": "/usr/bin/expr", "ls": "/usr/bin/ls", "head": "/usr/bin/head", "wc": "/usr/bin/wc"}

CASES = []


def case(name, prog, args, stdin=b"", files=None, check=None, want=None):
    if isinstance(stdin, str):
        stdin = stdin.encode()
    CASES.append(dict(name=name, prog=prog, args=args, stdin=stdin,
                      files=files or {}, check=check or [], want=want))


def sed(name, args, stdin=b"", **kw):
    case(name, "sed", args, stdin, **kw)


def grep(name, args, stdin=b"", **kw):
    case(name, "grep", args, stdin, **kw)


def expr(name, args, **kw):
    case(name, "expr", args, b"", **kw)


def ls(name, args, **kw):
    case(name, "ls", args, b"", **kw)


L5 = "one\ntwo\nthree\nfour\nfive\n"
FOO = "foo bar foo\nbaz\nfoofoo\n\nqux foo\n"

# ---- sed: s ----
sed("s-basic", ["s/foo/X/"], FOO)
sed("s-g", ["s/foo/X/g"], FOO)
sed("s-nth", ["s/o/0/2"], FOO)
sed("s-nth-g", ["s/o/0/2g"], FOO)
sed("s-nth-missing", ["s/a/b/3"], "aa\n")
sed("s-p", ["-n", "s/foo/X/p"], FOO)
sed("s-I", ["s/FOO/x/I"], FOO)
sed("s-amp", ["s/[0-9][0-9]*/<&>/"], "a12b345\n")
sed("s-amp-escaped", [r"s/a/\&/"], "a\n")
sed("s-bre-groups", [r"s/\(ab\) \(cd\)/\2 \1/"], "ab cd\n")
sed("s-ere-groups", ["-E", r"s/(ab) (cd)/\2 \1/"], "ab cd\n")
sed("s-r-groups", ["-r", r"s/(a+)(b+)/[\2\1]/"], "xaabbby\n")
sed("s-group0", [r"s/b\+/(\0)/"], "abbc\n")
sed("s-newline-repl", [r"s/ /\n/g"], "a b c\n")
sed("s-tab", [r"s/\t/<TAB>/;s/x/\ty/"], "a\tbx\n")
sed("s-backslash-newline", ["s/ /\\\n/"], "a b\n")
sed("s-upper-word", [r"s/\w\+/\u&/g"], "hello big world\n")
sed("s-U", [r"s/.*/\U&/"], "Mixed Case 123\n")
sed("s-U-E", [r"s/\(.*\)-\(.*\)/\U\1\E-\2/"], "abc-def\n")
sed("s-L", ["-E", r"s/(.)(.*)/\1\L\2/"], "HELLO WORLD\n")
sed("s-l", [r"s/.*/\l&/"], "ABC\n")
sed("s-u-L", ["-E", r"s/.*/\u\L&/"], "hELLO\n")
sed("s-utf8-upper", [r"s/.*/\U&/"], "ação çé ünïcode\n")
sed("s-utf8-lower", [r"s/.*/\L&/"], "AÇÃO ÇÉ ДОМ\n")
sed("s-empty-reuse", ["/foo/s//X/g"], FOO)
sed("s-empty-matches", ["s/x*/-/g"], "abc\n")
sed("s-empty-after-match", ["s/a*/x/g"], "baaac\n")
sed("s-caret-g", ["s/^a/X/g"], "aaa\n")
sed("s-dollar", ["s/$/!/"], "a\nb\n")
sed("s-delim-bar", ["s|/usr|/opt|"], "/usr/bin\n")
sed("s-delim-escaped", [r"s,a\,b,X,"], "a,b\n")
sed("s-dot-utf8", ["s/./X/g"], "ção\n")
# glibc's C.UTF-8 refuses a range between non-ASCII characters ("Invalid range
# end"); a range here is code point order, which POSIX leaves to the locale.
sed("s-range-utf8", ["s/[à-ü]/_/g"], "olá você\n", want=(b"ol_ voc_\n", 0, False))
sed("s-3g", ["s/./X/3g"], "abcdef\n")
sed("s-greedy", ["s/a.*b/X/"], "1aXbYb2\n")
sed("s-alt-bre", [r"s/cat\|dog/pet/g"], "cat dog cow\n")
sed("s-alt-ere", ["-E", "s/cat|dog/pet/g"], "cat dog cow\n")
sed("s-plus-bre", [r"s/a\+/X/"], "baaac\n")
sed("s-quest-bre", [r"s/ab\?c/X/g"], "ac abc abbc\n")
sed("s-interval-bre", [r"s/a\{2\}/X/"], "aaaa\n")
sed("s-interval-ere", ["-E", "s/a{2,}/X/"], "baaaab\n")
sed("s-braces-literal-bre", ["s/a{2}/X/"], "a{2}\n")
sed("s-plus-literal-bre", ["s/a+b/X/"], "a+b aab\n")
sed("s-ere-plus-group", ["-E", "s/(foo|bar)+/X/"], "xfoobarfoo!\n")
sed("s-swap-ere", ["-E", r"s/^(.)(.*)$/\2\1/"], "hello\n")
sed("s-classes", ["s/[[:upper:]]/(&)/g;s/[[:digit:]]\\+/#/g"], "AbC 123 d4\n")
sed("s-not-space", ["s/[^[:space:]]\\+/W/g"], "  ab  cd \n")
sed("s-word-boundary", [r"s/\bis\b/IS/g"], "this is his island is\n")
sed("s-word-start-end", [r"s/\<a/A/g;s/b\>/B/g"], "ab bab abab\n")
sed("s-W-s-S", [r"s/\W/_/g;s/\s/!/;s/\S/?/"], "a b-c\n")
sed("s-backref-regex", [r"s/\(.\)\1/<\1\1>/g"], "aabccdee\n")
sed("s-backref-ere", ["-E", r"s/(.)(.)\2\1/[&]/"], "xabbay\n")
sed("s-M-flag", ["N;N;s/^/>/Mg"], "a\nb\nc\n")
sed("s-M-dollar", ["N;s/a$/A/M"], "a\nb\n")
sed("s-buffer-anchors", ["N;s/\\`a/S/M;s/b\\'/E/M"], "a\nb\n")
sed("s-w-file", ["-n", "s/foo/X/w %D/w1"], FOO, check=["%D/w1"])
sed("s-n-p-twice-lines", ["-n", "p;p"], "x\ny\n")
sed("s-long-line", ["s/a/b/g"], "a" * 100000 + "\n")
sed("s-many-commands", [";".join("s/%d/x/" % i for i in range(60))], " ".join(str(i) for i in range(60)) + "\n")
sed("s-no-trailing-newline", ["s/a/b/"], b"xa")
sed("s-p-no-trailing-newline", ["p"], b"a\nb")
sed("s-control-x", [r"s/a/\cA/"], "a\n")
sed("s-hex-dec-oct", [r"s/a/\x41\d066\o103/"], "a\n")

# ---- sed: addresses ----
sed("a-line", ["-n", "2p"], L5)
sed("a-last", ["-n", "$p"], L5)
sed("a-range", ["-n", "2,4p"], L5)
sed("a-regex", ["-n", "/o/p"], L5)
sed("a-regex-range", ["-n", "/two/,/four/p"], L5)
sed("a-plus", ["-n", "2,+2p"], L5)
sed("a-step", ["-n", "0~2p"], L5)
sed("a-step-first", ["-n", "1~3p"], L5)
sed("a-mult", ["-n", "2,~4p"], L5 + "six\nseven\n")
sed("a-zero-re", ["0,/o/d"], L5)
sed("a-one-re", ["1,/o/d"], L5)
sed("a-re-plus", ["/two/,+1d"], L5)
sed("a-backwards", ["-n", "3,1p"], L5)
sed("a-not-last", ["$!d"], L5)
sed("a-not-line", ["2!d"], L5)
sed("a-not-range", ["2,3!d"], L5)
sed("a-I", ["-n", "/TWO/Ip"], L5)
sed("a-custom-delim", ["-n", r"\,o,p"], L5)
sed("a-re-to-last", ["/three/,$d"], L5)
sed("a-count", ["-n", "$="], L5)
sed("a-equals", ["="], "a\nb\n")
sed("a-range-repeats", ["-n", "/t/,/f/p"], L5 + "ten\nx\nfive\n")
sed("a-range-re-same-line", ["-n", "/o/,/o/p"], L5)
sed("a-empty-in-range", ["-n", "/two/,/four/{//!p}"], L5)
sed("a-dollar-empty-input", ["-n", "$p"], "")
sed("a-empty-input", ["p"], "")
sed("a-space-before-bang", ["2 ! d"], L5)

# ---- sed: text commands ----
sed("t-a-classic", ["2a\\\nadded"], L5)
sed("t-a-oneliner", ["2a hello world"], L5)
sed("t-a-leading-space", ["1a\\  indented"], "x\n")
sed("t-a-multiline", ["1a\\\nl1\\\nl2"], "x\ny\n")
sed("t-i", ["3i\\\ninserted"], L5)
sed("t-i-oneliner", ["$i before last"], L5)
sed("t-c", ["2c\\\nchanged"], L5)
sed("t-c-range", ["2,4c\\\nCHANGED"], L5)
sed("t-c-neg", ["$!c\\\nX"], "a\nb\nc\n")
sed("t-a-last", ["$a END"], L5)
sed("t-a-escapes", ["1a a\\tb"], "x\n")
sed("t-a-then-n", ["1{a\\\nX\nn\n}"], "1\n2\n3\n")
sed("t-a-q", ["1{a\\\nX\nq\n}"], "1\n2\n")
sed("t-i-before-d", ["2{i\\\nI\nd\n}"], "1\n2\n3\n")

# ---- sed: flow ----
sed("f-e-twice", ["-e", "1d", "-e", "2d"], L5)
sed("f-file", ["-f", "%D/s.sed"], L5, files={"%D/s.sed": "# drop the first\n1d\ns/o/0/g\n"})
sed("f-hash-n", ["#n\n2p"], L5)
sed("f-comment", ["# a comment\n2d # another\n"], L5)
sed("f-block", ["/o/{s/o/0/;s/e/E/}"], L5)
sed("f-block-nested", ["2,4{/three/!{s/$/!/}}"], L5)
sed("f-block-semicolons", ["2{p;p};3d"], L5)
sed("f-join", [":a;N;$!ba;s/\\n/,/g"], L5)
sed("f-t", ["s/o/0/;ta;s/$/ no/;b;:a;s/$/ yes/"], L5)
sed("f-T", ["s/o/0/;Tz;s/$/ +/;:z"], L5)
sed("f-t-reset", ["s/x/y/;n;tz;s/$/!/;:z"], "x\na\n")
sed("f-uniq", ["$!N;/^\\(.*\\)\\n\\1$/!P;D"], "a\na\nb\nc\nc\nc\nd\n")
sed("f-n-odd", ["n;d"], L5)
sed("f-n-quiet", ["-n", "n;p"], L5)
sed("f-N-last", ["N;s/\\n/+/"], L5)
sed("f-N-quiet-last", ["-n", "N;p"], "1\n2\n3\n")
sed("f-tac", ["1!G;h;$!d"], L5)
sed("f-x", ["x;$!d;x"], L5)
sed("f-H-g", ["-n", "H;${g;s/\\n/:/g;p}"], L5)
sed("f-D-P", ["N;P;D"], L5)
sed("f-q", ["2q"], L5)
sed("f-q-code", ["2q5"], L5)
sed("f-Q", ["2Q"], L5)
sed("f-Q-code", ["3Q7"], L5)
sed("f-q-n", ["-n", "/three/{p;q}"], L5)
sed("f-z", ["2z"], L5)
sed("f-y", ["y/abc/xyz/"], "aabbcc abc\n")
sed("f-y-utf8", ["y/áéç/aec/"], "çá é\n")
sed("f-y-newline", ["N;y/\\n/ /"], "a\nb\n")
sed("f-l", ["-n", "l"], "a\tb\\c\x01\n")
sed("f-l-utf8", ["-n", "l"], "ação\n")
sed("f-l-wrap", ["-n", "l 6"], "abcdefghijk\n")
sed("f-l-nowrap", ["-n", "l 0"], "x" * 100 + "\n")
sed("f-l-option", ["-n", "-l", "10", "l"], "abcdefghijklmnopq\n")
sed("f-l-default-wrap", ["-n", "l"], "y" * 150 + "\n")
sed("f-F", ["F"], "a\n")
sed("f-w", ["-n", "/o/w %D/wo"], L5, check=["%D/wo"])
sed("f-W", ["-n", "N;W %D/wW"], L5, check=["%D/wW"])
sed("f-w-stdout", ["-n", "w /dev/stdout"], "a\nb\n")
sed("f-r", ["2r %D/r1"], L5, files={"%D/r1": "INSERTED\n"})
sed("f-r-last", ["$r %D/r1"], "a\nb\n", files={"%D/r1": "END\n"})
sed("f-r-missing", ["1r %D/nope"], "a\nb\n")
sed("f-R", ["R %D/r2"], "a\nb\nc\n", files={"%D/r2": "1\n2\n"})
sed("f-n-option-after", ["s/a/X/p", "-n"], "abc\nd\n")
sed("f-double-dash", ["--", "s/a/b/"], "a\n")
sed("f-files", ["-n", "$p", "%D/f1", "%D/f2"], "", files={"%D/f1": "1\n2\n", "%D/f2": "3\n4\n"})
sed("f-files-equals", ["=", "%D/f1", "%D/f2"], "", files={"%D/f1": "1\n2\n", "%D/f2": "3\n4\n"})
sed("f-separate", ["-s", "-n", "$p", "%D/f1", "%D/f2"], "", files={"%D/f1": "1\n2\n", "%D/f2": "3\n4\n"})
sed("f-separate-F", ["-s", "1F", "%D/f1", "%D/f2"], "", files={"%D/f1": "1\n2\n", "%D/f2": "3\n4\n"})
sed("f-stdin-dash", ["1d", "%D/f1", "-"], "from stdin\n", files={"%D/f1": "1\n2\n"})
sed("f-inplace", ["-i", "s/o/0/g", "%D/ip"], "", files={"%D/ip": "foo\nbar\n"}, check=["%D/ip"])
sed("f-inplace-backup", ["-i.bak", "1d", "%D/ib"], "", files={"%D/ib": "a\nb\n"}, check=["%D/ib", "%D/ib.bak"])
sed("f-inplace-two", ["-i", "$s/$/!/", "%D/i1", "%D/i2"], "", files={"%D/i1": "a\nb\n", "%D/i2": "c\n"}, check=["%D/i1", "%D/i2"])
sed("f-z-option", ["-z", "s/a/x/"], b"a1\x00a2\x00")
sed("f-null-data-l", ["-z", "-n", "l"], b"a\nb\x00")
sed("f-expression-long", ["--expression=2d", "--quiet", "--expression", "3p"], L5)
sed("f-regexp-extended-long", ["--regexp-extended", "s/(o)/[\\1]/"], "two\n")

# ---- sed: errors (exit code and that something is said) ----
sed("e-unknown-cmd", ["k"], "a\n")
sed("e-unterminated-s", ["s/a/b"], "a\n")
sed("e-unknown-s-option", ["s/a/b/x"], "a\n")
# GNU exits 4 for these two (its "panic" path); they are mistakes in the
# command line, which is 1 everywhere else in both.
sed("e-missing-label", ["b nowhere"], "a\n", want=(b"", 1, True))
sed("e-unmatched-brace", ["{p"], "a\n")
sed("e-unexpected-brace", ["p}"], "a\n")
sed("e-y-lengths", ["y/abc/de/"], "a\n")
sed("e-bad-ref", [r"s/a/\1/"], "a\n")
sed("e-bad-regex", ["-E", "s/(a/x/"], "a\n")
sed("e-missing-file", ["p", "%D/does-not-exist"], "")
sed("e-missing-file-and-good", ["p", "%D/does-not-exist", "%D/g"], "", files={"%D/g": "ok\n"})
sed("e-no-script", [], "a\n")
sed("e-multiple-p", ["s/a/b/pp"], "a\n")
sed("e-zero-nth", ["s/a/b/0"], "a\n")
sed("e-q-two-addresses", ["1,2q"], "a\n")
sed("e-colon-address", ["1:a"], "a\n")
sed("e-extra-chars", ["p x"], "a\n")
sed("e-a-no-text", ["a"], "a\n")
sed("e-invalid-option", ["-k", "p"], "a\n")
sed("e-line-zero", ["0p"], "a\n")
sed("e-inplace-no-files", ["-i", "p"], "a\n", want=(b"", 1, True))

# ---- grep ----
G1 = "apple\nbanana\nCherry\napple pie\npineapple\nfoo bar\n"
grep("g-basic", ["apple"], G1)
grep("g-i", ["-i", "cherry"], G1)
grep("g-v", ["-v", "apple"], G1)
grep("g-c", ["-c", "apple"], G1)
grep("g-n", ["-n", "an"], G1)
grep("g-w", ["-w", "apple"], G1)
grep("g-x", ["-x", "apple"], G1)
grep("g-o", ["-o", "an"], G1)
grep("g-o-i", ["-o", "-i", "A[a-z]"], "An apple And\n")
grep("g-bre-default-alt", ["apple\\|foo"], G1)
grep("g-bre-pipe-literal", ["a|b"], "a|b\nab\n")
grep("g-E-alt", ["-E", "apple|foo"], G1)
grep("g-E-plus", ["-E", "p+le"], G1)
grep("g-bre-plus-literal", ["p+"], "p+\npp\n")
grep("g-F", ["-F", "a.b"], "a.b\naxb\n")
grep("g-F-i", ["-F", "-i", "A.B"], "a.b\naxb\n")
grep("g-e-twice", ["-e", "banana", "-e", "foo"], G1)
grep("g-e-backrefs-own", ["-e", "\\(a\\)\\1", "-e", "\\(b\\)\\1"], "aa\nbb\nab\n")
grep("g-f", ["-f", "%D/pats"], G1, files={"%D/pats": "Cherry\npie\n"})
grep("g-pattern-newlines", ["banana\nfoo"], G1)
grep("g-l", ["-l", "apple", "%D/a", "%D/b"], "", files={"%D/a": "apple\n", "%D/b": "pear\n"})
grep("g-L", ["-L", "apple", "%D/a", "%D/b"], "", files={"%D/a": "apple\n", "%D/b": "pear\n"})
grep("g-H", ["-H", "apple", "%D/a"], "", files={"%D/a": "apple\n"})
grep("g-h", ["-h", "apple", "%D/a", "%D/b"], "", files={"%D/a": "apple\n", "%D/b": "apple tree\n"})
grep("g-multi", ["apple", "%D/a", "%D/b"], "", files={"%D/a": "apple\n", "%D/b": "apple tree\n"})
grep("g-m", ["-m", "2", "apple"], G1)
grep("g-A", ["-A", "1", "banana"], G1)
grep("g-B", ["-B", "2", "Cherry"], G1)
grep("g-C", ["-C", "1", "foo"], G1)
grep("g-q-hit", ["-q", "apple"], G1)
grep("g-q-miss", ["-q", "zzz"], G1)
grep("g-no-match", ["zzz"], G1)
grep("g-bad-regex", ["-E", "(a"], G1)
grep("g-missing-file", ["a", "%D/nope"], "")
grep("g-s-missing-file", ["-s", "a", "%D/nope"], "")
grep("g-backref", ["\\(.\\)\\1"], "abc\naab\nxyzz\n")
grep("g-utf8-dot", ["-o", "^..."], "ação\n")
grep("g-utf8-class", ["-o", "[[:alpha:]]*"], "ação123\n")
grep("g-utf8-i", ["-i", "AÇÃO"], "ação\nacao\n")
grep("g-w-second", ["-w", "foo"], "foobar foo\nfoobar\n")
grep("g-x-o", ["-x", "-o", "apple"], G1)
grep("g-c-v", ["-c", "-v", "a"], G1)
grep("g-empty-pattern", [""], "a\n\nb\n")
grep("g-empty-f", ["-f", "%D/empty"], "a\n", files={"%D/empty": ""})
grep("g-anchors", ["^b.*a$"], G1)
grep("g-interval", ["p\\{2\\}"], G1)
grep("g-classes", ["[[:upper:]]"], G1)

# ---- expr ----
expr("x-group", ["abc", ":", "a\\(.\\)c"])
expr("x-length", ["abc", ":", "a.c"])
expr("x-no-match", ["abc", ":", "x"])
expr("x-no-match-group", ["abc", ":", "x\\(.\\)"])
expr("x-anchored", ["abc", ":", "b"])
expr("x-utf8-length", ["ação", ":", ".*"])
expr("x-match-keyword", ["match", "hello", "h\\(el\\)"])
expr("x-arith", ["3", "+", "4"])
expr("x-bad-regex", ["a", ":", "\\(a"])

# ---- ls (not -l, -s, -i or -t: GNU's show owners, block counts, inodes and
# nanosecond times FAT32 does not have) ----
TREE = {"%D/b.txt": "bb\n", "%D/a.c": "a\n", "%D/c": "ccc\n", "%D/.hid": "", "%D/sub/": None,
        "%D/sub/x": "x\n", "%D/Zed": "", "%D/b.txt~": "", "%D/f10": "", "%D/f2": ""}
ls("l-dir", ["%D"], files=TREE)
ls("l-a", ["-a", "%D"], files=TREE)
ls("l-A", ["-A", "%D"], files=TREE)
ls("l-files", ["%D/c", "%D/a.c"], files=TREE)
ls("l-file-and-dir", ["%D/c", "%D/sub"], files=TREE)
ls("l-two-dirs", ["%D/sub", "%D"], files=TREE)
ls("l-d", ["-d", "%D", "%D/c"], files=TREE)
ls("l-R", ["-R", "%D"], files=TREE)
ls("l-missing", ["%D/nope"], files=TREE)
ls("l-missing-and-file", ["%D/nope", "%D/c"], files=TREE)
ls("l-1", ["-1", "%D"], files=TREE)
ls("l-m", ["-m", "%D"], files=TREE)
ls("l-x", ["-x", "%D"], files=TREE)
ls("l-C", ["-C", "%D"], files=TREE)
ls("l-C-narrow", ["-C", "-w", "20", "%D"], files=TREE)
ls("l-p", ["-p", "%D"], files=TREE)
ls("l-r", ["-r", "%D"], files=TREE)
# (no directory in these two: a directory's size is the filesystem's own)
FLAT = dict((k, v) for k, v in TREE.items() if "sub" not in k)
ls("l-S", ["-S", "%D"], files=FLAT)
ls("l-X", ["-X", "%D"], files=TREE)
ls("l-v", ["-v", "%D"], files=TREE)
ls("l-I", ["-I", "*.txt", "%D"], files=TREE)
ls("l-B", ["-B", "%D"], files=TREE)
ls("l-Q", ["-Q", "%D"], files=TREE)
ls("l-gdf", ["--group-directories-first", "%D"], files=TREE)
ls("l-sort-size", ["--sort=size", "%D"], files=FLAT)
ls("l-bad-option", ["-j", "%D"], files=TREE)
ls("l-v-more", ["-v", "%D"], files=dict(("%D/" + n, "") for n in
   ["a1.tar.gz", "a10.tar.gz", "a2.tar.gz", "a2.tar.gz~", ".h2", ".h10", "x-1.0", "x-1.0~rc1", "x-1.0.1", "README"]))   # (FAT32: "readme" would be README)
ls("l-many", ["%D"], files=dict(("%D/n" + "%04d" % i, "") for i in range(5000)))

# Classic head counts are recognized only as the first argument, like GNU.
case("head-classic-count", "head", ["-3"], L5)
case("head-classic-zero", "head", ["-0"], L5)
case("head-classic-leading-zero", "head", ["-005"], L5)
case("head-classic-file", "head", ["-3", "%D/input"], files={"%D/input": L5})
case("head-classic-modern-precedence", "head", ["-3", "-n", "2"], L5)
case("head-classic-not-first", "head", ["-q", "-3"], L5)
case("head-classic-invalid-suffix", "head", ["-3x"], L5)

# A single count has no column padding; multiple pipe counts stay aligned.
case("wc-stdin-bytes", "wc", ["-c"], b"x" * 58)
case("wc-stdin-words", "wc", ["-w"], "one two\n")
case("wc-stdin-empty", "wc", ["-c"])
case("wc-stdin-lines", "wc", ["-l"], L5)
case("wc-stdin-chars", "wc", ["-m"], "é日\n")
case("wc-stdin-longest", "wc", ["-L"], "a\tb\n")
case("wc-stdin-repeated-option", "wc", ["-cc"], "abc")
case("wc-stdin-two-counts", "wc", ["-lc"], L5)
case("wc-stdin-default-counts", "wc", [], L5)


def run(c):
    d = tempfile.mkdtemp(prefix="cmdt-")
    try:
        sub = lambda s: s.replace("%D", d)
        for path, content in c["files"].items():
            if path.endswith("/"):
                os.makedirs(sub(path), exist_ok=True)
                continue
            if isinstance(content, str):
                content = content.encode()
            with open(sub(path), "wb") as f:
                f.write(content.replace(b"%D", d.encode()))
        env = dict(os.environ, LC_ALL="C.UTF-8")
        env.pop("POSIXLY_CORRECT", None)
        p = subprocess.run([GNU[c["prog"]]] + [sub(a) for a in c["args"]],
                           input=c["stdin"], capture_output=True, env=env, cwd=d, timeout=20)
        out = p.stdout.replace(d.encode(), b"%D")
        files = []
        for path in c["check"]:
            try:
                with open(sub(path), "rb") as f:
                    files.append((path, f.read().replace(d.encode(), b"%D")))
            except FileNotFoundError:
                sys.exit("%s: GNU %s left no %s" % (c["name"], c["prog"], path))
        return out, p.returncode, len(p.stderr) > 0, files
    finally:
        shutil.rmtree(d)


def blob(b):
    return str(len(b)).encode() + b"\n" + b + b"\n"


def main():
    parts = []
    for c in CASES:
        out, code, err, files = run(c)
        if c["want"] is not None:
            out, code, err = c["want"]
        parts.append(b"T " + c["name"].encode() + b"\n")
        parts.append(b"P /" + c["prog"].encode() + b".cse\n")
        for path, content in c["files"].items():
            if path.endswith("/"):
                parts.append(b"M " + path.rstrip("/").encode() + b"\n")
                continue
            if isinstance(content, str):
                content = content.encode()
            parts.append(b"F " + path.encode() + b"\n" + blob(content))
        for a in c["args"]:
            parts.append(b"A " + blob(a.encode()))
        if c["stdin"]:
            parts.append(b"I " + blob(c["stdin"]))
        parts.append(b"O " + blob(out))
        parts.append(b"C " + str(code).encode() + b"\n")
        if err:
            parts.append(b"E\n")
        for path, content in files:
            parts.append(b"G " + path.encode() + b"\n" + blob(content))
        parts.append(b".\n")
    data = b"".join(parts)
    with open(OUT, "wb") as f:
        f.write(data)
    print("%d cases, %d bytes -> %s" % (len(CASES), len(data), os.path.relpath(OUT, ROOT)))


if __name__ == "__main__":
    main()
