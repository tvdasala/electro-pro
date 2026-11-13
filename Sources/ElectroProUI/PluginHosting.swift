import AppKit
import NPNOBridge
import SwiftUI

private struct PluginRootView: View {
    @StateObject var vm: PianoViewModel

    var body: some View {
        ContentView(vm: vm)
    }
}

@MainActor
private final class ElectroProPluginHostingView: NSHostingView<PluginRootView> {
    let viewModel: PianoViewModel

    init(viewModel: PianoViewModel, frame: NSRect) {
        self.viewModel = viewModel
        super.init(rootView: PluginRootView(vm: viewModel))
        self.frame = frame
        self.autoresizingMask = [.width, .height]
    }

    @available(*, unavailable)
    @MainActor required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @available(*, unavailable)
    @MainActor required init(rootView: PluginRootView) {
        fatalError("init(rootView:) has not been implemented")
    }
}

@_cdecl("ElectroProCreatePluginView")
public func ElectroProCreatePluginView(
    _ callbacksPtr: UnsafePointer<NPNOPluginCallbacks>,
    _ width: Double,
    _ height: Double
) -> UnsafeMutableRawPointer {
    let rawBits = UInt(bitPattern: callbacksPtr)
    let resultBits: UInt = MainActor.assumeIsolated {
        let ptr = UnsafePointer<NPNOPluginCallbacks>(bitPattern: rawBits)!
        var callbacks = ptr.pointee
        let hostPtr = npno_host_create_plugin(&callbacks)!
        let vm = PianoViewModel(pluginHost: hostPtr)
        let w = width > 100 ? width : 1180
        let h = height > 100 ? height : 760
        let hostingView = ElectroProPluginHostingView(
            viewModel: vm,
            frame: NSRect(x: 0, y: 0, width: w, height: h)
        )
        return UInt(bitPattern: Unmanaged.passRetained(hostingView).toOpaque())
    }
    return UnsafeMutableRawPointer(bitPattern: resultBits)!
}

@_cdecl("ElectroProSyncPluginView")
public func ElectroProSyncPluginView(_ viewPtr: UnsafeMutableRawPointer) {
    let rawBits = UInt(bitPattern: viewPtr)
    MainActor.assumeIsolated {
        let ptr = UnsafeMutableRawPointer(bitPattern: rawBits)!
        let obj = Unmanaged<NSView>.fromOpaque(ptr).takeUnretainedValue()
        if let hosting = obj as? ElectroProPluginHostingView {
            hosting.viewModel.syncFromPluginHost()
        }
    }
}
