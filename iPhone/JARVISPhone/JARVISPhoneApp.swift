import SwiftUI

/// On the iPhone the app stays in portrait and only the Mac screen view can rotate, keyboard
/// included. On the iPad everything rotates, like any app: it can also sit next to another.
final class AppOrientation: NSObject, UIApplicationDelegate {
    static let isPad = UIDevice.current.userInterfaceIdiom == .pad
    static var allowed: UIInterfaceOrientationMask = isPad ? .all : .portrait

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.allowed
    }

    /// `go` rotates at once, even with rotation lock on the phone.
    static func set(allowed: UIInterfaceOrientationMask, go: UIInterfaceOrientationMask? = nil) {
        guard !isPad else { return }
        self.allowed = allowed
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        var controller = scene.keyWindow?.rootViewController
        while let current = controller {
            current.setNeedsUpdateOfSupportedInterfaceOrientations()
            controller = current.presentedViewController
        }
        if let go { scene.requestGeometryUpdate(.iOS(interfaceOrientations: go)) }
    }
}

@main
struct JARVISPhoneApp: App {
    @UIApplicationDelegateAdaptor(AppOrientation.self) private var orientation
    @StateObject private var assistant = Assistant()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            ContentView(assistant: assistant)
                .preferredColorScheme(.dark)
                .onChange(of: phase, initial: true) { _, now in
                    // In the background iOS closes the network: it reopens when coming back to the app.
                    if now == .active { assistant.becameActive() }
                    if now == .background { assistant.wentToBackground() }
                }
        }
    }
}
