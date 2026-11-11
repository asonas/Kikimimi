import AppKit
import SwiftUI

@MainActor
final class RecorderWindows {
    private weak var main: NSWindow?
    private weak var mini: NSWindow?
    private var miniRequested = false
    private var minimizeWhenAttached = false
    var openMini: (() -> Void)?
    var closeMini: (() -> Void)?

    func captureMain(_ window: NSWindow) {
        main = window
        if minimizeWhenAttached { minimizeWhenAttached = false; window.miniaturize(nil) }
    }
    func captureMini(_ window: NSWindow) { mini = window; miniRequested = false }
    func miniClosed(_ window: NSWindow) { if mini === window { miniRequested = false } }
    func showMini() {
        guard !AppDelegate.isHeadless else { return }
        miniRequested = true
        openMini?()
        if let main { main.miniaturize(nil) }
        else { minimizeWhenAttached = true }
    }
    /// Called after openWindow(main), which also covers a main window the user closed.
    func frontMain() {
        minimizeWhenAttached = false
        if let main, main.isVisible || main.isMiniaturized {
            main.deminiaturize(nil)
            main.makeKeyAndOrderFront(nil)
        }
    }
    func expand() {
        guard !AppDelegate.isHeadless else { return }
        closeMiniWindow()
        AppDelegate.showMainWindow?()
    }
    func recordingEnded() {
        guard !AppDelegate.isHeadless, miniRequested || mini?.isVisible == true || mini?.isMiniaturized == true else { return }
        expand()
    }
    private func closeMiniWindow() {
        miniRequested = false
        closeMini?()
    }
}

/// Capture the hosting window directly; neither localized titles nor window ordering identify it.
struct RecorderWindowCapture: NSViewRepresentable {
    let capture: @MainActor (NSWindow) -> Void
    func makeNSView(context: Context) -> WindowView { WindowView(capture: capture) }
    func updateNSView(_ view: WindowView, context: Context) { view.capture = capture }
    final class WindowView: NSView {
        var capture: @MainActor (NSWindow) -> Void
        init(capture: @escaping @MainActor (NSWindow) -> Void) {
            self.capture = capture
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { capture(window) }
        }
    }
}
