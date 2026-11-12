@echo off
setlocal enabledelayedexpansion

echo ==> Compilando Nord Electro Piano para Windows (Standalone .exe + VST3 .vst3)...

if not exist "Windows_Build" mkdir "Windows_Build"
if not exist "Windows_Build\Electro Piano.vst3\Contents\x86_64-win" mkdir "Windows_Build\Electro Piano.vst3\Contents\x86_64-win"

where cl.exe >nul 2>nul
if %ERRORLEVEL% EQU 0 (
    echo ==> Usando compilador Microsoft Visual C++ ^(cl.exe^)...
    cl /nologo /std:c++20 /O2 /EHsc /utf-8 /DUNICODE /D_UNICODE /DNOMINMAX ^
        /I"Sources\NPNOKit\include" /I"Sources\Windows" ^
        Sources\NPNOKit\Document.cpp ^
        Sources\NPNOKit\Instrument.cpp ^
        Sources\NPNOKit\Engine.cpp ^
        Sources\Windows\WinNordPanel.cpp ^
        Sources\Windows\WinStandaloneMain.cpp ^
        /Fe:"Windows_Build\Electro Piano.exe" ^
        /link /SUBSYSTEM:WINDOWS user32.lib gdi32.lib winmm.lib comdlg32.lib shell32.lib ole32.lib

    cl /nologo /std:c++20 /O2 /EHsc /utf-8 /LD /DUNICODE /D_UNICODE /DNOMINMAX ^
        /I"Sources\NPNOKit\include" /I"Sources\Windows" ^
        Sources\NPNOKit\Document.cpp ^
        Sources\NPNOKit\Instrument.cpp ^
        Sources\NPNOKit\Engine.cpp ^
        Sources\Windows\WinNordPanel.cpp ^
        Sources\Windows\WinVST3Plugin.cpp ^
        /Fe:"Windows_Build\Electro Piano.vst3\Contents\x86_64-win\Electro Piano.vst3" ^
        /link user32.lib gdi32.lib winmm.lib comdlg32.lib shell32.lib ole32.lib

    del /q *.obj *.exp *.lib 2>nul
    echo ==> Concluido com sucesso em Windows_Build\
    exit /b 0
)

where g++.exe >nul 2>nul
if %ERRORLEVEL% EQU 0 (
    echo ==> Usando compilador MinGW-w64 ^(g++.exe^)...
    g++ -std=c++20 -O3 -municode -mwindows -static -static-libgcc -static-libstdc++ ^
        -ISources/NPNOKit/include -ISources/Windows ^
        Sources/NPNOKit/Document.cpp ^
        Sources/NPNOKit/Instrument.cpp ^
        Sources/NPNOKit/Engine.cpp ^
        Sources/Windows/WinNordPanel.cpp ^
        Sources/Windows/WinStandaloneMain.cpp ^
        -o "Windows_Build/Electro Piano.exe" ^
        -lwinmm -lcomdlg32 -lgdi32 -luser32 -lshell32 -lole32

    g++ -std=c++20 -O3 -shared -municode -static -static-libgcc -static-libstdc++ ^
        -ISources/NPNOKit/include -ISources/Windows ^
        Sources/NPNOKit/Document.cpp ^
        Sources/NPNOKit/Instrument.cpp ^
        Sources/NPNOKit/Engine.cpp ^
        Sources/Windows/WinNordPanel.cpp ^
        Sources/Windows/WinVST3Plugin.cpp ^
        -o "Windows_Build/Electro Piano.vst3/Contents/x86_64-win/Electro Piano.vst3" ^
        -lwinmm -lcomdlg32 -lgdi32 -luser32 -lshell32 -lole32

    echo ==> Concluido com sucesso em Windows_Build\
    exit /b 0
)

echo ERRO: Nenhum compilador C++ ^(Visual Studio cl.exe ou MinGW-w64 g++.exe^) encontrado no PATH.
exit /b 1
