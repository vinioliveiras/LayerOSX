#!/bin/sh
# live ISO only — starts just enough to run the install wizard
# fullscreen (GParted + zenity dialogs; see
# opt/layerosx/kiosk/install-wizard.sh). None of this persists onto
# the installed system (see .bash_profile).
#
# Must run BEFORE `openbox &` -- it edits openbox's config, which is
# only read at startup (see lib/install-f2-keybind.sh).
# Same window look as the installed system: no desktop portals (GTK4 zenity
# would ask systemd for one that isn't there), and picom for the rounded
# corners and open/close animations (kiosk/picom.conf).
export GDK_DEBUG=no-portals GTK_USE_PORTAL=0
/opt/layerosx/kiosk/lib/install-f2-keybind.sh /var/log/layerosx-install.log
openbox &
sleep 1
command -v picom >/dev/null 2>&1 && picom -b --config /opt/layerosx/kiosk/picom.conf 2>>/var/log/layerosx-picom.log
/opt/layerosx/kiosk/lib/force-max-refresh.sh &
exec /opt/layerosx/kiosk/install-wizard.sh
