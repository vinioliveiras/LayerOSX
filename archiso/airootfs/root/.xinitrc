#!/bin/sh
# live ISO só — arranca o essencial pra mostrar o Calamares em ecrã
# cheio. Nada disto persiste no sistema instalado (ver .bash_profile).
openbox &
sleep 1
exec calamares
