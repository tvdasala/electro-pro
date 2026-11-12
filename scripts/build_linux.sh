#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DIST_LINUX="${ROOT_DIR}/Linux"
BUILD_TMP="/tmp/epno_linux_build"
ZIG="/tmp/zig-macos-aarch64-0.13.0/zig"

echo "=========================================================="
echo "  Compilando Electro Piano para Ubuntu e Arch Linux       "
echo "=========================================================="

if [ ! -f "${ZIG}" ]; then
    echo "Erro: Zig compilador não encontrado em ${ZIG}."
    exit 1
fi

rm -rf "${DIST_LINUX}" "${BUILD_TMP}"
mkdir -p "${DIST_LINUX}/Electro Piano.vst3/Contents/x86_64-linux"
mkdir -p "${BUILD_TMP}"

echo "[1/6] Compilando Standalone Executable (x86_64-linux-gnu)..."
"${ZIG}" c++ -target x86_64-linux-gnu.2.31 -std=c++20 -O3 -Wl,-s \
    -ISources/NPNOKit/include -ISources/Linux \
    Sources/Linux/LinuxStandaloneMain.cpp \
    Sources/Linux/LinuxNordPanel.cpp \
    Sources/Linux/LinuxNordCore.cpp \
    Sources/NPNOKit/Document.cpp \
    Sources/NPNOKit/Instrument.cpp \
    Sources/NPNOKit/Engine.cpp \
    -o "${DIST_LINUX}/ElectroPiano"
chmod +x "${DIST_LINUX}/ElectroPiano"

echo "[2/6] Compilando VST3 Plugin Shared Library (x86_64-linux-gnu)..."
"${ZIG}" c++ -target x86_64-linux-gnu.2.31 -std=c++20 -O3 -fPIC -shared -Wl,-s \
    -ISources/NPNOKit/include -ISources/Linux \
    Sources/Linux/LinuxVST3Plugin.cpp \
    Sources/Linux/LinuxNordPanel.cpp \
    Sources/Linux/LinuxNordCore.cpp \
    Sources/NPNOKit/Document.cpp \
    Sources/NPNOKit/Instrument.cpp \
    Sources/NPNOKit/Engine.cpp \
    -o "${DIST_LINUX}/Electro Piano.vst3/Contents/x86_64-linux/Electro Piano.so"
chmod +x "${DIST_LINUX}/Electro Piano.vst3/Contents/x86_64-linux/Electro Piano.so"

echo "[3/6] Copiando ícone e gerando .desktop..."
cp "${ROOT_DIR}/Resources/AppIcon_1024.png" "${DIST_LINUX}/electro-piano.png"

cat << 'EOF' > "${DIST_LINUX}/electro-piano.desktop"
[Desktop Entry]
Version=1.0
Type=Application
Name=Electro Piano
GenericName=Virtual Piano Workstation
Comment=Nord Piano Workstation Player & VST3 Plugin
Exec=ElectroPiano
Icon=electro-piano
Terminal=false
Categories=AudioVideo;Audio;Music;Sequencer;Midi;
Keywords=piano;nord;npno;vst;vst3;audio;synth;
StartupNotify=true
EOF

echo "[4/6] Gerando scripts de instalacao universal..."
cat << 'EOF' > "${DIST_LINUX}/install.sh"
#!/usr/bin/env bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=========================================================="
echo "  Instalador Universal - Electro Piano (Ubuntu / Arch)   "
echo "=========================================================="

# Verifica se é root ou se tem sudo
if [ "$EUID" -ne 0 ]; then
    SUDO="sudo"
else
    SUDO=""
fi

echo "[1/4] Instalando executável Standalone em /usr/local/bin..."
$SUDO cp -f "${DIR}/ElectroPiano" /usr/local/bin/
$SUDO chmod 755 /usr/local/bin/ElectroPiano

echo "[2/4] Instalando Plugin VST3 em /usr/lib/vst3..."
$SUDO mkdir -p /usr/lib/vst3
$SUDO rm -rf "/usr/lib/vst3/Electro Piano.vst3"
$SUDO cp -r "${DIR}/Electro Piano.vst3" /usr/lib/vst3/
$SUDO chmod -R 755 "/usr/lib/vst3/Electro Piano.vst3"

# Instala também na pasta do usuário para DAWs de usuário
mkdir -p "${HOME}/.vst3"
rm -rf "${HOME}/.vst3/Electro Piano.vst3"
cp -r "${DIR}/Electro Piano.vst3" "${HOME}/.vst3/"

echo "[3/4] Instalando ícone e atalho no menu de aplicativos..."
$SUDO mkdir -p /usr/share/icons/hicolor/512x512/apps
$SUDO cp -f "${DIR}/electro-piano.png" /usr/share/icons/hicolor/512x512/apps/electro-piano.png
$SUDO mkdir -p /usr/share/applications
$SUDO cp -f "${DIR}/electro-piano.desktop" /usr/share/applications/

# Atualiza bancos de dados de desktop e ícones se ferramentas existirem
which update-desktop-database >/dev/null 2>&1 && $SUDO update-desktop-database || true
which gtk-update-icon-cache >/dev/null 2>&1 && $SUDO gtk-update-icon-cache -f -t /usr/share/icons/hicolor || true

echo "[4/4] Pronto!"
echo ""
echo "Instalação concluída com sucesso!"
echo "-> Standalone: Digite 'ElectroPiano' no terminal ou abra pelo menu de aplicativos."
echo "-> Plugin VST3: Disponível no Reaper, Bitwig, Ardour, Renoise, Carla (/usr/lib/vst3/ ou ~/.vst3/)."
echo ""
EOF
chmod +x "${DIST_LINUX}/install.sh"

cat << 'EOF' > "${DIST_LINUX}/uninstall.sh"
#!/usr/bin/env bash
set -e

if [ "$EUID" -ne 0 ]; then
    SUDO="sudo"
else
    SUDO=""
fi

echo "Desinstalando Electro Piano..."
$SUDO rm -f /usr/local/bin/ElectroPiano
$SUDO rm -rf "/usr/lib/vst3/Electro Piano.vst3"
rm -rf "${HOME}/.vst3/Electro Piano.vst3"
$SUDO rm -f /usr/share/icons/hicolor/512x512/apps/electro-piano.png
$SUDO rm -f /usr/share/applications/electro-piano.desktop

which update-desktop-database >/dev/null 2>&1 && $SUDO update-desktop-database || true
echo "Electro Piano desinstalado com sucesso."
EOF
chmod +x "${DIST_LINUX}/uninstall.sh"

echo "[5/6] Construindo pacote nativo .deb para Ubuntu / Debian..."
DEB_DIR="${BUILD_TMP}/deb"
mkdir -p "${DEB_DIR}/DEBIAN"
mkdir -p "${DEB_DIR}/usr/bin"
mkdir -p "${DEB_DIR}/usr/lib/vst3"
mkdir -p "${DEB_DIR}/usr/share/applications"
mkdir -p "${DEB_DIR}/usr/share/icons/hicolor/512x512/apps"

cp "${DIST_LINUX}/ElectroPiano" "${DEB_DIR}/usr/bin/"
cp -r "${DIST_LINUX}/Electro Piano.vst3" "${DEB_DIR}/usr/lib/vst3/"
cp "${DIST_LINUX}/electro-piano.desktop" "${DEB_DIR}/usr/share/applications/"
cp "${DIST_LINUX}/electro-piano.png" "${DEB_DIR}/usr/share/icons/hicolor/512x512/apps/"

INST_SIZE=$(du -sk "${DEB_DIR}/usr" | awk '{print $1}')

cat << EOF > "${DEB_DIR}/DEBIAN/control"
Package: electro-piano
Version: 1.0.0
Section: sound
Priority: optional
Architecture: amd64
Installed-Size: ${INST_SIZE}
Maintainer: Electro Pro Audio <support@electropro.internal>
Description: Nord Piano Workstation Player & VST3 Plugin
 High-performance virtual piano player and VST3 plugin capable of playing
 Nord Piano Library (.npno) sample instruments natively on Linux.
 Supports ALSA, PipeWire, PulseAudio, and hardware MIDI controllers.
EOF

# Empacota em .deb padrão
(
    cd "${DEB_DIR}"
    echo "2.0" > debian-binary
    tar -czf control.tar.gz -C DEBIAN control
    tar -czf data.tar.gz -C . usr
    python3 -c '
import os, time, sys

def make_ar(archive_path, files):
    with open(archive_path, "wb") as out:
        out.write(b"!<arch>\n")
        for fname in files:
            base = os.path.basename(fname)
            size = os.path.getsize(fname)
            mtime = int(time.time())
            name_field = base.ljust(16)
            mtime_field = str(mtime).ljust(12)
            owner_field = "0".ljust(6)
            group_field = "0".ljust(6)
            mode_field = "100644".ljust(8)
            size_field = str(size).ljust(10)
            trailer = b"`\n"
            header = (name_field + mtime_field + owner_field + group_field + mode_field + size_field).encode("ascii") + trailer
            assert len(header) == 60
            out.write(header)
            with open(fname, "rb") as f:
                out.write(f.read())
            if size % 2 != 0:
                out.write(b"\n")

make_ar(sys.argv[1], sys.argv[2:])
' "${DIST_LINUX}/electro-piano_1.0.0_amd64.deb" debian-binary control.tar.gz data.tar.gz
)

echo "[6/6] Construindo pacote nativo e PKGBUILD para Arch Linux..."
cat << 'EOF' > "${DIST_LINUX}/PKGBUILD"
# Maintainer: Electro Pro Audio <support@electropro.internal>
pkgname=electro-piano
pkgver=1.0.0
pkgrel=1
pkgdesc="Nord Piano Workstation Player & VST3 Plugin"
arch=('x86_64')
url="https://github.com/electro-pro"
license=('custom')
depends=('alsa-lib' 'libx11')
optdepends=(
    'pipewire-alsa: Suporte a PipeWire Audio'
    'pulseaudio-alsa: Suporte a PulseAudio'
)
source=()

package() {
    install -Dm755 "${srcdir}/ElectroPiano" "${pkgdir}/usr/bin/ElectroPiano"
    mkdir -p "${pkgdir}/usr/lib/vst3"
    cp -r "${srcdir}/Electro Piano.vst3" "${pkgdir}/usr/lib/vst3/"
    install -Dm644 "${srcdir}/electro-piano.desktop" "${pkgdir}/usr/share/applications/electro-piano.desktop"
    install -Dm644 "${srcdir}/electro-piano.png" "${pkgdir}/usr/share/icons/hicolor/512x512/apps/electro-piano.png"
}
EOF

ARCH_DIR="${BUILD_TMP}/arch"
mkdir -p "${ARCH_DIR}/usr/bin"
mkdir -p "${ARCH_DIR}/usr/lib/vst3"
mkdir -p "${ARCH_DIR}/usr/share/applications"
mkdir -p "${ARCH_DIR}/usr/share/icons/hicolor/512x512/apps"

cp "${DIST_LINUX}/ElectroPiano" "${ARCH_DIR}/usr/bin/"
cp -r "${DIST_LINUX}/Electro Piano.vst3" "${ARCH_DIR}/usr/lib/vst3/"
cp "${DIST_LINUX}/electro-piano.desktop" "${ARCH_DIR}/usr/share/applications/"
cp "${DIST_LINUX}/electro-piano.png" "${ARCH_DIR}/usr/share/icons/hicolor/512x512/apps/"

ARCH_SIZE=$(du -sb "${ARCH_DIR}/usr" 2>/dev/null | awk '{print $1}')
if [ -z "${ARCH_SIZE}" ]; then
    ARCH_SIZE=$(du -sk "${ARCH_DIR}/usr" | awk '{print $1 * 1024}')
fi

cat << EOF > "${ARCH_DIR}/.PKGINFO"
pkgname = electro-piano
pkgver = 1.0.0-1
pkgdesc = Nord Piano Workstation Player & VST3 Plugin
url = https://github.com/electro-pro
builddate = $(date +%s)
packager = Electro Pro Audio <support@electropro.internal>
size = ${ARCH_SIZE}
arch = x86_64
license = custom
depend = alsa-lib
depend = libx11
optdepend = pipewire-alsa: Suporte a PipeWire Audio
optdepend = pulseaudio-alsa: Suporte a PulseAudio
EOF

# Empacota o pacote do Arch Linux (.pkg.tar.zst)
(
    cd "${ARCH_DIR}"
    tar -cf - .PKGINFO usr | zstd -c -T0 -19 > "${DIST_LINUX}/electro-piano-1.0.0-1-x86_64.pkg.tar.zst"
)

cat << 'EOF' > "${DIST_LINUX}/LEIA-ME.txt"
================================================================================
  ELECTRO PIANO - PACOTE NATIVO PARA LINUX (UBUNTU / DEBIAN & ARCH LINUX)
================================================================================

Este pacote contém o reprodutor virtual de alta fidelidade e plugin VST3
para instrumentos da Nord Piano Library (.npno), compilado nativamente para
distribuições Linux x86_64 (glibc 2.31+), com suporte total a:
- Ubuntu 20.04 LTS, Ubuntu 22.04 LTS, Ubuntu 24.04 LTS
- Debian 11 (Bullseye), Debian 12 (Bookworm)
- Arch Linux, Manjaro, EndeavourOS
- DAWs: Reaper, Bitwig Studio, Ardour, Renoise, Carla, Waveform

CONTEÚDO DO PACOTE:
-------------------
1. ElectroPiano (Aplicativo Standalone independente com interface gráfica)
2. Electro Piano.vst3 (Plugin VST3 nativo para DAWs Linux)
3. electro-piano_1.0.0_amd64.deb (Pacote oficial para Ubuntu / Debian / Mint)
4. electro-piano-1.0.0-1-x86_64.pkg.tar.zst (Pacote oficial para Arch Linux / Pacman)
5. install.sh (Script de instalação universal com 1 clique)
6. uninstall.sh (Script de desinstalação limpa)

================================================================================
COMO INSTALAR:
================================================================================

OPÇÃO A: Instalação no Ubuntu / Debian / Pop!_OS / Linux Mint
-------------------------------------------------------------
Abra o terminal nesta pasta e execute:
   sudo apt install ./electro-piano_1.0.0_amd64.deb

Ou via dpkg:
   sudo dpkg -i electro-piano_1.0.0_amd64.deb
   sudo apt-get install -f

OPÇÃO B: Instalação no Arch Linux / Manjaro / EndeavourOS
--------------------------------------------------------
Abra o terminal nesta pasta e execute:
   sudo pacman -U electro-piano-1.0.0-1-x86_64.pkg.tar.zst

OPÇÃO C: Instalação Universal com 1 Clique (Qualquer Distro)
------------------------------------------------------------
   chmod +x install.sh
   ./install.sh

OPÇÃO D: Modo Portátil (Sem Instalação)
---------------------------------------
Para rodar sem instalar no sistema:
   chmod +x ElectroPiano
   ./ElectroPiano

Para usar o VST3 de forma portátil, basta copiar a pasta "Electro Piano.vst3"
para:
   ~/.vst3/

================================================================================
ONDE COLOCAR OS TIMBRES (.npno) E CARREGAMENTO AUTOMÁTICO:
================================================================================
O Electro Piano realiza busca e carregamento automático de timbres nas seguintes pastas:
1. ./Sounds/ (ao lado do app ou dentro da sessão da DAW)
2. ./timbres/ (ao lado do app ou do plugin)
3. ~/.vst3/Sounds/ ou ~/.vst3/timbres/
4. ~/Music/Nord Piano Library/
5. ~/Documents/ElectroPiano/Sounds/ ou ~/Documents/ElectroPiano/timbres/
6. Qualquer pasta customizada adicionada em:
   ~/.config/ElectroPiano/sample_paths.txt

-> Se você colocar seus arquivos .npno em ./Sounds ou ./timbres, eles serão
   carregados e detectados automaticamente, sem precisar abrir janela de diálogo!
-> Use os botões [<] e [>] em cada camada para alternar instantaneamente entre todos
   os timbres encontrados nessas pastas.

================================================================================
SELEÇÃO DE ARQUIVOS (.NPNO) PELA INTERFACE (ABRIR .NPNO):
================================================================================
Ao clicar em "ABRIR .NPNO" em qualquer camada:
1. Abre um Navegador de Arquivos Integrado (In-App) diretamente na tela,
   permitindo navegar por pastas, atalhos rápidos e clicar diretamente no timbre desejado.
2. Botão "Diálogo do Sistema":
   Dispara o diálogo nativo do seu ambiente gráfico:
   - kdialog (KDE Plasma - padrão no CachyOS, Kubuntu, Arch KDE)
   - zenity (GNOME / GTK - padrão no Ubuntu, Debian, Pop!_OS)
   - yad / qarma (ambientes leves e tiling window managers)

================================================================================
COMPATIBILIDADE COM DAWS LINUX (BITWIG STUDIO, REAPER, ETC.):
================================================================================
- O plugin VST3 implementa IPlugView nativo com X11EmbedWindowID em 60 FPS.
- Testado e otimizado para Bitwig Studio, Reaper para Linux, Ardour, Renoise e Carla.
- Janela dimensionada em 1140 x 690 pixels.

================================================================================
RECURSOS DA VERSÃO:
================================================================================
- 4 Camadas de Som simultâneas (Layers A, B, C, D) com knobs independentes
- 8 Slots de Memória de Programas (Salva e recupera as 4 camadas com 1 clique)
- Mapeamento MIDI Universal dos Knobs (Clique com o botão direito em qualquer knob)
- 5 Temas de Painel: Nord Red, Matte Black, Slate Navy, Vintage Green, Burgundy
- Áudio ALSA / PipeWire / PulseAudio de baixíssima latência (64 a 1024 amostras)
- Auto-detecção de teclados controladores USB e DIN MIDI
================================================================================
EOF

rm -rf "${BUILD_TMP}"

echo ""
echo "=========================================================="
echo "  Build para Ubuntu e Arch Linux concluída com sucesso!   "
echo "  Pasta de destino: ${DIST_LINUX}                         "
echo "=========================================================="
ls -lh "${DIST_LINUX}"
