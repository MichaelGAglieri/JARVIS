import LocalAuthentication

/// The check a voice cannot imitate: Touch ID, or the Mac password if the
/// finger is not available (lid closed). macOS handles the window and JARVIS receives
/// only yes or no. If it times out, is cancelled or is unavailable, it counts as no.
enum OwnerCheck {
    static func verify(reason: String, timeout: Double = 30) async -> Bool {
        let context = LAContext()
        let timer = Task {
            try? await Task.sleep(for: .seconds(timeout))
            if !Task.isCancelled { context.invalidate() }
        }
        defer { timer.cancel() }
        return await withTaskCancellationHandler {
            (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
        } onCancel: {
            context.invalidate()
        }
    }
}
