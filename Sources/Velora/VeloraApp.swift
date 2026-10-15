import SwiftUI
import VeloraCore

extension Notification.Name { static let openVeloraMovie = Notification.Name("openVeloraMovie") }

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        if let first = filenames.first {
            NotificationCenter.default.post(name: .openVeloraMovie, object: URL(fileURLWithPath: first))
        }
        sender.reply(toOpenOrPrint: .success)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct VeloraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = PlayerModel()
    var body: some Scene {
        WindowGroup("Velora") {
            PlayerView(model: model)
                .preferredColorScheme(.dark)
                .onReceive(NotificationCenter.default.publisher(for: .openVeloraMovie)) { note in
                    if let url = note.object as? URL { model.open(url) }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.close() }
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
