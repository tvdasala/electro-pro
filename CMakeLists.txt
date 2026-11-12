cmake_minimum_required(VERSION 3.20)
project(ElectroPiano VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(NPNO_CORE_SOURCES
    Sources/NPNOKit/Document.cpp
    Sources/NPNOKit/Instrument.cpp
    Sources/NPNOKit/Engine.cpp
)

if(WIN32)
    add_definitions(-DUNICODE -D_UNICODE -DNOMINMAX -D_CRT_SECURE_NO_WARNINGS)

    # 1. Aplicativo Standalone Windows (Electro Piano.exe)
    add_executable(ElectroPianoWin WIN32
        ${NPNO_CORE_SOURCES}
        Sources/Windows/WinNordPanel.cpp
        Sources/Windows/WinStandaloneMain.cpp
    )
    target_include_directories(ElectroPianoWin PRIVATE
        Sources/NPNOKit/include
        Sources/Windows
    )
    target_link_libraries(ElectroPianoWin PRIVATE
        winmm
        comdlg32
        gdi32
        user32
        shell32
        ole32
    )
    set_target_properties(ElectroPianoWin PROPERTIES
        OUTPUT_NAME "Electro Piano"
    )

    # 2. Plugin VST3 Windows (Electro Piano.vst3)
    add_library(ElectroPianoVST3 SHARED
        ${NPNO_CORE_SOURCES}
        Sources/Windows/WinNordPanel.cpp
        Sources/Windows/WinVST3Plugin.cpp
    )
    target_include_directories(ElectroPianoVST3 PRIVATE
        Sources/NPNOKit/include
        Sources/Windows
    )
    target_link_libraries(ElectroPianoVST3 PRIVATE
        winmm
        comdlg32
        gdi32
        user32
        shell32
        ole32
    )
    set_target_properties(ElectroPianoVST3 PROPERTIES
        PREFIX ""
        OUTPUT_NAME "Electro Piano"
        SUFFIX ".vst3"
    )
endif()
