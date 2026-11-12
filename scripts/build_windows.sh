#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

CXX_WIN="${CXX_WIN:-x86_64-w64-mingw32-g++}"
if ! command -v "$CXX_WIN" >/dev/null 2>&1; then
    if [ -x "/opt/homebrew/bin/x86_64-w64-mingw32-g++" ]; then
        CXX_WIN="/opt/homebrew/bin/x86_64-w64-mingw32-g++"
    else
        echo "Erro: $CXX_WIN não encontrado. Instale com: brew install mingw-w64"
        exit 1
    fi
fi

OUT_DIR="$ROOT_DIR/Windows"
VST3_DIR="$OUT_DIR/Electro Piano.vst3/Contents/x86_64-win"
mkdir -p "$VST3_DIR" "$OUT_DIR/Sounds" "$OUT_DIR/Electro Piano.vst3/Contents/Resources/Sounds"

COMMON_SRCS=(
    "Sources/NPNOKit/Document.cpp"
    "Sources/NPNOKit/Instrument.cpp"
    "Sources/NPNOKit/Engine.cpp"
    "Sources/Windows/WinNordPanel.cpp"
)

CXXFLAGS=(
    -std=c++20
    -O3
    -s
    -municode
    -static
    -static-libgcc
    -static-libstdc++
    -Wl,-Bstatic -lstdc++ -lpthread -Wl,-Bdynamic
    -ISources/NPNOKit/include
    -ISources/Windows
)

WINLIBS=(
    -lwinmm
    -lcomdlg32
    -lgdi32
    -luser32
    -lshell32
    -lole32
    -loleaut32
    -luuid
    -lksuser
)

WINDRES="${WINDRES:-x86_64-w64-mingw32-windres}"
if ! command -v "$WINDRES" >/dev/null 2>&1; then
    if [ -x "/opt/homebrew/bin/x86_64-w64-mingw32-windres" ]; then
        WINDRES="/opt/homebrew/bin/x86_64-w64-mingw32-windres"
    fi
fi

BUILD_TMP="$ROOT_DIR/build_win"
mkdir -p "$BUILD_TMP"
echo "==> Compilando recursos e ícone do Windows (resources.rc)..."
"$WINDRES" -I"$ROOT_DIR" "$ROOT_DIR/Sources/Windows/resources.rc" -O coff -o "$BUILD_TMP/resources.o"

echo "==> Compilando Aplicativo Standalone Windows (Electro Piano.exe)..."
"$CXX_WIN" -mwindows \
    "${COMMON_SRCS[@]}" \
    "Sources/Windows/WinStandaloneMain.cpp" \
    "$BUILD_TMP/resources.o" \
    "${CXXFLAGS[@]}" \
    "${WINLIBS[@]}" \
    -o "$OUT_DIR/Electro Piano.exe"

cp -f "$OUT_DIR/Electro Piano.exe" "$OUT_DIR/Nord Electro Piano.exe"

echo "==> Compilando Plugin VST3 Windows (Electro Piano.vst3)..."
"$CXX_WIN" -shared \
    "${COMMON_SRCS[@]}" \
    "Sources/Windows/WinVST3Plugin.cpp" \
    "${CXXFLAGS[@]}" \
    "${WINLIBS[@]}" \
    -o "$VST3_DIR/Electro Piano.vst3"

echo "==> Compilando Instalador GUI Windows (Instalador Nord Electro Piano (Windows).exe)..."
"$CXX_WIN" -mwindows -std=c++20 -O3 -s -municode \
    -DCLEAN_INSTALLER=1 \
    "Sources/Windows/WinInstallerMain.cpp" \
    "$BUILD_TMP/resources.o" \
    -static -static-libgcc -static-libstdc++ \
    -Wl,-Bstatic -lstdc++ -lpthread -Wl,-Bdynamic \
    -luuid -lole32 -lshell32 -lcomctl32 -luser32 -lgdi32 \
    -o "$OUT_DIR/Instalador Nord Electro Piano (Windows).exe"

cp -f "$OUT_DIR/Instalador Nord Electro Piano (Windows).exe" "$OUT_DIR/Instalador Nord Electro Piano (Limpo).exe"

cat > "$OUT_DIR/LEIA-ME.txt" << 'EOF'
========================================================================
 NORD ELECTRO PIANO (WINDOWS x64) — VERSÃO LIMPA (SEM TIMBRES EMBUTIDOS)
========================================================================

Esta é a versão ultraleve (~25 MB) do Nord Electro Piano.

INSTRUÇÕES DE INSTALAÇÃO:
1. Dê um duplo-clique em "Instalador Nord Electro Piano (Windows).exe" para
   instalar o aplicativo Standalone e o Plugin VST3 no seu Windows com 1 clique.
2. Como alternativa, você também pode executar "Instalar_Windows.bat".
3. Baixe os timbres oficiais da Nord Piano Library (.npno).
4. Coloque seus arquivos .npno dentro da pasta "Sounds" ou carregue-os
   diretamente em qualquer camada (A, B, C, D) através do botão
   "LOAD .NPNO" ou do menu Arquivo (Ctrl+O).

COMPATIBILIDADE:
- Windows 10 e Windows 11 (64-bit)
- Standalone (.exe) com suporte a drivers WASAPI (baixa latência), ASIO 2.0 e WaveOut
- Suporte a Painel ASIO dedicado e persistência de saídas estéreo
- 8 slots de memória para salvar e restaurar timbres instantaneamente
- Plugin VST3 compatível com Reaper, Cubase, FL Studio, Ableton Live, Studio One, etc.
========================================================================
EOF

cat > "$OUT_DIR/Sounds/COLOQUE_SEUS_TIMBRES_AQUI.txt" << 'EOF'
Coloque aqui seus arquivos de timbre da Nord Piano Library (.npno).
Ao abrir o Electro Piano, ele detectará e listará automaticamente todos os sons colocados aqui.
EOF

echo "==> Build de Windows concluído com sucesso em:"
echo "    Standalone EXE:             $OUT_DIR/Electro Piano.exe"
echo "    Plugin VST3:                $OUT_DIR/Electro Piano.vst3"
echo "    Instalador Oficial:         $OUT_DIR/Instalador Nord Electro Piano (Windows).exe"
