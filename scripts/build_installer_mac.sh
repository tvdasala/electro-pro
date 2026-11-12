#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "==> 1. Compilando Electro Piano Standalone para Apple Silicon (arm64, target macOS 11.0+)..."
swift build -c release --product ElectroPiano --triple arm64-apple-macosx11.0
BIN_ARM64="/tmp/ElectroPiano_arm64"
cp -f "$ROOT_DIR/.build/out/Products/Release/ElectroPiano" "$BIN_ARM64"

echo "==> 2. Compilando Electro Piano Standalone para Macs Intel (x86_64, target macOS 11.0+)..."
cat << 'EOF' > /tmp/swift_compat.s
.globl __swift_FORCE_LOAD_$_swiftCompatibility56
__swift_FORCE_LOAD_$_swiftCompatibility56:
    .long 0

.globl __swift_FORCE_LOAD_$_swiftCompatibilityConcurrency
__swift_FORCE_LOAD_$_swiftCompatibilityConcurrency:
    .long 0

.globl __swift_FORCE_LOAD_$_swiftCompatibilityPacks
__swift_FORCE_LOAD_$_swiftCompatibilityPacks:
    .long 0
EOF
clang -c -arch x86_64 -target x86_64-apple-macos11.0 -o /tmp/swift_compat_x86_64.o /tmp/swift_compat.s
swift build -c release --product ElectroPiano --triple x86_64-apple-macosx11.0 -Xlinker /tmp/swift_compat_x86_64.o
BIN_X86_64="/tmp/ElectroPiano_x86_64"
cp -f "$ROOT_DIR/.build/out/Products/Release/ElectroPiano" "$BIN_X86_64"

echo "==> 3. Compilando Plugins AudioUnit e VST3 (target macOS 11.0+)..."
bash "$ROOT_DIR/scripts/build_plugins.sh"

AU_SRC="$ROOT_DIR/Mac/Electro Piano.component"
VST3_SRC="$ROOT_DIR/Mac/Electro Piano.vst3"

# ==============================================================================
# 4. PASTA E INSTALADOR LIMPO MAC (ARM - APPLE SILICON)
# ==============================================================================
echo "==> 4. Montando pacote Mac (ARM)..."
ARM_DIR="$ROOT_DIR/Mac (ARM)"
mkdir -p "$ARM_DIR/Electro Piano.app/Contents/MacOS" "$ARM_DIR/Electro Piano.app/Contents/Resources/Sounds"
mkdir -p "$ARM_DIR/Electro Piano.component/Contents/MacOS" "$ARM_DIR/Electro Piano.component/Contents/Resources/Sounds"
mkdir -p "$ARM_DIR/Electro Piano.vst3/Contents/MacOS" "$ARM_DIR/Electro Piano.vst3/Contents/Resources/Sounds"

cp -f "$BIN_ARM64" "$ARM_DIR/Electro Piano.app/Contents/MacOS/ElectroPiano"
if [ -f "$ROOT_DIR/Resources/AppIcon.icns" ]; then
    cp -f "$ROOT_DIR/Resources/AppIcon.icns" "$ARM_DIR/Electro Piano.app/Contents/Resources/AppIcon.icns"
fi

cat > "$ARM_DIR/Electro Piano.app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>pt-BR</string>
    <key>CFBundleExecutable</key>
    <string>ElectroPiano</string>
    <key>CFBundleIdentifier</key>
    <string>com.electropiano.npno</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Electro Piano</string>
    <key>CFBundleDisplayName</key>
    <string>Electro Piano</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>11.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

cp -R "$AU_SRC" "$ARM_DIR/"
rm -f "$ARM_DIR/Electro Piano.component/Contents/Resources/Sounds/"*.npno
lipo "$AU_SRC/Contents/MacOS/Electro Piano" -thin arm64 -output "$ARM_DIR/Electro Piano.component/Contents/MacOS/Electro Piano"

cp -R "$VST3_SRC" "$ARM_DIR/"
rm -f "$ARM_DIR/Electro Piano.vst3/Contents/Resources/Sounds/"*.npno
lipo "$VST3_SRC/Contents/MacOS/Electro Piano" -thin arm64 -output "$ARM_DIR/Electro Piano.vst3/Contents/MacOS/Electro Piano"

codesign --force --deep --sign - "$ARM_DIR/Electro Piano.app"
codesign --force --deep --sign - "$ARM_DIR/Electro Piano.component"
codesign --force --deep --sign - "$ARM_DIR/Electro Piano.vst3"

cat > "$ARM_DIR/Instalar_Mac_ARM.command" <<'EOF'
#!/usr/bin/env bash
DIR="$(cd "$(dirname "$0")" && pwd)"
echo "=========================================================="
echo "    INSTALADOR NORD ELECTRO PIANO (macOS ARM / APPLE SILICON)"
echo "=========================================================="
echo ""
echo "Instalando versão Apple Silicon (macOS 11.0+) no seu Mac..."

sudo mkdir -p "/Applications" \
              "/Library/Audio/Plug-Ins/Components" \
              "/Library/Audio/Plug-Ins/VST3" \
              "/Library/Application Support/Nord Electro Piano/Sounds"

echo "-> Copiando Aplicativo para /Applications..."
sudo rm -rf "/Applications/Electro Piano.app"
sudo cp -R "$DIR/Electro Piano.app" "/Applications/"

echo "-> Copiando AudioUnit para /Library/Audio/Plug-Ins/Components..."
sudo rm -rf "/Library/Audio/Plug-Ins/Components/Electro Piano.component"
sudo cp -R "$DIR/Electro Piano.component" "/Library/Audio/Plug-Ins/Components/"

echo "-> Copiando VST3 para /Library/Audio/Plug-Ins/VST3..."
sudo rm -rf "/Library/Audio/Plug-Ins/VST3/Electro Piano.vst3"
sudo cp -R "$DIR/Electro Piano.vst3" "/Library/Audio/Plug-Ins/VST3/"

echo "-> Atualizando cache de plugins do macOS..."
killall -9 AudioComponentRegistrar 2>/dev/null || true

echo ""
echo "=========================================================="
echo " INSTALAÇÃO CONCLUÍDA COM SUCESSO!"
echo " Você pode colocar seus arquivos de timbres .npno em:"
echo " /Library/Application Support/Nord Electro Piano/Sounds"
echo " ou carregar manualmente pelo botão 'LOAD .NPNO' no app."
echo "=========================================================="
read -p "Pressione Enter para fechar esta janela..."
EOF
chmod +x "$ARM_DIR/Instalar_Mac_ARM.command"

cat > "$ARM_DIR/LEIA-ME.txt" << 'EOF'
========================================================================
 NORD ELECTRO PIANO (macOS) — VERSÃO APPLE SILICON (ARM64: M1/M2/M3/M4)
========================================================================

Esta é a versão nativa compilada especialmente para processadores Apple
Silicon (M1, M2, M3, M4 e suas variantes Pro/Max/Ultra).

COMPATIBILIDADE:
- macOS 11.0 (Big Sur), macOS 12.0 (Monterey), macOS 13.0 (Ventura),
  macOS 14.0 (Sonoma), macOS 15.0 (Sequoia) ou superior.

CONTEÚDO DESTA PASTA:
1. "Instalador Nord Electro Piano (ARM).pkg": Instalador oficial guiado da Apple.
2. "Instalar_Mac_ARM.command": Script de instalação instantânea por terminal.
3. "Electro Piano.app": Aplicativo Standalone independente.
4. "Electro Piano.component": Plugin AudioUnit para MainStage e Logic Pro.
5. "Electro Piano.vst3": Plugin VST3 para DAWs (Reaper, Ableton, Cubase, Studio One, etc.).

ONDE COLOCAR SEUS TIMBRES (.npno):
Coloque seus timbres baixados da Nord Piano Library em:
/Library/Application Support/Nord Electro Piano/Sounds
Ao abrir o Electro Piano, ele detectará todos os sons automaticamente.
========================================================================
EOF

PAYLOAD_ARM="$(mktemp -d /tmp/epno_payload_arm.XXXXXX)"
mkdir -p "$PAYLOAD_ARM/Applications" \
         "$PAYLOAD_ARM/Library/Audio/Plug-Ins/Components" \
         "$PAYLOAD_ARM/Library/Audio/Plug-Ins/VST3" \
         "$PAYLOAD_ARM/Library/Application Support/Nord Electro Piano/Sounds"

cp -R "$ARM_DIR/Electro Piano.app" "$PAYLOAD_ARM/Applications/"
cp -R "$ARM_DIR/Electro Piano.component" "$PAYLOAD_ARM/Library/Audio/Plug-Ins/Components/"
cp -R "$ARM_DIR/Electro Piano.vst3" "$PAYLOAD_ARM/Library/Audio/Plug-Ins/VST3/"
cp -f "$ARM_DIR/LEIA-ME.txt" "$PAYLOAD_ARM/Library/Application Support/Nord Electro Piano/Sounds/"

pkgbuild \
    --root "$PAYLOAD_ARM" \
    --scripts "$ROOT_DIR/scripts/pkg_scripts" \
    --identifier "com.electropro.pkg.electropiano.arm" \
    --version "1.0.0" \
    --install-location "/" \
    "$ARM_DIR/Instalador Nord Electro Piano (ARM).pkg"

rm -rf "$PAYLOAD_ARM"

# ==============================================================================
# 5. PASTA E INSTALADOR LIMPO MAC (INTEL x86_64)
# ==============================================================================
echo "==> 5. Montando pacote Mac (Intel)..."
INTEL_DIR="$ROOT_DIR/Mac (Intel)"
mkdir -p "$INTEL_DIR/Electro Piano.app/Contents/MacOS" "$INTEL_DIR/Electro Piano.app/Contents/Resources/Sounds"
mkdir -p "$INTEL_DIR/Electro Piano.component/Contents/MacOS" "$INTEL_DIR/Electro Piano.component/Contents/Resources/Sounds"
mkdir -p "$INTEL_DIR/Electro Piano.vst3/Contents/MacOS" "$INTEL_DIR/Electro Piano.vst3/Contents/Resources/Sounds"

cp -f "$BIN_X86_64" "$INTEL_DIR/Electro Piano.app/Contents/MacOS/ElectroPiano"
if [ -f "$ROOT_DIR/Resources/AppIcon.icns" ]; then
    cp -f "$ROOT_DIR/Resources/AppIcon.icns" "$INTEL_DIR/Electro Piano.app/Contents/Resources/AppIcon.icns"
fi

cat > "$INTEL_DIR/Electro Piano.app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>pt-BR</string>
    <key>CFBundleExecutable</key>
    <string>ElectroPiano</string>
    <key>CFBundleIdentifier</key>
    <string>com.electropiano.npno</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Electro Piano</string>
    <key>CFBundleDisplayName</key>
    <string>Electro Piano</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>11.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

cp -R "$AU_SRC" "$INTEL_DIR/"
rm -f "$INTEL_DIR/Electro Piano.component/Contents/Resources/Sounds/"*.npno
lipo "$AU_SRC/Contents/MacOS/Electro Piano" -thin x86_64 -output "$INTEL_DIR/Electro Piano.component/Contents/MacOS/Electro Piano"

cp -R "$VST3_SRC" "$INTEL_DIR/"
rm -f "$INTEL_DIR/Electro Piano.vst3/Contents/Resources/Sounds/"*.npno
lipo "$VST3_SRC/Contents/MacOS/Electro Piano" -thin x86_64 -output "$INTEL_DIR/Electro Piano.vst3/Contents/MacOS/Electro Piano"

codesign --force --deep --sign - "$INTEL_DIR/Electro Piano.app"
codesign --force --deep --sign - "$INTEL_DIR/Electro Piano.component"
codesign --force --deep --sign - "$INTEL_DIR/Electro Piano.vst3"

cat > "$INTEL_DIR/Instalar_Mac_Intel.command" <<'EOF'
#!/usr/bin/env bash
DIR="$(cd "$(dirname "$0")" && pwd)"
echo "=========================================================="
echo "    INSTALADOR NORD ELECTRO PIANO (macOS INTEL x86_64)"
echo "=========================================================="
echo ""
echo "Instalando versão Intel (macOS 11.0+) no seu Mac..."

sudo mkdir -p "/Applications" \
              "/Library/Audio/Plug-Ins/Components" \
              "/Library/Audio/Plug-Ins/VST3" \
              "/Library/Application Support/Nord Electro Piano/Sounds"

echo "-> Copiando Aplicativo para /Applications..."
sudo rm -rf "/Applications/Electro Piano.app"
sudo cp -R "$DIR/Electro Piano.app" "/Applications/"

echo "-> Copiando AudioUnit para /Library/Audio/Plug-Ins/Components..."
sudo rm -rf "/Library/Audio/Plug-Ins/Components/Electro Piano.component"
sudo cp -R "$DIR/Electro Piano.component" "/Library/Audio/Plug-Ins/Components/"

echo "-> Copiando VST3 para /Library/Audio/Plug-Ins/VST3..."
sudo rm -rf "/Library/Audio/Plug-Ins/VST3/Electro Piano.vst3"
sudo cp -R "$DIR/Electro Piano.vst3" "/Library/Audio/Plug-Ins/VST3/"

echo "-> Atualizando cache de plugins do macOS..."
killall -9 AudioComponentRegistrar 2>/dev/null || true

echo ""
echo "=========================================================="
echo " INSTALAÇÃO CONCLUÍDA COM SUCESSO!"
echo " Você pode colocar seus arquivos de timbres .npno em:"
echo " /Library/Application Support/Nord Electro Piano/Sounds"
echo " ou carregar manualmente pelo botão 'LOAD .NPNO' no app."
echo "=========================================================="
read -p "Pressione Enter para fechar esta janela..."
EOF
chmod +x "$INTEL_DIR/Instalar_Mac_Intel.command"

cat > "$INTEL_DIR/LEIA-ME.txt" << 'EOF'
========================================================================
 NORD ELECTRO PIANO (macOS) — VERSÃO DEDICADA PARA MACS INTEL (x86_64)
========================================================================

Esta é a versão nativa compilada especialmente para computadores Mac
equipados com processadores Intel (Core i5, i7, i9, Xeon).

COMPATIBILIDADE:
- macOS 11.0 (Big Sur), macOS 12.0 (Monterey), macOS 13.0 (Ventura),
  macOS 14.0 (Sonoma), macOS 15.0 (Sequoia) ou superior.

CONTEÚDO DESTA PASTA:
1. "Instalador Nord Electro Piano (Intel).pkg": Instalador oficial guiado da Apple.
2. "Instalar_Mac_Intel.command": Script de instalação instantânea por terminal.
3. "Electro Piano.app": Aplicativo Standalone independente.
4. "Electro Piano.component": Plugin AudioUnit para MainStage e Logic Pro.
5. "Electro Piano.vst3": Plugin VST3 para DAWs (Reaper, Ableton, Cubase, Studio One, etc.).

ONDE COLOCAR SEUS TIMBRES (.npno):
Coloque seus timbres baixados da Nord Piano Library em:
/Library/Application Support/Nord Electro Piano/Sounds
Ao abrir o Electro Piano, ele detectará todos os sons automaticamente.
========================================================================
EOF

PAYLOAD_INTEL="$(mktemp -d /tmp/epno_payload_intel_v2.XXXXXX)"
mkdir -p "$PAYLOAD_INTEL/Applications" \
         "$PAYLOAD_INTEL/Library/Audio/Plug-Ins/Components" \
         "$PAYLOAD_INTEL/Library/Audio/Plug-Ins/VST3" \
         "$PAYLOAD_INTEL/Library/Application Support/Nord Electro Piano/Sounds"

cp -R "$INTEL_DIR/Electro Piano.app" "$PAYLOAD_INTEL/Applications/"
cp -R "$INTEL_DIR/Electro Piano.component" "$PAYLOAD_INTEL/Library/Audio/Plug-Ins/Components/"
cp -R "$INTEL_DIR/Electro Piano.vst3" "$PAYLOAD_INTEL/Library/Audio/Plug-Ins/VST3/"
cp -f "$INTEL_DIR/LEIA-ME.txt" "$PAYLOAD_INTEL/Library/Application Support/Nord Electro Piano/Sounds/"

pkgbuild \
    --root "$PAYLOAD_INTEL" \
    --scripts "$ROOT_DIR/scripts/pkg_scripts" \
    --identifier "com.electropro.pkg.electropiano.intel" \
    --version "1.0.0" \
    --install-location "/" \
    "$INTEL_DIR/Instalador Nord Electro Piano (Intel).pkg"

rm -rf "$PAYLOAD_INTEL"

# Limpa diretório Mac intermediário
rm -rf "$ROOT_DIR/Mac"

echo "==> Build concluído com sucesso!"
ls -lh "$ARM_DIR"/*.pkg
ls -lh "$INTEL_DIR"/*.pkg
