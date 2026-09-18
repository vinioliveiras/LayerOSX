#!/bin/sh
# live ISO only — starts just enough to run the install wizard
# fullscreen (GParted + zenity dialogs; see
# opt/layerosx/kiosk/install-wizard.sh). None of this persists onto
# the installed system (see .bash_profile).
openbox &
sleep 1
exec /opt/layerosx/kiosk/install-wizard.sh
