import AppKit
import SwiftUI

/// Tracks the actual host window, including fullscreen changes from the green button or system menu.
@MainActor
final class PlayerWindowState: ObservableObject {
    @Published private(set) var isFullscreen = false
    @Published private(set) var interactionCounter: UInt = 0
    @Published private(set) var topInset: CGFloat = 28
    weak var window: NSWindow?
    var onSkip: ((Double) -> Void)?
    private var notifications: [NSObjectProtocol] = []
    private var eventMonitor: Any?
    private var lastPointerSignal: TimeInterval = 0

    func attach(_ window: NSWindow?) {
        guard self.window !== window else { return }
        detach()
        self.window = window
        guard let window else { return }
        window.acceptsMouseMovedEvents = true
        isFullscreen = window.styleMask.contains(.fullScreen)
        updateScreenInsets()
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
                     NSWindow.didChangeScreenNotification, NSWindow.didResignKeyNotification, NSWindow.didBecomeKeyNotification] {
            notifications.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let window = self.window else { return }
                    if note.name != NSWindow.didResignKeyNotification && note.name != NSWindow.didBecomeKeyNotification && note.name != NSWindow.didChangeScreenNotification {
                        self.isFullscreen = window.styleMask.contains(.fullScreen)
                    }
                    self.updateScreenInsets()
                    self.interactionCounter &+= 1
                    NSCursor.setHiddenUntilMouseMoves(false)
                }
            })
        }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]) { [weak self] event in
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.isFullscreen, event.window === self.window else { return false }
                if event.type != .mouseMoved || event.timestamp - self.lastPointerSignal > 0.15 {
                    self.lastPointerSignal = event.timestamp
                    self.interactionCounter &+= 1
                }
                // Leave sheets, text fields, menus and system shortcuts to their own responders.
                guard event.type == .keyDown, self.window?.attachedSheet == nil,
                      !(self.window?.firstResponder is NSTextView),
                      event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
                if event.keyCode == 53 { self.toggleFullscreen(); return true }
                if self.window?.firstResponder is NSSlider { return false }
                if event.keyCode == 123 { self.onSkip?(-10); return true }
                if event.keyCode == 124 { self.onSkip?(10); return true }
                return false
            }
            return consumed ? nil : event
        }
    }

    func toggleFullscreen() { window?.toggleFullScreen(nil) }

    private func updateScreenInsets() {
        topInset = max(28, (window?.screen?.safeAreaInsets.top ?? 0) + 12)
    }

    func detach() {
        notifications.forEach(NotificationCenter.default.removeObserver)
        notifications.removeAll()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        window = nil
        NSCursor.setHiddenUntilMouseMoves(false)
    }
}

struct PlayerWindowReader: NSViewRepresentable {
    let state: PlayerWindowState
    func makeNSView(context: Context) -> WindowProbe {
        let view = WindowProbe(); view.state = state; return view
    }
    func updateNSView(_ nsView: WindowProbe, context: Context) { nsView.state = state }
    static func dismantleNSView(_ nsView: WindowProbe, coordinator: ()) { nsView.state?.detach() }

    final class WindowProbe: NSView {
        weak var state: PlayerWindowState?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let hostWindow = window
            DispatchQueue.main.async { [weak self] in self?.state?.attach(hostWindow) }
        }
    }
}
