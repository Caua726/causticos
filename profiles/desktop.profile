# desktop — the default. The system as it actually is: compositor, window
# manager, terminal, launcher, and the tools.
#
# /init is the COMPOSITOR, not the window manager. The compositor is the
# mechanism half — it owns the framebuffer and the input devices and hands the
# device fds down to /wm.cse through fdacts. The window manager is the policy
# half: geometry, focus, decoration. Installing wm.cse as /init (which one of
# the old seed scripts still did) skips the compositor entirely.

include base

init compositor

bin  wm
bin  launcher
bin  wterm
bin  newterm
bin  wmpat

# The window manager's shipped configuration. /var/wm/config.cst — the user's —
# is read after this one and overrides it key by key, and /var/wm also holds the
# saved layout. The directory has to exist for either to work.
file userspace/wm/wm.default.cst  /etc/wm.cst
dir  /var/wm

# The shared-library demo: a 1 KB program whose code lives in /lib. Proves the
# whole path — import table in the .cse, kernel resolving it at spawn against
# the .csl's export table — on a booted machine rather than on paper.
dir  /lib
file userspace/build/libdyndemo.csl  /lib/libdyndemo.csl
file userspace/build/libdyndemo2.csl /lib/libdyndemo2.csl
bin  dyntest
