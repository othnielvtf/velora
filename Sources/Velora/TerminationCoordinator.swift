import AppKit

/// Keep the main run loop alive until asynchronous media cleanup has finished.
@MainActor
final class TerminationCoordinator {
    private enum State { case running, waiting, finished }
    private var state = State.running
    private var cleanup: Task<Void, Never>?

    func requestTermination(shutdown: @escaping @MainActor () async -> Void,
                            reply: @escaping @MainActor () -> Void) -> NSApplication.TerminateReply {
        switch state {
        case .finished:
            return .terminateNow
        case .waiting:
            return .terminateLater
        case .running:
            state = .waiting
            cleanup = Task {
                await shutdown()
                state = .finished
                cleanup = nil
                reply()
            }
            return .terminateLater
        }
    }
}
