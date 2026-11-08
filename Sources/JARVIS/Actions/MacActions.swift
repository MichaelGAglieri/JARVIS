import AppKit
import Foundation

/// Apps, system settings, music, files and Shortcuts.
enum MacActions {
    // MARK: Apps

    private static let appFolders = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                                     // Safari lives here, not in /Applications.
                                     "/System/Cryptexes/App/System/Applications",
                                     NSHomeDirectory() + "/Applications", "/Applications/Utilities"]

    /// All installed apps, also in subfolders (Autodesk, Chrome Apps).
    static func installedApps() -> [URL] {
        appFolders.flatMap { folder -> [URL] in
            guard let items = FileManager.default.enumerator(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: nil,
                                                             options: [.skipsPackageDescendants, .skipsHiddenFiles]) else { return [] }
            var found: [URL] = []
            for case let url as URL in items {
                if items.level > 3 { items.skipDescendants() }
                if url.pathExtension == "app" { found.append(url) }
            }
            return found
        }
    }

    /// Uninstallers are never opened by similarity, and JARVIS does not suggest them.
    private static func isUninstaller(_ name: String) -> Bool {
        let lower = name.lowercased()
        return ["remove ", "rimuovi ", "uninstall", "disinstalla"].contains { lower.hasPrefix($0) }
    }

    /// Name → app: the file name and the one shown by the Finder ("Reminders", "Promemoria").
    private static func appsByName() -> [String: URL] {
        var names: [String: URL] = [:]
        let apps = installedApps().filter { !isUninstaller($0.deletingPathExtension().lastPathComponent) }
        // File names first: "Siri" is Siri, not Siri AI, which has the same name in Italian.
        for url in apps {
            let file = url.deletingPathExtension().lastPathComponent
            if names[file] == nil { names[file] = url }
        }
        for url in apps {
            let shown = (FileManager.default.displayName(atPath: url.path) as NSString).deletingPathExtension
            for name in [shown, italianName(of: url)].compactMap({ $0 }) where names[name] == nil { names[name] = url }
        }
        return names
    }

    private static let italianNamesLock = NSLock()
    nonisolated(unsafe) private static var italianNames: [String: String?] = [:]

    /// The Italian name written inside the app itself: Clock is "Orologio", Weather is "Meteo".
    static func italianName(of url: URL) -> String? {
        italianNamesLock.lock()
        defer { italianNamesLock.unlock() }
        if let known = italianNames[url.path] { return known }
        let resources = url.appendingPathComponent("Contents/Resources")
        func table(_ file: String) -> [String: Any]? {
            guard let data = try? Data(contentsOf: resources.appendingPathComponent(file)) else { return nil }
            return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        }
        let strings = (table("InfoPlist.loctable")?["it"] as? [String: Any]) ?? table("it.lproj/InfoPlist.strings")
        let raw = (strings?["CFBundleDisplayName"] ?? strings?["CFBundleName"]) as? String
        // Some apps have invisible characters in their name (WhatsApp).
        let name = raw.map { String(String.UnicodeScalarView($0.unicodeScalars.filter { !$0.properties.isDefaultIgnorableCodePoint })) }
        italianNames[url.path] = name
        return name
    }

    /// How the app is called aloud, in the language of the answer.
    static func spokenName(of url: URL, italian: Bool) -> String {
        let file = url.deletingPathExtension().lastPathComponent
        // Saved web apps are called "Home - Netflix": aloud "Netflix" is enough.
        let short = file.hasPrefix("Home - ") ? String(file.dropFirst(7)) : file
        return italian ? italianName(of: url) ?? short : short
    }

    /// The list JARVIS keeps in mind, to recognise names even when misheard.
    static func installedAppNames() -> [String] {
        Set(installedApps().map { $0.deletingPathExtension().lastPathComponent })
            .filter { !isUninstaller($0) && $0 != "JARVIS" }.sorted()
    }

    private static func canonicalName(_ name: String) -> String {
        let aliases = ["vs code": "visual studio code", "vscode": "visual studio code", "code": "visual studio code",
                       "impostazioni": "system settings", "impostazioni di sistema": "system settings",
                       "calendario": "calendar", "promemoria": "reminders", "note": "notes", "musica": "music",
                       "posta": "mail", "foto": "photos", "messaggi": "messages", "terminale": "terminal",
                       "calcolatrice": "calculator", "mappe": "maps", "anteprima": "preview", "fusion": "autodesk fusion",
                       "fusion 360": "autodesk fusion", "bambu": "bambustudio", "arduino": "arduino ide",
                       "word": "microsoft word", "excel": "microsoft excel", "powerpoint": "microsoft powerpoint",
                       "power point": "microsoft powerpoint", "gpt": "chatgpt", "chat gpt": "chatgpt", "netflix": "home - netflix"]
        let query = name.lowercased().trimmingCharacters(in: .whitespaces)
        return aliases[query] ?? name
    }

    /// Finds the requested app, tolerating misheard names.
    /// The last frontmost app, JARVIS excluded: "premi Slice" with no other name refers to it.
    private static var lastFrontApp: String?
    private static var frontObserver: NSObjectProtocol?

    static func watchFrontApp() {
        guard frontObserver == nil else { return }
        func remember(_ app: NSRunningApplication?) {
            guard let app, app.bundleIdentifier != Bundle.main.bundleIdentifier, let name = app.localizedName else { return }
            lastFrontApp = name
        }
        remember(NSWorkspace.shared.frontmostApplication)
        frontObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            remember(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        }
    }

    static func frontAppContext() -> String? {
        lastFrontApp.map { "[frontmost app: \($0)]" }
    }

    static func lookUpApp(_ name: String, sure: Double = 0.70) -> (url: URL?, match: AppIndex.Match) {
        let apps = appsByName()
        let match = AppIndex.resolve(canonicalName(name), among: Array(apps.keys).sorted(), sure: sure)
        if case .found(let found) = match { return (apps[found], match) }
        return (nil, match)
    }

    static func findApp(_ name: String) -> URL? { lookUpApp(name).url }

    static func openApp(_ args: [String: Any]) async -> String {
        let name = args.string("name") ?? "?"
        let (found, match) = lookUpApp(name)
        guard let url = found else {
            switch match {
            case .ambiguous(let names):
                return "Più app somigliano a \"\(name)\": \(names.joined(separator: ", ")). Chiedi quale, nominandole."
            case .none(let similar) where !similar.isEmpty:
                return "App non trovata: \(name). Le più simili sono \(similar.joined(separator: ", ")): se una suona come quella chiesta aprila, altrimenti chiedi quale."
            default:
                return "App non trovata: \(name)"
            }
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
            return "Aperta \(url.deletingPathExtension().lastPathComponent)"
        } catch {
            return "Errore aprendo \(name): \(error.localizedDescription)"
        }
    }

    @MainActor
    /// Name of an open app. Safari web apps (Netflix, YouTube…) for macOS
    /// are all called "Web App": the real name is the bundle's.
    static func displayName(_ app: NSRunningApplication) -> String {
        let bundleName = app.bundleURL?.deletingPathExtension().lastPathComponent
        if app.bundleIdentifier?.hasPrefix("com.apple.Safari.WebApp") == true || app.localizedName == "Web App",
           let bundleName { return bundleName }
        return app.localizedName ?? bundleName ?? "?"
    }

    /// Apps that "close everything" does not touch: JARVIS, Finder, the desktop widget and LuLu.
    private static let keepOpen: Set<String> = [jarvisBundleID, "com.apple.finder",
                                                "tracesOf.Uebersicht", "com.objective-see.lulu.app"]

    /// Apps with no work to lose: they save by themselves or have no documents.
    private static let lightApps: Set<String> = [
        "com.apple.Notes", "com.apple.reminders", "com.apple.iCal", "com.apple.calculator", "com.apple.clock",
        "com.apple.weather", "com.apple.Maps", "com.apple.Music", "com.apple.TV", "com.apple.podcasts",
        "com.apple.iBooksX", "com.apple.news", "com.apple.stocks", "com.apple.Home", "com.apple.AddressBook",
    ]

    /// Quits without asking, unless macOS reports unsaved changes. If the app does not
    /// say so it quits anyway: it is a normal quit, an app with an open document asks by itself.
    @MainActor
    static func closesWithoutAsking(_ app: NSRunningApplication) -> Bool {
        if lightApps.contains(app.bundleIdentifier ?? "") { return true }
        var value: CFTypeRef?
        guard AXIsProcessTrusted(),
              AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return true }
        return !windows.contains { window in
            // macOS exposes it on the close button (the dot in the middle), not on the window.
            var button: CFTypeRef?, edited: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &button) == .success, let button else { return false }
            return AXUIElementCopyAttributeValue(button as! AXUIElement, kAXEditedAttribute as CFString, &edited) == .success && edited as? Bool == true
        }
    }

    /// The name of the open app, only if it is almost certainly the requested one.
    @MainActor
    static func runningApp(named name: String, sure: Double) -> String? {
        let open = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !keepOpen.contains($0.bundleIdentifier ?? "")
        }
        let names = open.flatMap { app -> [String] in
            [displayName(app), app.bundleURL?.deletingPathExtension().lastPathComponent ?? "", app.bundleURL.flatMap(italianName) ?? ""]
        }.filter { !$0.isEmpty }
        if case .found(let found) = AppIndex.resolve(canonicalName(name), among: Array(Set(names)).sorted(), sure: sure) { return found }
        return nil
    }

    /// Open apps with those names (separated by commas or "e"), or all of them with `all`.
    @MainActor
    static func matchingApps(_ args: [String: Any]) -> [NSRunningApplication] {
        let open = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !keepOpen.contains($0.bundleIdentifier ?? "")
        }
        if args.bool("all") == true { return open }
        guard let raw = args.string("name") else { return [] }
        let names = raw.lowercased()
            .replacingOccurrences(of: " e ", with: ",").replacingOccurrences(of: " and ", with: ",")
            .components(separatedBy: CharacterSet(charactersIn: ",;"))
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var found: [NSRunningApplication] = []
        for name in names {
            // Open apps first: "chiudi craft" is clear if only one is open.
            var target = name
            if case .found(let running) = AppIndex.resolve(name, among: open.map(displayName)) {
                target = running.lowercased()
            } else if let url = findApp(name) {
                target = url.deletingPathExtension().lastPathComponent.lowercased()
            }
            for app in open where !found.contains(app) {
                // Displayed name ("Calcolatrice") and file name ("Calculator") can differ.
                let file = app.bundleURL?.deletingPathExtension().lastPathComponent.lowercased() ?? ""
                let shown = displayName(app).lowercased() + " " + file
                if shown.contains(target) || shown.contains(name) { found.append(app) }
            }
        }
        return found
    }

    @MainActor
    static func quit(_ apps: [NSRunningApplication]) -> String {
        let names = apps.map(displayName)
        apps.forEach { $0.terminate() }
        return "Chiuse: " + names.joined(separator: ", ")
    }

    @MainActor
    static func runningApps() -> String {
        let names = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map { displayName($0) }
        return "App aperte: " + names.joined(separator: ", ")
    }

    // MARK: System

    static func currentVolume() async -> Int? {
        Int(await Shell.osascript("output volume of (get volume settings)").out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func setVolume(_ args: [String: Any]) async -> String {
        if let mute = args.bool("mute") {
            _ = await Shell.osascript("set volume output muted \(mute)")
            return mute ? "Audio silenziato" : "Audio riattivato"
        }
        guard let level = args.number("level") else {
            let current = await Shell.osascript("output volume of (get volume settings)")
            return "Volume attuale: \(current.out)%"
        }
        let value = Int(max(0, min(100, level)))
        _ = await Shell.osascript("set volume output volume \(value) without output muted")
        return "Volume al \(value)%"
    }

    static func setDarkMode(_ args: [String: Any]) async -> String {
        let value = args.bool("enabled").map { $0 ? "true" : "false" } ?? "not dark mode"
        let result = await Shell.osascript("tell application \"System Events\" to tell appearance preferences to set dark mode to \(value)")
        return result.ok ? "Aspetto aggiornato" : "Errore: \(result.err)"
    }

    static func sleepDisplay() async -> String {
        _ = await Shell.run("/usr/bin/pmset", ["displaysleepnow"])
        return "Schermo spento"
    }

    static func systemStatus() async -> String {
        let battery = await Shell.run("/usr/bin/pmset", ["-g", "batt"])
        let disk = await Shell.run("/bin/df", ["-h", "/"])
        let uptime = ProcessInfo.processInfo.systemUptime
        let diskLine = disk.out.split(separator: "\n").last.map(String.init) ?? ""
        let diskParts = diskLine.split(separator: " ", omittingEmptySubsequences: true)
        let free = diskParts.count > 3 ? String(diskParts[3]) : "?"
        let batteryLine = battery.out.split(separator: "\n").dropFirst().first.map(String.init) ?? battery.out
        let memory = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        return """
        Batteria: \(batteryLine.trimmingCharacters(in: .whitespaces))
        Disco libero: \(free)
        Memoria totale: \(Int(memory)) GB
        Acceso da: \(Int(uptime / 3600)) ore
        """
    }

    // MARK: Music (Music app)

    static func music(_ args: [String: Any]) async -> String {
        let action = args.string("action")?.lowercased() ?? "playpause"
        let query = args.string("query")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch action {
        case "search", "play" where !query.isEmpty, "playlist" where !query.isEmpty:
            return await playMusic(query)
        case "playlist", "search":
            return "Manca cosa cercare"
        case "volume":
            guard let level = args.number("level") else { return await musicScript("return sound volume as text") }
            let result = await musicScript("set sound volume to \(Int(max(0, min(100, level))))\nreturn \"Volume di Musica al \" & sound volume & \"%\"")
            return result
        case "play":
            return await musicScript("play\ndelay 0.5\nreturn \(nowPlayingScript)")
        default:
            // With the app closed there is nothing to stop or skip: it is not opened just to say so.
            guard musicIsRunning else { return "Musica non è aperta" }
            switch action {
            case "pause": return await musicScript("pause\nreturn \"Musica in pausa\"")
            case "next": return await musicScript("next track\ndelay 0.5\nreturn \(nowPlayingScript)")
            case "previous":
                // When streaming, the first "previous" goes back to the start of the same track: then another is needed.
                return await musicScript("""
                    set before to name of current track
                    previous track
                    delay 1
                    if name of current track is before then
                        previous track
                        delay 1
                    end if
                    return \\(nowPlayingScript)
                    """)
            case "status": return await musicScript("return \(nowPlayingScript)")
            default: return await musicScript("playpause\ndelay 0.5\nreturn \(nowPlayingScript)")
            }
        }
    }

    static var musicIsRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty
    }

    /// Music just opened does not answer for a few seconds, and with the first page it hangs.
    private static func musicReady() async {
        guard !musicIsRunning else { return }
        _ = await Shell.run("/usr/bin/open", ["-g", "-a", "Music"])
        for _ in 0..<20 {
            try? await Task.sleep(for: .seconds(1))
            if !(await musicScript("return sound volume as text", timeout: 3)).hasPrefix("Errore") { break }
        }
        try? await Task.sleep(for: .seconds(2))
    }

    private static let nowPlayingScript = "(my stateText())"

    private static func musicScript(_ body: String, timeout: Double = 20) async -> String {
        let script = """
        on trackName()
            tell application "Music"
                try
                    return name of current track
                on error
                    return ""
                end try
            end tell
        end trackName
        on stateText()
            tell application "Music"
                if player state is playing then return "In riproduzione: " & name of current track & " — " & artist of current track
                return "Musica in pausa"
            end tell
        end stateText
        tell application "Music"
        \(body)
        end tell
        """
        let result = await Shell.osascript(script, timeout: timeout)
        return result.ok ? (result.out.isEmpty ? "Fatto" : result.out) : "Errore Musica: \(result.err)"
    }

    /// First among the user's playlists and tracks, then in the Apple Music catalog.
    private static func playMusic(_ query: String) async -> String {
        await musicReady()
        let quoted = Shell.quote(query)
        let local = await musicScript("""
            if (exists user playlist \(quoted)) then
                play user playlist \(quoted)
                return "In riproduzione la playlist " & \(quoted)
            end if
            set results to (search library playlist 1 for \(quoted))
            if (count of results) is 0 then return "NESSUNO"
            play item 1 of results
            return "In riproduzione: " & name of item 1 of results & " — " & artist of item 1 of results
            """)
        guard local == "NESSUNO" else { return local }
        let hits = await musicCatalog(query)
        guard !hits.isEmpty else { return "Non trovo \(query) nemmeno nel catalogo di Apple Music." }
        // Some compilations have the track under another title: a second album is also tried.
        var answer = ""
        for hit in hits.prefix(2) {
            answer = await playFromCatalog(hit)
            if answer.hasPrefix("In riproduzione") { break }
        }
        return answer
    }

    private struct CatalogHit: Decodable {
        let trackName: String
        let artistName: String
        let trackViewUrl: String
        let trackNumber: Int?
        let trackCount: Int?
    }

    /// Apple's public search: no account needed, and it receives only the searched words.
    private static func musicCatalog(_ query: String) async -> [CatalogHit] {
        struct Page: Decodable { let results: [CatalogHit] }
        var parts = URLComponents(string: "https://itunes.apple.com/search")!
        parts.queryItems = [.init(name: "term", value: query), .init(name: "media", value: "music"), .init(name: "entity", value: "song"),
                            .init(name: "limit", value: "10"), .init(name: "country", value: Locale.current.region?.identifier ?? "IT")]
        guard let url = parts.url, let (data, _) = try? await URLSession.shared.data(from: url),
              let results = (try? JSONDecoder().decode(Page.self, from: data))?.results else { return [] }
        // The live version or the cover are not what is asked for, unless said.
        let words = query.lowercased()
        func penalty(_ hit: CatalogHit) -> Int {
            let title = hit.trackName.lowercased()
            let unwanted = ["live", "karaoke", "tribute", "cover", "instrumental", "remix", "dal vivo"].filter { title.contains($0) && !words.contains($0) }.count
            let artist = hit.artistName.lowercased().split(separator: " ").contains { words.contains($0) } ? 0 : 1
            return unwanted * 2 + artist
        }
        return results.enumerated().sorted { (penalty($0.element), $0.offset) < (penalty($1.element), $1.offset) }.map(\.element)
    }

    /// A specific track cannot be started from the catalog: Music opens its album and `play` starts from the first.
    /// So the track is reached with "next", at zero volume so the others are not heard.
    private static func playFromCatalog(_ hit: CatalogHit) async -> String {
        let link = hit.trackViewUrl.replacingOccurrences(of: "https://", with: "music://")
        await musicReady()
        // The volume returns to what it was even if the script is interrupted: Music must not stay muted.
        let volume = Int(await musicScript("return sound volume as text"))
        _ = await musicScript("stop")
        _ = await Shell.run("/usr/bin/open", ["-g", link])
        let wanted = Shell.quote(hit.trackName)
        let current = await musicScript("""
            set sound volume to 0
            set savedShuffle to shuffle enabled
            set shuffle enabled to false
            -- La pagina nuova deve caricarsi, o `play` riprende l'album di prima.
            delay 3
            repeat 20 times
                play
                delay 0.5
                if player state is playing and (my trackName()) is not "" then exit repeat
            end repeat
            repeat \((hit.trackCount ?? hit.trackNumber ?? 1) + 1) times
                set seen to my trackName()
                if seen is \(wanted) then exit repeat
                next track
                -- Il brano cambia con un po' di ritardo: senza aspettarlo si va oltre.
                repeat 20 times
                    delay 0.2
                    if my trackName() is not seen then exit repeat
                end repeat
            end repeat
            set shuffle enabled to savedShuffle
            return "BRANO:" & my trackName()
            """, timeout: 40)
        if let volume { _ = await musicScript("set sound volume to \(volume)") }
        Diagnostics.log("musica    cercavo \(hit.trackName) (\(hit.trackNumber ?? 0)/\(hit.trackCount ?? 0)): \(current)")
        let name = current.hasPrefix("BRANO:") ? String(current.dropFirst(6)) : ""
        if name.caseInsensitiveCompare(hit.trackName) == .orderedSame { return "In riproduzione: \(hit.trackName) — \(hit.artistName)" }
        return name.isEmpty
            ? "Ho aperto \(hit.trackName) di \(hit.artistName) in Musica, ma non è partito: va premuto Riproduci, oppure manca l'abbonamento su questo Mac."
            : "Non sono arrivato a \(hit.trackName): ora suona \(name). Forse è attiva la riproduzione casuale."
    }

    // MARK: Files and projects

    /// Searches by words, not by exact name: "chimica organica dispenser"
    /// finds "Chimica_Organica_Dispense.pdf" (case, underscores and small
    /// dictation errors do not matter).
    static func searchFiles(_ args: [String: Any]) async -> String {
        guard let query = args.string("query"), !query.isEmpty else { return "Ricerca vuota" }
        let paths = await fuzzyFind(query)
        return paths.isEmpty ? "Nessun file trovato per \(query)" : "File trovati (il primo è il più simile):\n" + paths.prefix(10).joined(separator: "\n")
    }

    static func openPath(_ args: [String: Any]) async -> String {
        guard var path = args.string("path") else { return "Percorso mancante" }
        path = (path as NSString).expandingTildeInPath
        if !FileManager.default.fileExists(atPath: path) {
            // The model rebuilt the path from memory: look for the most similar file.
            guard let found = await resolve(path) else {
                return "Il percorso non esiste: \(path). Usa search_files con alcune parole del nome."
            }
            path = found
        }
        var arguments = [path]
        if let app = args.string("app"), let url = findApp(app) { arguments = ["-a", url.path, path] }
        if args.bool("reveal") == true { arguments = ["-R", path] }
        let result = await Shell.run("/usr/bin/open", arguments)
        return result.ok ? "Aperto \(path)" : "Errore: \(result.err)"
    }

    /// Missing path → the file with the most similar name, first in the same
    /// folder (even if written with different case), then in the whole home.
    private static func resolve(_ path: String) async -> String? {
        let fm = FileManager.default
        let name = (path as NSString).lastPathComponent
        var folder = ""
        for part in (path as NSString).deletingLastPathComponent.split(separator: "/") {
            let parent = folder.isEmpty ? "/" : folder
            let exact = parent + (parent.hasSuffix("/") ? "" : "/") + part
            if fm.fileExists(atPath: exact) { folder = exact; continue }
            guard let match = (try? fm.contentsOfDirectory(atPath: parent))?
                    .first(where: { words($0) == words(String(part)) }) else { folder = ""; break }
            folder = parent + (parent.hasSuffix("/") ? "" : "/") + match
        }
        if !folder.isEmpty, let items = try? fm.contentsOfDirectory(atPath: folder) {
            let best = items.map { ($0, similarity(name, $0)) }.max { $0.1 < $1.1 }
            if let best, best.1 >= 0.75 { return folder + "/" + best.0 }
        }
        let stem = (name as NSString).deletingPathExtension
        guard let first = await fuzzyFind(stem).first,
              similarity(stem, (first as NSString).lastPathComponent) >= 0.75 else { return nil }
        return first
    }

    /// Spotlight on the longest word, then sorts by similarity with the whole sentence.
    private static func fuzzyFind(_ query: String) async -> [String] {
        let queryWords = words(query)
        guard let key = queryWords.max(by: { $0.count < $1.count }) else { return [] }
        // Word stem: "dispenser" also finds "dispense".
        let root = String(key.prefix(max(4, key.count - 2)))
        let result = await Shell.run("/usr/bin/mdfind", ["-onlyin", NSHomeDirectory(), "-name", root], timeout: 10)
        var paths = result.out.split(separator: "\n").map(String.init)
            .filter { !$0.contains("/Library/") && !$0.contains("/.") && !$0.contains("/node_modules/") && !$0.contains("/build/") }
        // Spotlight does not show Desktop, Documents and Downloads to an app without
        // permission: there the search is also done directly (macOS asks on first use).
        let scanned = await Task.detached(priority: .userInitiated) { scanProtectedFolders(matching: root) }.value
        for path in scanned where !paths.contains(path) { paths.append(path) }
        return paths.map { ($0, similarity(query, ($0 as NSString).lastPathComponent)) }
            .filter { $0.1 >= 0.5 }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// Folders that macOS protects with a permission: Desktop, Documents,
    /// Downloads, iCloud Drive, external and network drives. Never the system
    /// folders (/System, /Library, ~/Library).
    private static func scanProtectedFolders(matching root: String) -> [String] {
        let fm = FileManager.default
        let home = URL(fileURLWithPath: NSHomeDirectory())
        var bases = ["Desktop", "Documents", "Downloads"].map { home.appendingPathComponent($0) }
        bases.append(home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs"))
        let boot = (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey]))?.volumeName
        for volume in (try? fm.contentsOfDirectory(atPath: "/Volumes")) ?? [] where volume != boot {
            bases.append(URL(fileURLWithPath: "/Volumes").appendingPathComponent(volume))
        }
        var found: [String] = []
        for base in bases {
            guard let items = fm.enumerator(at: base, includingPropertiesForKeys: nil,
                                            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in items {
                if items.level > 4 { items.skipDescendants(); continue }
                if ["node_modules", "build", "Library", "System"].contains(url.lastPathComponent) { items.skipDescendants(); continue }
                if words(url.lastPathComponent).contains(where: { $0.hasPrefix(root) }) { found.append(url.path) }
                if found.count >= 50 { return found }
            }
        }
        return found
    }

    /// Lowercase words without accents, splitting on spaces, hyphens and underscores.
    private static func words(_ s: String) -> [String] {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !["pdf", "doc", "docx", "txt", "md"].contains($0) }
    }

    /// Share of searched words present in the name (tolerating errors).
    private static func similarity(_ query: String, _ name: String) -> Double {
        let q = words(query), n = words(name)
        guard !q.isEmpty else { return 0 }
        let hits = q.filter { w in n.contains { close(w, $0) } }.count
        return Double(hits) / Double(q.count)
    }

    private static func close(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        // Short acronyms misheard: "ros" for "ross" or "pid" for "pi di".
        if min(a.count, b.count) >= 3 && (a.hasPrefix(b) || b.hasPrefix(a)) { return true }
        if a.count == 4 && b.count == 4 { return editDistance(a, b) <= 2 && a.first == b.first }
        // Surnames and long words: "ardoino" for "arduino".
        return a.count >= 5 && editDistance(a, b) <= (a.count >= 6 ? 2 : 1)
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty, !b.isEmpty else { return max(a.count, b.count) }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var row = [i] + [Int](repeating: 0, count: b.count)
            for j in 1...b.count {
                row[j] = min(prev[j] + 1, row[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = row
        }
        return prev[b.count]
    }

    /// Projects in ~/Projects, including collections such as ~/Projects/Robotica.
    @MainActor
    static func listProjects() -> String {
        let folders = ProjectInsights.projectFolders()
        guard !folders.isEmpty else { return "Nessun progetto in ~/Projects" }
        let grouped = Dictionary(grouping: folders) { $0.deletingLastPathComponent().lastPathComponent }
        return grouped.sorted { $0.key < $1.key }.map { group, items in
            "\(group == "Projects" ? "Progetti" : group): " + items.map(\.lastPathComponent).sorted().joined(separator: ", ")
        }.joined(separator: "\n") + "\n(Usa project_info per i dettagli. Non leggere i percorsi ad alta voce.)"
    }

    // MARK: Shortcuts

    static func runShortcut(_ args: [String: Any]) async -> String {
        guard let name = args.string("name") else { return "Nome comando rapido mancante" }
        var arguments = ["run", name]
        if let input = args.string("input") {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-shortcut-input.txt")
            try? input.write(to: file, atomically: true, encoding: .utf8)
            arguments += ["--input-path", file.path]
        }
        let result = await Shell.run("/usr/bin/shortcuts", arguments, timeout: 90)
        if result.ok { return result.out.isEmpty ? "Comando rapido \(name) eseguito" : "Risultato: \(result.out.prefix(1500))" }
        return "Errore eseguendo \(name): \(result.err.prefix(300))"
    }

    static func listShortcuts() async -> String {
        let result = await Shell.run("/usr/bin/shortcuts", ["list"])
        return result.out.isEmpty ? "Nessun comando rapido" : "Comandi rapidi: " + result.out.split(separator: "\n").joined(separator: ", ")
    }
}
