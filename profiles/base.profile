# base — what every root image carries, whatever it boots into.
#
# The tools, and nothing that decides what /init is. A profile that includes
# base picks the init itself; base deliberately does not, so `include base`
# never fights the profile including it.
#
# Names here are target names from userspace/Causticfile. That file is the only
# place a program's source path is written down; if a name below is not a target
# there, the build says so by name instead of silently shipping less.

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

# power
bin  poweroff
bin  reboot

# viewers/editors — full-screen, through the framebuffer grab stack
bin  vic
bin  pager
bin  hexedit

text /hello.txt  ola do CausticOS! este arquivo veio do root FAT32 via cat.
