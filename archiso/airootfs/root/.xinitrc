#!/bin/sh
# live ISO only — starts just enough to run the install wizard
# fullscreen (GParted + zenity dialogs; see
# opt/layerosx/kiosk/install-wizard.sh). None of this persists onto
# the installed system (see .bash_profile).
#
# Must run BEFORE `openbox &` -- it edits openbox's config, which is
# only read at startup (see lib/install-f2-keybind.sh).
/opt/layerosx/kiosk/lib/install-f2-keybind.sh /var/log/layerosx-install.log
openbox &
sleep 1
/opt/layerosx/kiosk/lib/force-max-refresh.sh &
exec /opt/layerosx/kiosk/install-wizard.sh
