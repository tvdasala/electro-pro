import AppKit
import SwiftUI
import ElectroProUI

@main
struct ElectroPianoApp: App {
    @StateObject private var viewModel = PianoViewModel()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup(L("Electro Pro")) {
            ContentView(vm: viewModel)
        }
        .defaultSize(width: 1200, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            // File Menu
            CommandGroup(replacing: .newItem) {
                Button(L("Load Sound into Selected Layer…")) {
                    viewModel.openFilePicker(forLayer: viewModel.selectedLayer)
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button(L("Load Sound into Layer A…")) {
                    viewModel.openFilePicker(forLayer: 0)
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])

                Button(L("Load Sound into Layer B…")) {
                    viewModel.openFilePicker(forLayer: 1)
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])

                Button(L("Load Sound into Layer C…")) {
                    viewModel.openFilePicker(forLayer: 2)
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])

                Button(L("Load Sound into Layer D…")) {
                    viewModel.openFilePicker(forLayer: 3)
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])

                Divider()

                Button(String(localized: "Save to Current Program (M\(viewModel.selectedMemorySlot))", bundle: epBundle)) {
                    viewModel.storeCurrentToMemory(slot: viewModel.selectedMemorySlot)
                }
                .keyboardShortcut("s", modifiers: [.command])

                Button(L("Revert to Saved")) {
                    viewModel.revertToSavedProgram()
                }
                .disabled(!viewModel.isProgramEdited)

                Button(L("Rename Program…")) {
                    viewModel.beginRenameCurrentProgram()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Menu(L("Copy Program To…")) {
                    ForEach(1...4, id: \.self) { slot in
                        let slotName = viewModel.memorySlots[slot - 1].name
                        Button(String(localized: "Program \(slot) — \(slotName)", bundle: epBundle)) {
                            viewModel.copyCurrentProgram(toSlot: slot)
                        }
                        .disabled(slot == viewModel.selectedMemorySlot)
                    }
                }

                Divider()

                Button(L("Export Program…")) {
                    viewModel.exportCurrentProgram()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])

                Button(L("Import Program…")) {
                    viewModel.importProgram()
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])

                Divider()

                Button(L("Purge Unused Samples from RAM")) {
                    viewModel.purgeUnusedMemory()
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])

                Button(L("Reload Purged Samples")) {
                    viewModel.reloadPurgedMemory()
                }
            }

            // Edit Menu (Undo / Redo + Reset + Panic)
            CommandGroup(replacing: .undoRedo) {
                Button(L("Undo")) {
                    viewModel.performUndo()
                }
                .keyboardShortcut("z", modifiers: [.command])
                .disabled(!viewModel.canUndo)

                Button(L("Redo")) {
                    viewModel.performRedo()
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!viewModel.canRedo)
            }

            CommandGroup(after: .pasteboard) {
                Divider()
                Button(L("Reset Equalizer (Flat 0 dB)")) {
                    viewModel.resetEq()
                }
                if viewModel.activeMidiLearnKey != nil || viewModel.midiLearnLayer >= 0 {
                    Button(L("Cancel MIDI Learn")) {
                        viewModel.activeMidiLearnKey = nil
                        viewModel.toggleMidiLearn(layer: viewModel.midiLearnLayer, slot: viewModel.midiLearnSlot)
                    }
                    .keyboardShortcut(.escape, modifiers: [])
                }
                Button(L("Panic — All Notes Off")) {
                    viewModel.panic()
                }
                .keyboardShortcut(".", modifiers: [.command])
            }

            // View Menu (Tabs, Layers, On-Screen Keyboard, and Zoom on Cmd +/−)
            CommandGroup(after: .toolbar) {
                Button(viewModel.showVirtualKeyboard ? L("Hide On-Screen Keyboard (61 Keys)") : L("Show On-Screen Keyboard (61 Keys)")) {
                    viewModel.showVirtualKeyboard.toggle()
                }
                .keyboardShortcut("k", modifiers: [.command])

                Divider()

                ForEach(WorkstationTab.allCases) { tab in
                    Button(String(localized: "Tab: \(tab.title)", bundle: epBundle)) {
                        viewModel.selectedTab = tab
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(tab.rawValue + 1)")), modifiers: [.command])
                }

                Divider()

                ForEach(0..<4, id: \.self) { layer in
                    Button(String(localized: "Select Layer \(kLayerLetters[layer])", bundle: epBundle)) {
                        viewModel.selectedLayer = layer
                        if !viewModel.selectedTab.isPerLayer {
                            viewModel.selectedTab = viewModel.lastLayerTab
                        }
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(layer + 1)")), modifiers: [.option])
                }

                Divider()

                Button(L("Zoom In")) {
                    viewModel.zoomIn()
                }
                .keyboardShortcut("=", modifiers: [.command])

                Button(L("Zoom Out")) {
                    viewModel.zoomOut()
                }
                .keyboardShortcut("-", modifiers: [.command])

                Button(L("Actual Size (100%)")) {
                    viewModel.zoomToFitScreen()
                }
                .keyboardShortcut("0", modifiers: [.command])
            }

            CommandGroup(replacing: .appInfo) {
                Button(L("About Electro Pro")) {
                    viewModel.showAboutSheet = true
                }
            }

            CommandGroup(replacing: .help) {
                Button(L("Keyboard Shortcuts…")) {
                    viewModel.showKeyboardShortcutsSheet = true
                }
                .keyboardShortcut("/", modifiers: [.command])
            }

            #if DEBUG
            CommandMenu(L("Debug")) {
                Button(L("Manual CC Sender…")) {
                    viewModel.showDebugManualCCSheet = true
                }
                Button(viewModel.isRunningStressTest ? L("Stop Stress Test") : L("Stress Test (60s)…")) {
                    viewModel.toggleStressTest()
                }
            }
            #endif
        }

        // Native Settings Window (Cmd+,)
        Settings {
            ElectroProSettingsView(vm: viewModel)
        }
    }
}
