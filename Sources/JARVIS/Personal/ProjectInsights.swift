import Foundation

/// Knowledge of the projects in ~/Projects: README, git status, recent work.
enum ProjectInsights {
    static let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Projects")

    /// Project folders: those in ~/Projects and, for collections such as
    /// ~/Projects/Robotica, those inside them.
    static func projectFolders() -> [URL] {
        let fm = FileManager.default
        func dirs(_ url: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
                .filter { !$0.lastPathComponent.hasPrefix(".") && (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        }
        return dirs(root).flatMap { dir -> [URL] in
            dir.lastPathComponent.lowercased().hasSuffix("projects") ? dirs(dir) : [dir]
        }
    }

    static func find(_ name: String) -> URL? {
        func norm(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let q = norm(name)
        guard !q.isEmpty else { return nil }
        let folders = projectFolders()
        return folders.first { norm($0.lastPathComponent) == q }
            ?? folders.first { norm($0.lastPathComponent).hasPrefix(q) }
            ?? folders.first { norm($0.lastPathComponent).contains(q) || q.contains(norm($0.lastPathComponent)) }
    }

    static func info(_ args: [String: Any]) async -> String {
        guard let name = args.string("name"), let dir = find(name) else {
            return "Progetto non trovato. Progetti disponibili: " + projectFolders().map(\.lastPathComponent).joined(separator: ", ")
        }
        var out = "Progetto \(dir.lastPathComponent) (percorso \(dir.path))\n"

        let readmeNames = ["README.md", "readme.md", "README.MD", "00_INIZIA_QUI.md", "README.txt", "README"]
        if let readme = readmeNames.map({ dir.appendingPathComponent($0) }).first(where: { FileManager.default.fileExists(atPath: $0.path) }),
           let text = try? String(contentsOf: readme, encoding: .utf8) {
            out += "\nREADME (inizio):\n" + text.prefix(1500) + "\n"
        }

        if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) {
            let log = await Shell.run("/usr/bin/git", ["-C", dir.path, "log", "-6", "--format=%ar: %s"], timeout: 10)
            let status = await Shell.run("/usr/bin/git", ["-C", dir.path, "status", "--short"], timeout: 10)
            let branch = await Shell.run("/usr/bin/git", ["-C", dir.path, "branch", "--show-current"], timeout: 10)
            let changed = status.out.split(separator: "\n").count
            out += "\nGit: ramo \(branch.out), \(changed) file modificati non salvati in un commit.\nUltimi commit:\n\(log.out)\n"
        } else {
            out += "\nNon è un repository git.\n"
        }

        let recent = await recentFiles(in: dir, days: 14, limit: 10)
        out += recent.isEmpty ? "\nNessun file modificato nelle ultime due settimane." : "\nFile modificati di recente:\n" + recent.joined(separator: "\n")
        return out
    }

    /// Which projects were worked on in the last few days (according to Spotlight).
    static func recentActivity(_ args: [String: Any]) async -> String {
        let days = Int(args.number("days") ?? 7)
        let query = "kMDItemFSContentChangeDate >= $time.today(-\(days))"
        let result = await Shell.run("/usr/bin/mdfind", ["-onlyin", root.path, query], timeout: 15)
        let folders = projectFolders()
        var counts: [String: (count: Int, latest: Date)] = [:]
        for line in result.out.split(separator: "\n") {
            let path = String(line)
            if path.contains("/.git/") || path.contains("/build/") || path.contains("/install/") || path.contains("/log/")
                || path.contains("/node_modules/") || path.contains("/.build/") { continue }
            guard let project = folders.first(where: { path.hasPrefix($0.path + "/") }) else { continue }
            let date = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
            let entry = counts[project.lastPathComponent] ?? (0, .distantPast)
            counts[project.lastPathComponent] = (entry.count + 1, max(entry.latest, date))
        }
        guard !counts.isEmpty else { return "Nessuna modifica ai progetti negli ultimi \(days) giorni." }
        return "Progetti modificati negli ultimi \(days) giorni:\n" + counts.sorted { $0.value.latest > $1.value.latest }.map {
            "- \($0.key): \($0.value.count) file, ultima modifica \($0.value.latest.formatted(.relative(presentation: .named)))"
        }.joined(separator: "\n")
    }

    private static func recentFiles(in dir: URL, days: Int, limit: Int) async -> [String] {
        let query = "kMDItemFSContentChangeDate >= $time.today(-\(days))"
        let result = await Shell.run("/usr/bin/mdfind", ["-onlyin", dir.path, query], timeout: 10)
        let files = result.out.split(separator: "\n").map(String.init).filter {
            !$0.contains("/.git/") && !$0.contains("/build/") && !$0.contains("/install/") && !$0.contains("/node_modules/") && !$0.contains("/.build/")
        }
        let dated = files.compactMap { path -> (String, Date)? in
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  attrs[.type] as? FileAttributeType == .typeRegular,
                  let date = attrs[.modificationDate] as? Date else { return nil }
            return (path, date)
        }
        return dated.sorted { $0.1 > $1.1 }.prefix(limit).map {
            "- \($0.0.replacingOccurrences(of: dir.path + "/", with: "")) (\($0.1.formatted(.relative(presentation: .named))))"
        }
    }
}
