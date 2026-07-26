# base — what every root image carries, whatever it boots into.
#
# The tools, and nothing that decides what /init is. A profile that includes
# base picks the init itself; base deliberately does not, so `include base`
# never fights the profile including it.
#
# Names here are target names from userspace/Causticfile. That file is the only
# place a program's source path is written down; if a name below is not a target
# there, the build says so by name instead of silently shipping less.

# The base runtime, shared. Every program on the image imports the syscall
# bindings, the program helpers and futil from this file instead of carrying
# them: their code is NOT in them, so an image without it has programs that load
# and stop at the first unresolved symbol. It ships in base for exactly that
# reason — it is not optional for anything that includes base.
dir  /lib
file userspace/build/libbase.csl   /lib/libbase.csl

# text/file tools
bin  cat
bin  echo
bin  grep
bin  head
bin  tail
bin  wc
bin  sort
bin  uniq
bin  rev
bin  tac
bin  cut
bin  fold
bin  cmp
bin  seq
bin  tr
bin  sed
bin  diff
bin  nl
bin  paste
bin  comm
bin  tee
bin  expand
bin  unexpand
bin  basename
bin  dirname
bin  hexdump
bin  base64
bin  md5sum

# filesystem
bin  ls
bin  touch
bin  mkdir
bin  rmdir
bin  rm
bin  mv
bin  cp
bin  stat
bin  du
bin  tree
bin  find

# shell-shaped odds and ends
bin  clear
bin  true
bin  false
bin  yes
bin  expr
bin  sleep

# system: monitors and the clock
bin  ps
bin  top
bin  btop
bin  htop
bin  free
bin  df
bin  uptime
bin  sysinfo
bin  nproc
bin  lscpu
bin  date

# network. netd is a daemon, not a command: the compositor starts it (it is
# /init, so it is the one process that may), and everything else asks it for an
# endpoint. It is loaded by absolute path from userspace, so it has to be here
# whether or not anyone types its name.
bin  netd
bin  ifconfig
bin  ping
bin  nslookup
bin  arp
bin  wget
bin  nc
bin  httpd
bin  netsnoop

# audio. soundd is the mixer: the kernel hands the stream to one holder at a
# time, and soundd is what makes two programs audible at once. Also loaded by
# absolute path (userspace/lib/sndcli), so it ships regardless.
bin  soundd
bin  aplay
bin  arecord

# power
bin  poweroff
bin  reboot

# viewers/editors — full-screen, through the framebuffer grab stack
bin  vic
bin  pager
bin  hexedit

text /hello.txt  ola do CausticOS! este arquivo veio do root FAT32 via cat.
