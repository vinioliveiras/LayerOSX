#!/bin/sh
# live ISO only — starts just enough to show Calamares fullscreen.
# None of this persists onto the installed system (see .bash_profile).
openbox &
sleep 1
exec calamares
