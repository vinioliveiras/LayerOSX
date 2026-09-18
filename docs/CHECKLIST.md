# Checklist de build e teste

Nada disto foi validado em hardware real ainda. Isto é o roteiro pra
fazer isso, por ordem, e a lista dos pontos onde é mais provável
precisar de ajuste.

## 1. Preparar a máquina de build

Precisa de correr numa máquina Arch-based com o pacote `archiso`
instalado (a tua CachyOS atual serve, ou podes arrancar o
`archlinux-2026.09.01-x86_64.iso` que já tens em `D:\Downloads` como
ambiente live e instalar o `archiso` lá dentro — o instalador oficial
do Arch não é usado como "base" da nossa ISO, é só um Linux com
internet onde correr o `mkarchiso`).

```sh
sudo pacman -S archiso
git clone <o-teu-repo> LayerOSX
cd LayerOSX/archiso
./build.sh
```

Este passo já vai mostrar se falta algum pacote em
`packages.x86_64` (nomes mudam, versões saem de repo, etc.).

## 2. `customize_airootfs.sh` — o maior ponto de incerteza

Este script compila o `qemus/qemu-macos` (QEMU + Reims-vGPU) e o
`dmg2img` durante o build. Antes do build "a sério":

- Abre https://github.com/qemus/qemu-macos e confirma o comando de
  build atual (o script tenta `build.sh` e depois `meson`, mas isto
  pode ter mudado).
- Confirma que os pacotes de build (`meson`, `ninja`, `pkgconf`,
  `glib2`, `pixman`, `sdl2`, `vulkan-headers`) chegam — o projeto pode
  precisar de mais alguma dependência que ainda não está em
  `packages.x86_64`.
- Se o build falhar aqui, a ISO ainda sai (o script só avisa, não
  trava o `mkarchiso`), mas o `/opt/layerosx/kiosk/mac-vm-launch.sh`
  não vai ter `qemu-system-x86_64` acelerado nenhum.

## 3. Arrancar a ISO numa pen (Ventoy)

- Confirma que arranca em UEFI e mostra o Calamares em fullscreen
  (openbox + `.xinitrc`, autologin root na tty1).
- Só deve aparecer: boas-vindas → partição (interativo, igual ao que
  já fazes hoje: reaproveitar a EFI de ~200 MB, nunca formatar) →
  resumo → a progredir sozinho → concluído.
- Se travar num ecrã preto antes do Calamares aparecer: o problema é o
  `.xinitrc`/`.bash_profile`/autologin da tty1, não o Calamares em si.

## 4. Primeiro arranque do sistema instalado

- Devia arrancar direto no utilizador `mac`, sem pedir password, e
  cair no `macos-source-wizard.sh` (zenity).
- Testa as 3 opções pelo menos uma vez cada, mesmo que só pra ver que
  abrem sem crashar: descarga automática, disco existente, `.dmg`
  existente.
- A opção do `.dmg` é a mais frágil (ver `kiosk/lib/extract-dmg-installer.sh`)
  — se falhar, cai bem (mensagem de erro clara), mas ainda precisa de
  mais trabalho pra suportar instaladores APFS de verdade.

## 5. A VM em si

- Confirma que o `-display sdl,gl=on,full-screen=on` dá ecrã.
- **O ponto mais incerto do projeto inteiro**: a flag exata que ativa
  o dispositivo de vídeo acelerado do Reims-vGPU na linha de comando
  do `qemu-system-x86_64` (ver o `TODO(verificar)` em
  `kiosk/mac-vm-launch.sh`). Sem confirmar isto no README do
  `qemus/qemu-macos`, a VM pode arrancar mas sem aceleração nenhuma
  (só software rendering, lento).
- Confirma teclado/rato USB a funcionar dentro da VM antes de tentares
  instalar/configurar nada.

## 6. Restart / Shutdown físicos

- Dentro do macOS já instalado: testa "Restart" no menu Apple.
  Esperado: a VM fecha, e a máquina física reinicia a sério
  (`systemctl reboot`), não só relança a VM.
- Testa "Shut Down": esperado, a máquina física desliga a sério
  (`systemctl poweroff`).
- Se nenhum dos dois disparar (fica preso em "vm-only" e relança a
  VM): o guest pode não estar a emitir o evento QMP `SHUTDOWN` com o
  `reason` esperado — confirma com `journalctl` / o log em
  `~/mac-vm.log` o que o `qmp-watch.py` recebeu.

## 7. Limpeza automática

- `systemctl status layerosx-cleanup.timer` deve mostrar o timer
  ativo.
- Corre `sudo /usr/local/bin/layerosx-cleanup.sh` manualmente uma
  vez pra confirmar que não rebenta com nada (principalmente o
  `paccache`, que depende do `pacman-contrib` estar mesmo instalado).

## Notas de licenciamento (não é conselho jurídico)

- A ISO gerada por este projeto nunca contém ficheiros da Apple.
- A imagem de recuperação e/ou o `.dmg` são sempre obtidos
  diretamente pela Apple (ou já eram teus) no momento em que TU corres
  o wizard, pro teu próprio disco — nunca embrulhados dentro da ISO
  que distribuis. É a mesma abordagem que o OSX-KVM e a comunidade de
  VMs macOS sempre seguiram.
- Continua a ser contra o EULA da Apple correr macOS fora de hardware
  Apple, aceleração ou não — isto não muda essa realidade.
