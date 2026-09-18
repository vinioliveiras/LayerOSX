# kiosk/ (fica em `/opt/layerosx/kiosk` no sistema instalado)

- **`mac-vm-launch.sh`** — corre em vez de desktop, autologin do
  utilizador `mac` na tty1 (ver `postinstall/40-kiosk-autologin.sh`).
  Garante que existe uma VM (senão chama o wizard), lança o QEMU em
  fullscreen, e fica à espera de um evento QMP `SHUTDOWN` para saber
  se o macOS pediu Shut Down (`reason: guest-shutdown` →
  `systemctl poweroff` a sério) ou Restart
  (`reason: guest-reset`/`guest-panic` → `systemctl reboot` a sério —
  de propósito, reinicia o Arch por baixo também, para o caso de ele
  estar com problemas). Se o QEMU morrer por outro motivo, relança só
  a VM (até 5 vezes seguidas; a partir daí reinicia a máquina física
  por segurança).
- **`qmp-watch.py`** — fala QMP em bruto (JSON lines) num socket Unix,
  devolve `host-poweroff` / `host-reboot` / `vm-only` em stdout.
- **`macos-source-wizard.sh`** — corre uma única vez, na primeira
  execução (quando ainda não existe disco de VM). Pergunta, com uma
  janela `zenity`, se queres: descarregar a imagem de recuperação
  diretamente da Apple, apontar para uma VM/disco que já tens, ou
  apontar para um `.dmg` de instalador que já tens — para poderes
  sempre usar o mais recente que descarregaste no site da Apple / App
  Store noutro Mac.
- **`lib/fetch-recovery.sh`** — usa o `fetch-macOS.py` do projeto
  OSX-KVM para descarregar a imagem de recuperação diretamente dos
  servidores da Apple, para o teu próprio disco.
- **`lib/extract-dmg-installer.sh`** — **experimental**. Tenta extrair
  um instalador arrancável a partir de um `.dmg` que já tens. A parte
  difícil é o sistema de ficheiros lá dentro (HFS+ normalmente
  funciona, APFS em Linux ainda é limitado) — ver `docs/CHECKLIST.md`.

## Sobre licenciamento

Nada aqui contém ficheiros da Apple. O que é descarregado ou usado
(imagem de recuperação, `.dmg`) vem sempre diretamente da Apple ou do
teu próprio ficheiro, para o teu próprio disco, no momento em que TU
correste o wizard — nunca embrulhado dentro da ISO que este projeto
gera. Isto é a mesma linha que o OSX-KVM e a comunidade de
Hackintosh/VMs sempre seguiram: automatizar o download/instalação, sem
nunca redistribuir nada da Apple. Continua a ser contra o EULA da
Apple correr macOS fora de hardware Apple — isto não muda essa
realidade, só automatiza os passos técnicos do lado do Linux.
