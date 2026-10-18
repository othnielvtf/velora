import SwiftUI
import VeloraCore

extension Notification.Name { static let openVeloraMovie = Notification.Name("openVeloraMovie") }

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var shutdownHandler: (@MainActor () async -> Void)?
    private let termination = TerminationCoordinator()

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        if let first = filenames.first {
            NotificationCenter.default.post(name: .openVeloraMovie, object: URL(fileURLWithPath: first))
        }
        sender.reply(toOpenOrPrint: .success)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let shutdownHandler else { return .terminateNow }
        return termination.requestTermination(shutdown: shutdownHandler) {
            sender.reply(toApplicationShouldTerminate: true)
        }
    }
}

@main
@MainActor
struct VeloraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model: PlayerModel

    init() {
        let model = PlayerModel()
        _model = StateObject(wrappedValue: model)
        delegate.shutdownHandler = { await model.shutdown() }
    }

    var body: some Scene {
        WindowGroup("Velora") {
            PlayerView(model: model)
                .preferredColorScheme(.dark)
                .onReceive(NotificationCenter.default.publisher(for: .openVeloraMovie)) { note in
                    if let url = note.object as? URL { model.open(url) }
                }
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                    if let index = CommandLine.arguments.firstIndex(of: "--open"), CommandLine.arguments.count > index + 1 {
                        model.open(URL(fileURLWithPath: CommandLine.arguments[index + 1]))
                    }
                }
        }
        .defaultSize(width: 1080, height: 790)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Movie…", action: model.openPanel).keyboardShortcut("o")
                Button("Load Subtitles…", action: model.loadSubtitlePanel)
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(model.media == nil || model.isPreparing)
                Button("Close Movie", action: model.close).keyboardShortcut("w", modifiers: [.command, .shift])
            }
            CommandMenu("Playback") {
                Button("Play / Pause", action: model.togglePlayback).keyboardShortcut(.space, modifiers: [])
                Button("Skip Forward 10 Seconds") { model.skip(10) }.keyboardShortcut(.rightArrow, modifiers: [.command])
                Button("Skip Back 10 Seconds") { model.skip(-10) }.keyboardShortcut(.leftArrow, modifiers: [.command])
                Divider()
                Button("Full Screen") { NSApp.mainWindow?.toggleFullScreen(nil) }.keyboardShortcut("f", modifiers: [.control, .command])
            }
        }
    }
}
