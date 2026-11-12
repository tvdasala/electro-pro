#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "==> Compilando Electro Piano AudioUnit (.component) e VST3 (.vst3)..."

AU_BUNDLE="$ROOT_DIR/Mac/Electro Piano.component"
VST3_BUNDLE="$ROOT_DIR/Mac/Electro Piano.vst3"

rm -rf "$AU_BUNDLE" "$VST3_BUNDLE"
mkdir -p "$AU_BUNDLE/Contents/MacOS" "$AU_BUNDLE/Contents/Resources/Sounds"
mkdir -p "$VST3_BUNDLE/Contents/MacOS" "$VST3_BUNDLE/Contents/Resources/Sounds"

if [ -f "$ROOT_DIR/Resources/AppIcon.icns" ]; then
    echo "==> Copiando ícone oficial AppIcon.icns para os bundles..."
    cp -f "$ROOT_DIR/Resources/AppIcon.icns" "$AU_BUNDLE/Contents/Resources/AppIcon.icns"
    cp -f "$ROOT_DIR/Resources/AppIcon.icns" "$VST3_BUNDLE/Contents/Resources/AppIcon.icns"
fi

echo -n "BNDL????" > "$AU_BUNDLE/Contents/PkgInfo"
echo -n "BNDL????" > "$VST3_BUNDLE/Contents/PkgInfo"

cat > "$AU_BUNDLE/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>pt_BR</string>
    <key>CFBundleExecutable</key>
    <string>Electro Piano</string>
    <key>CFBundleIdentifier</key>
    <string>com.electropro.audiounit.electropiano</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Electro Piano</string>
    <key>CFBundleDisplayName</key>
    <string>Electro Piano</string>
    <key>CFBundlePackageType</key>
    <string>BNDL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleSignature</key>
    <string>????</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>MacOSX</string>
    </array>
    <key>CFBundleVersion</key>
    <string>65536</string>
    <key>LSMinimumSystemVersion</key>
    <string>11.0</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>AudioComponents</key>
    <array>
        <dict>
            <key>name</key>
            <string>Electro Pro: Electro Piano</string>
            <key>description</key>
            <string>Electro Piano NPNO Instrument</string>
            <key>factoryFunction</key>
            <string>ElectroPianoAUFactory</string>
            <key>manufacturer</key>
            <string>ElPr</string>
            <key>subtype</key>
            <string>Epno</string>
            <key>type</key>
            <string>aumu</string>
            <key>version</key>
            <integer>65536</integer>
            <key>sandboxSafe</key>
            <false/>
        </dict>
    </array>
</dict>
</plist>
EOF

cat > "$VST3_BUNDLE/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>pt_BR</string>
    <key>CFBundleExecutable</key>
    <string>Electro Piano</string>
    <key>CFBundleIdentifier</key>
    <string>com.electropro.vst3.electropiano</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Electro Piano</string>
    <key>CFBundleDisplayName</key>
    <string>Electro Piano</string>
    <key>CFBundlePackageType</key>
    <string>BNDL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleSignature</key>
    <string>????</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>MacOSX</string>
    </array>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>11.0</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CSResourcesFileMapped</key>
    <true/>
</dict>
</plist>
EOF

COMMON_SRCS=(
    "Sources/NPNOKit/Document.cpp"
    "Sources/NPNOKit/Instrument.cpp"
    "Sources/NPNOKit/Engine.cpp"
    "Sources/ElectroPianoPlugin/PluginShared.mm"
)

CXXFLAGS=(
    -std=c++20
    -O3
    -mmacosx-version-min=11.0
    -arch arm64
    -arch x86_64
    -fobjc-arc
    -fvisibility=hidden
    -Wall
    -Wextra
    -Wno-unused-parameter
    -ISources/NPNOKit/include
    -ISources/ElectroPianoPlugin
)

FRAMEWORKS=(
    -framework Cocoa
    -framework AudioToolbox
    -framework AudioUnit
    -framework CoreAudio
    -framework CoreMIDI
    -framework CoreFoundation
    -framework UniformTypeIdentifiers
    -framework QuartzCore
)

echo "==> Compilando binário AudioUnit (.component)..."
clang++ -bundle \
    "${CXXFLAGS[@]}" \
    "${COMMON_SRCS[@]}" \
    "Sources/ElectroPianoPlugin/AudioUnitPlugin.mm" \
    "${FRAMEWORKS[@]}" \
    -o "$AU_BUNDLE/Contents/MacOS/Electro Piano"

echo "==> Compilando binário VST3 (.vst3)..."
clang++ -bundle \
    "${CXXFLAGS[@]}" \
    -DEPNO_BUILD_VST3=1 \
    "${COMMON_SRCS[@]}" \
    "Sources/ElectroPianoPlugin/VST3Plugin.mm" \
    "${FRAMEWORKS[@]}" \
    -o "$VST3_BUNDLE/Contents/MacOS/Electro Piano"

echo "==> Assinando bundles (ad-hoc codesign)..."
codesign --force --deep --sign - "$AU_BUNDLE"
codesign --force --deep --sign - "$VST3_BUNDLE"

USER_AU_DIR="$HOME/Library/Audio/Plug-Ins/Components"
USER_VST3_DIR="$HOME/Library/Audio/Plug-Ins/VST3"
mkdir -p "$USER_AU_DIR" "$USER_VST3_DIR"

rm -rf "$USER_AU_DIR/Electro Piano.component"
cp -R "$AU_BUNDLE" "$USER_AU_DIR/Electro Piano.component"

rm -rf "$USER_VST3_DIR/Electro Piano.vst3"
cp -R "$VST3_BUNDLE" "$USER_VST3_DIR/Electro Piano.vst3"

echo "==> Plugins instalados com sucesso em:"
echo "    AU:   $USER_AU_DIR/Electro Piano.component"
echo "    VST3: $USER_VST3_DIR/Electro Piano.vst3"

killall -9 AudioComponentRegistrar 2>/dev/null || true
echo "==> Cache de Audio Components do macOS atualizado com sucesso."
