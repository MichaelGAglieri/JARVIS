import SwiftUI
@MainActor final class Assistant: ObservableObject {
    enum State: Equatable {
        case booting(String), idle, listening, transcribing, thinking, acting, speaking, error(String)
    }
    @Published var state: State = .idle
    @Published var deepIdle = false
    @Published var privacyMode = false
    let levels = AudioLevels()
}
final class AudioLevels { var mic: Float = 0; var voice: Float = 0 }
