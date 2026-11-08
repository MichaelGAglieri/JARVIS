import Foundation

/// Link with ROS 2: starts (on the first request) the Python bridge
/// `Resources/ros_bridge.py` inside the lab's pixi environment and talks to it over HTTP.
final class RosBridge {
    /// The project folder, from the settings (`labProject`); read once.
    static let project = URL(fileURLWithPath: (JarvisConfig.load().labProject as NSString).expandingTildeInPath)
    static let pixi = ["/opt/homebrew/bin/pixi", "/usr/local/bin/pixi", NSHomeDirectory() + "/.pixi/bin/pixi"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    private var process: Process?
    private var port: Int?
    private let token = UUID().uuidString
    private var starting: Task<Bool, Never>?

    var isRunning: Bool { port != nil && process?.isRunning == true }

    /// Starts the bridge if it is not already running (about 5-10 seconds the first time).
    func ensureRunning() async -> Bool {
        if isRunning { return true }
        if let starting { return await starting.value }
        let task = Task { await start() }
        starting = task
        let ok = await task.value
        starting = nil
        return ok
    }

    private func start() async -> Bool {
        guard let pixi = Self.pixi,
              let script = Bundle.main.url(forResource: "ros_bridge", withExtension: "py") else { return false }
        let manifest = Self.project.appendingPathComponent("pixi.toml").path
        let wrapper = Self.project.appendingPathComponent("architetture/laboratorio/nodo.sh").path
        let workspace = Self.project.appendingPathComponent("architetture/laboratorio/ros2_ws/install/local_setup.bash").path
        guard FileManager.default.fileExists(atPath: manifest) else { return false }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pixi)
        // With the workspace built, go through the lab's script (domain 42,
        // doc_lab packages); otherwise the ROS environment is enough.
        var command = ["run", "--manifest-path", manifest, "--"]
        command += FileManager.default.fileExists(atPath: workspace) ? [wrapper, "python", script.path] : ["python", script.path]
        process.arguments = command
        process.currentDirectoryURL = Self.project
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["ROS_DOMAIN_ID"] = env["ROS_DOMAIN_ID"] ?? "42"
        env["JARVIS_BRIDGE_TOKEN"] = token
        env["JARVIS_PID"] = String(ProcessInfo.processInfo.processIdentifier)
        process.environment = env
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        self.process = process

        let port: Int? = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                var line = Data()
                while true {
                    let byte = stdout.fileHandleForReading.readData(ofLength: 1)
                    if byte.isEmpty { continuation.resume(returning: nil); return }
                    if byte == Data([0x0A]) {
                        let text = String(decoding: line, as: UTF8.self)
                        if text.hasPrefix("PORT ") { continuation.resume(returning: Int(text.dropFirst(5))); return }
                        line = Data()
                    } else {
                        line.append(byte)
                    }
                }
            }
        }
        self.port = port
        return port != nil
    }

    func stop() {
        process?.terminate()
        process = nil
        port = nil
    }

    // MARK: Calls

    private func call(_ method: String, _ path: String, _ body: [String: Any]? = nil, timeout: Double = 15) async -> String {
        guard await ensureRunning(), let port, let url = URL(string: "http://127.0.0.1:\(port)\(path)") else {
            return "Il ponte ROS 2 non è partito: controlla che pixi e il progetto del laboratorio (labProject nelle impostazioni) siano presenti."
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body { request.httpBody = try? JSONSerialization.data(withJSONObject: body) }
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return "Il ponte ROS 2 non risponde." }
        return String(decoding: data, as: UTF8.self)
    }

    func graph() async -> String { await call("GET", "/graph") }

    func echo(topic: String, timeout: Double) async -> String {
        await call("POST", "/echo", ["topic": topic, "timeout": timeout], timeout: timeout + 5)
    }

    func publish(topic: String, data: Any, type: String?) async -> String {
        var body: [String: Any] = ["topic": topic, "data": data]
        if let type { body["type"] = type }
        return await call("POST", "/publish", body)
    }

    func lab(_ text: String, wait: Double = 30) async -> String {
        await call("POST", "/lab", ["text": text, "wait": wait], timeout: wait + 5)
    }

    func labStatus() async -> String { await call("GET", "/lab") }

    /// Opens the full lab (Webots, nodes, outcomes, console) like `pixi run finestre`.
    func startLab() async -> String {
        guard let pixi = Self.pixi else { return "pixi non trovato" }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pixi)
        process.arguments = ["run", "--manifest-path", Self.project.appendingPathComponent("pixi.toml").path, "finestre"]
        process.currentDirectoryURL = Self.project
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        process.environment = env
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            return "Avvio del laboratorio in corso: compilazione, poi Webots e le finestre dei nodi. Premere Play in Webots per iniziare."
        } catch {
            return "Avvio non riuscito: \(error.localizedDescription)"
        }
    }
}
