import AppKit
import Foundation

/// Arduino with `arduino-cli` (the one bundled with Arduino IDE works fine):
/// connected boards, compiling, uploading and reading the serial port.
enum ArduinoActions {
    static let cli: String? = [
        "/opt/homebrew/bin/arduino-cli", "/usr/local/bin/arduino-cli",
        "/Applications/Arduino IDE.app/Contents/Resources/app/lib/backend/resources/arduino-cli",
        NSHomeDirectory() + "/Applications/Arduino IDE.app/Contents/Resources/app/lib/backend/resources/arduino-cli",
    ].first { FileManager.default.isExecutableFile(atPath: $0) }

    struct Board {
        let port: String
        let name: String
        let fqbn: String?
    }

    static func detectedBoards() async -> [Board] {
        guard let cli else { return [] }
        let result = await Shell.run(cli, ["board", "list", "--format", "json"], timeout: 20)
        guard let json = try? JSONSerialization.jsonObject(with: Data(result.out.utf8)) as? [String: Any],
              let ports = json["detected_ports"] as? [[String: Any]] else { return [] }
        return ports.compactMap { entry in
            guard let port = entry["port"] as? [String: Any], let address = port["address"] as? String,
                  (port["protocol"] as? String) == "serial", !address.contains("Bluetooth"), !address.contains("debug-console")
            else { return nil }
            let match = (entry["matching_boards"] as? [[String: Any]])?.first
            return Board(port: address, name: match?["name"] as? String ?? "scheda sconosciuta", fqbn: match?["fqbn"] as? String)
        }
    }

    static func listBoards() async -> String {
        guard cli != nil else { return "arduino-cli non trovato: installa Arduino IDE o brew install arduino-cli." }
        let boards = await detectedBoards()
        guard !boards.isEmpty else { return "Nessuna scheda Arduino collegata via USB." }
        return "Schede collegate:\n" + boards.map { "- \($0.name) su \($0.port)\($0.fqbn.map { " (\($0))" } ?? "")" }.joined(separator: "\n")
    }

    /// A project's sketch: a folder containing a .ino with the same name.
    static func findSketch(_ query: String) async -> URL? {
        let root = NSHomeDirectory() + "/Projects"
        let result = await Shell.run("/usr/bin/mdfind", ["-onlyin", root, "kMDItemFSName == '*.ino'"], timeout: 10)
        let sketches = result.out.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
            .filter { $0.deletingPathExtension().lastPathComponent == $0.deletingLastPathComponent().lastPathComponent }
            .filter { !$0.path.contains("/build/") && !$0.path.contains("/archivio/") && !$0.path.contains("/legacy") }
        func norm(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let q = norm(query)
        return (sketches.first { norm($0.deletingPathExtension().lastPathComponent) == q }
            ?? sketches.first { norm($0.path).contains(q) })?.deletingLastPathComponent()
    }

    /// FQBN: the given one, the connected board's, or an Arduino Mega
    private static func fqbn(_ args: [String: Any], board: Board?) -> String {
        args.string("fqbn") ?? board?.fqbn ?? "arduino:avr:mega:cpu=atmega2560"
    }

    static func compile(_ args: [String: Any]) async -> String {
        guard let cli else { return "arduino-cli non trovato." }
        guard let name = args.string("sketch"), let sketch = await findSketch(name) else {
            return "Sketch non trovato: indica il nome del progetto o del file .ino."
        }
        let board = await detectedBoards().first
        let fqbn = fqbn(args, board: board)
        let result = await Shell.run(cli, ["compile", "--fqbn", fqbn, sketch.path], timeout: 240)
        let lines = (result.out + "\n" + result.err).split(separator: "\n").map(String.init)
        if result.ok {
            let usage = lines.filter { $0.contains("bytes") || $0.contains("byte") }.prefix(2).joined(separator: " ")
            return "Compilazione riuscita di \(sketch.lastPathComponent) per \(fqbn). \(usage)"
        }
        let errors = lines.filter { $0.contains("error") || $0.contains("errore") }.prefix(5).joined(separator: "\n")
        return "Compilazione fallita di \(sketch.lastPathComponent):\n\(errors.isEmpty ? String(result.err.suffix(800)) : errors)"
    }

    /// A serial port already opened by another program (Robot Console, the IDE's serial
    /// monitor…) must not be touched: it could interrupt a moving robot.
    static func portBusy(_ port: String) async -> String? {
        let result = await Shell.run("/usr/sbin/lsof", [port], timeout: 5)
        let owners = result.out.split(separator: "\n").dropFirst().compactMap { $0.split(separator: " ").first.map(String.init) }
        return owners.isEmpty ? nil : Set(owners).joined(separator: ", ")
    }

    /// Checks before uploading; returns an error or the board to use.
    static func uploadTarget(_ args: [String: Any]) async -> (board: Board?, sketch: URL?, problem: String?) {
        guard cli != nil else { return (nil, nil, "arduino-cli non trovato.") }
        guard let name = args.string("sketch"), let sketch = await findSketch(name) else {
            return (nil, nil, "Sketch non trovato.")
        }
        let boards = await detectedBoards()
        guard let board = boards.first(where: { args.string("port") == nil || $0.port == args.string("port") }) else {
            return (nil, sketch, "Nessuna scheda collegata su cui caricare.")
        }
        if let owner = await portBusy(board.port) {
            return (board, sketch, "La porta \(board.port) è occupata da \(owner): chiudi il collegamento (per la Mega del robot, scollegala in Robot Console) prima di caricare.")
        }
        return (board, sketch, nil)
    }

    static func upload(sketch: URL, board: Board, fqbn requested: String?) async -> String {
        guard let cli else { return "arduino-cli non trovato." }
        let fqbn = requested ?? board.fqbn ?? "arduino:avr:mega:cpu=atmega2560"
        let compile = await Shell.run(cli, ["compile", "--fqbn", fqbn, sketch.path], timeout: 240)
        guard compile.ok else { return "Compilazione fallita, niente caricamento:\n\(compile.err.suffix(600))" }
        let upload = await Shell.run(cli, ["upload", "--fqbn", fqbn, "--port", board.port, "--verify", sketch.path], timeout: 240)
        return upload.ok ? "Caricato \(sketch.lastPathComponent) su \(board.name) (\(board.port)) e verificato."
                         : "Caricamento fallito: \(upload.err.suffix(600))"
    }

    /// Reads the serial port for a few seconds. Opening the port usually resets the board.
    static func readSerial(port: String, baud: Int, seconds: Double) async -> String {
        guard let cli else { return "arduino-cli non trovato." }
        let result = await Shell.run(cli, ["monitor", "-p", port, "--config", "baudrate=\(baud)", "--quiet"], timeout: seconds)
        let text = (result.out + result.err).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "Nessun dato dalla seriale \(port) in \(Int(seconds)) s a \(baud) baud."
                            : "Seriale \(port) (\(baud) baud):\n" + String(text.suffix(2500))
    }
}

/// Bambu Studio: opening projects and 3D models to prepare prints.
enum BambuActions {
    static func open(_ args: [String: Any]) async -> String {
        guard let app = MacActions.findApp("bambustudio") ?? MacActions.findApp("bambu studio") else {
            return "Bambu Studio non è installato."
        }
        guard let query = args.string("model"), !query.isEmpty else {
            _ = await Shell.run("/usr/bin/open", ["-a", app.path])
            return "Aperto Bambu Studio."
        }
        let result = await Shell.run("/usr/bin/mdfind", ["-onlyin", NSHomeDirectory() + "/Projects", "-name", query], timeout: 10)
        let files = result.out.split(separator: "\n").map(String.init).filter {
            let ext = ($0 as NSString).pathExtension.lowercased()
            return ["3mf", "stl", "step", "stp", "obj"].contains(ext) && !$0.contains("/archivio/")
        }
        // Prepared projects (3MF) first, then models.
        guard let file = files.first(where: { $0.lowercased().hasSuffix(".3mf") }) ?? files.first else {
            return "Nessun modello 3D trovato per \"\(query)\"."
        }
        _ = await Shell.run("/usr/bin/open", ["-a", app.path, file])
        return "Aperto \((file as NSString).lastPathComponent) in Bambu Studio."
    }
}
