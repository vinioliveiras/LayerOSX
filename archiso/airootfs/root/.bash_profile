# live ISO only — root autologin em tty1 arranca direto o Calamares.
# (Este ficheiro NÃO vai parar no sistema instalado — o Calamares copia o
# rootfs do live, mas o postinstall troca o autologin para o kiosk do
# macOS antes do primeiro arranque real. Ver postinstall/40-kiosk.sh.)
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
    exec startx /root/.xinitrc
fi
