# LayerOSX

Uma ISO de instalação para um Arch Linux propositadamente vazio, cujo único
trabalho é arrancar diretamente numa VM de macOS acelerada (via
[qemus/qemu-macos](https://github.com/qemus/qemu-macos), que embute o
[Reims-vGPU](https://reims-vgpu.com/)). O objetivo: ligar o portátil, ver o
macOS a arrancar — sem desktop Linux visível, sem passos manuais depois da
instalação (exceto escolher de onde vem o macOS, uma única vez).


## Estado do projeto

Isto ainda **não foi testado em hardware real**. É um esqueleto funcional,
escrito e revisto tecnicamente, mas só se valida a arrancar de verdade numa
pen — a primeira tentativa vai precisar de iteração, principalmente nos dois
pontos mais incertos: o build do `qemus/qemu-macos` dentro de
`customize_airootfs.sh`, e a flag exata de vídeo acelerado do Reims-vGPU em
`kiosk/mac-vm-launch.sh`. Ver `docs/CHECKLIST.md` para o plano de testes
passo a passo.

## Como encaixa tudo

```
Instalador (ISO, arranca da pen Ventoy)
  └── Calamares, só com UI a sério na partição (igual ao que já fazes:
      reaproveitar a EFI de ~200 MB, nunca formatar). Tudo o resto
      (locale=en_US, teclado=us, utilizador, GRUB) fica fixo, sem
      perguntar nada — ver postinstall/*.sh
        └── no fim, corre postinstall/run.sh no sistema instalado
              ├── locale, teclado, hostname, utilizador "mac"
              ├── driver NVIDIA + KVM
              ├── GRUB reaproveitando a EFI existente
              └── autologin do "mac" na tty1 + kiosk

Primeiro arranque do sistema instalado:
  login automático → kiosk/mac-vm-launch.sh
    └── ainda não há VM? → macos-source-wizard.sh (uma pergunta, zenity):
          1. Descarregar a imagem de recuperação direto da Apple (padrão)
          2. Já tenho uma VM/disco de macOS — escolher no disco
          3. Já tenho um instalador .dmg (App Store/outro Mac) — escolher
             no disco (experimental, ver docs/CHECKLIST.md)
    └── QEMU em fullscreen — aqui é onde TU assumes: Disk Utility,
        instalar o macOS, Setup Assistant — isso fica contigo, não é
        automatizado (de propósito: é a parte pessoal, Apple ID, conta)

Depois de instalado o macOS:
  Restart no menu Apple → a máquina física reinicia a sério
  Shut Down no menu Apple → a máquina física desliga a sério
  (mecanismo: QMP + `-no-reboot`, ver kiosk/README.md — decidido assim
  porque um Restart também deve limpar qualquer problema do Arch por
  baixo, não só da VM)
```

## Sobre meter a ISO com o macOS "lá dentro" já pronto

Não dá, e não é isso que este projeto faz. Embrulhar uma imagem/instalador
da Apple dentro da ISO que se distribui seria redistribuir software com
copyright da Apple — problema real, sem tornar isto mais "automático"
nenhum. O que este projeto automatiza é o download/preparação, sempre
correndo no teu próprio hardware, pro teu próprio disco, no momento em que
TU o fazes: a ISO em si nunca leva nada da Apple. É a mesma linha que o
OSX-KVM e toda a comunidade de VMs macOS sempre seguiram — e continua a ser
contra o EULA da Apple correr macOS fora de hardware Apple, com ou sem
aceleração; nada aqui muda essa realidade.

A parte "navegar pelo disco e escolher um `.dmg` mais recente" que querias
está no wizard (opção 3) — é a mais experimental das três, porque instalar
a partir de um `.dmg` real da Apple normalmente significa lidar com uma
imagem APFS, e o suporte a APFS em Linux ainda é limitado.

## Estrutura

- `archiso/` — perfil do `mkarchiso` (vanilla Arch, não CachyOS), com o
  Calamares reduzido a: boas-vindas, partição (UI a sério), resumo
- `archiso/airootfs/root/postinstall/` — scripts que correm no sistema já
  instalado, chrooted, antes do primeiro arranque real
- `archiso/airootfs/opt/layerosx/kiosk/` — o launcher da VM, o wizard
  de primeira execução e o vigia de shutdown/reboot via QMP
- `archiso/airootfs/root/customize_airootfs.sh` — compila o
  `qemus/qemu-macos` e o `dmg2img` durante o build (precisa de rede na
  máquina de build, não na final)
- `docs/CHECKLIST.md` — passo a passo de build e teste, com os pontos que
  mais provavelmente vão precisar de ajuste

## Build

```sh
cd archiso && ./build.sh
```

Precisa de correr numa máquina Arch-based com o pacote `archiso`
instalado (a tua CachyOS serve — ou o
`archlinux-2026.09.01-x86_64.iso` que já tens, arrancado como live
environment, também serve só para este passo). Produz um `.iso` para
arrastar para a pen com o Ventoy.
