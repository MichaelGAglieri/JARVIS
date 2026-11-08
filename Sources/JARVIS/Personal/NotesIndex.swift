import AppKit
import IOKit.ps
import PDFKit
import SQLite3
import Vision

/// Search in your notes: handouts and PDFs from the study folders, all local. The index is an
/// SQLite file, `appunti.sqlite`, and holds a copy of the text; the original files are only read.
///
/// Building the index reads thousands of pages and pushes RAM above 3 GB, so a separate
/// low-priority process does it, then quits and hands everything back.
enum NotesDatabase {
    static let url = JarvisConfig.directory.appendingPathComponent("appunti.sqlite")

    static func open(readOnly: Bool) -> OpaquePointer? {
        var db: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        sqlite3_busy_timeout(db, 3000)
        return db
    }

    static func run(_ db: OpaquePointer?, _ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Runs a statement with text or number parameters; `row` receives each row.
    @discardableResult
    static func query(_ db: OpaquePointer?, _ sql: String, _ values: [Any] = [], row: ((OpaquePointer) -> Void)? = nil) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return false }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case let number as Int: sqlite3_bind_int64(statement, position, Int64(number))
            case let number as Int64: sqlite3_bind_int64(statement, position, number)
            case let number as Double: sqlite3_bind_double(statement, position, number)
            case let data as Data: _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, position, $0.baseAddress, Int32(data.count), transient) }
            default: sqlite3_bind_text(statement, position, "\(value)", -1, transient)
            }
        }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: row?(statement)
            case SQLITE_DONE: return true
            default: return false
            }
        }
    }

    static func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }
}

// MARK: Search

enum NotesSearch {
    /// Words that tell nothing apart, in Italian and English, including those of spoken questions.
    private static let stopwords: Set<String> = [
        "il", "lo", "la", "gli", "le", "un", "uno", "una", "di", "da", "in", "con", "su", "per", "tra", "fra", "ed", "che", "chi", "cui",
        "del", "dello", "della", "dei", "degli", "delle", "al", "allo", "alla", "ai", "agli", "alle", "dal", "dallo", "dalla", "dai", "dagli", "dalle",
        "nel", "nello", "nella", "nei", "negli", "nelle", "sul", "sullo", "sulla", "sui", "sugli", "sulle", "cosa", "cos", "come", "quale", "quali", "qual", "quando",
        "dove", "perché", "perche", "sono", "ha", "hanno", "si", "non", "mi", "ti", "ci", "vi", "questo", "questa", "quello", "quella", "miei", "mie", "mio", "mia",
        "appunti", "dispensa", "dispense", "differenza", "funziona", "calcola", "significa", "spiega", "spiegami", "serve", "dimmi", "cerca", "dicono", "dice", "puoi",
        "the", "of", "and", "or", "to", "is", "are", "what", "how", "why", "when", "where", "an", "on", "for", "with",
    ]

    /// A word of the question. Long words lose their ending ("resistenze" finds "resistenza"); short
    /// ones do not, otherwise "costi" would find "costante": only its own forms are searched.
    struct Term {
        let word: String
        let stem: String
        var match: String {
            if stem != word, word.count <= 5 { return "(" + "aeio".map { "\"\(stem)\($0)\"" }.joined(separator: " OR ") + ")" }
            return "\"\(stem)\"*"
        }
    }

    static func terms(_ query: String) -> [Term] {
        let words = query.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !stopwords.contains($0) && ($0.count > 1 || $0.allSatisfy(\.isNumber)) }
        var seen = Set<String>()
        return words.compactMap { word in
            var stem = word
            if word.count >= 4, !word.contains(where: \.isNumber), let last = word.last, "aeiou".contains(last) {
                stem.removeLast()
                if word.count >= 6, let other = stem.last, "aeiou".contains(other), stem.count > 4 { stem.removeLast() }
            }
            return seen.insert(stem).inserted ? Term(word: word, stem: stem) : nil
        }
    }

    private struct Hit {
        let path: String
        let page: Int
        let text: String
    }

    static func search(query: String, subject: String?) -> String {
        var terms = terms(query)
        guard !terms.isEmpty else { return "Dimmi cosa cercare negli appunti: servono parole più precise." }
        guard FileManager.default.fileExists(atPath: NotesDatabase.url.path), let db = NotesDatabase.open(readOnly: true) else {
            return "L'indice degli appunti non è ancora pronto: si sta costruendo in sottofondo."
        }
        defer { sqlite3_close(db) }
        NotesDatabase.run(db, "CREATE VIRTUAL TABLE temp.vocabulary USING fts5vocab(main, passages, row)")
        var notes: [String] = []
        corrected(&terms, in: db, notes: &notes)
        var hits: [Hit] = []
        func add(_ match: String, keep: (Hit) -> Bool = { _ in true }) {
            for hit in passages(db, match: match, subject: subject) where keep(hit) {
                if !hits.contains(where: { $0.path == hit.path && $0.page == hit.page }) { hits.append(hit) }
            }
        }
        // "quick sort" is also "quicksort": first the whole word, if it exists in the notes.
        let joined = joinedTerms(terms, in: db)
        if joined.count != terms.count { add(expression(joined, near: joined.count > 1)) }
        // First the pages with the words close together, then those that have them all.
        if terms.count > 1 { add(expression(terms, near: true)) }
        let close = hits.count
        add(expression(terms, near: false))
        let whole = hits.count
        // Few pages with all the words: also those that have almost all of them, saying so. With two
        // words the rarer is enough, but not if a word was misspelled: the topic is not there.
        if hits.count < 3, terms.count >= 2, notes.isEmpty {
            let complete = hits.count
            if terms.count >= 3 {
                add(terms.map(\.match).joined(separator: " OR ")) { hit in
                    let folded = Self.folded(hit.text)
                    return terms.filter { folded.contains($0.stem) }.count >= terms.count - 1
                }
            } else if let rare = terms.filter({ exists($0.match, in: db) }).min(by: { documents($0, in: db) < documents($1, in: db) }), terms.allSatisfy({ exists($0.match, in: db) }) {
                add(rare.match)
            }
            if hits.count > complete { notes.append("(Nessuna o poche pagine hanno tutte le parole: alcuni passaggi ne contengono solo una parte, quindi possono non c'entrare.)") }
        }
        // Words find what is written that way; meaning finds what is said another way.
        // If the searched term is already there, clearly, there is no need to load the model: it costs RAM and seconds.
        let partial = Set(hits[whole...].map(key))
        let wordsOnly = Set(hits.map(key))
        var ordered = ranked(hits, terms: terms)
        var fromMeaning = Set<String>()
        let clear = terms.count <= 2 && (terms.count == 1 ? whole : close) >= 3
        if !clear, let similar = NotesVectors.similar(to: query, subject: subject, in: db) {
            ordered = merge(words: ordered, partial: partial, meaning: similar, in: db)
            fromMeaning = Set(ordered.map(key)).subtracting(wordsOnly)
        }
        if !fromMeaning.isEmpty { notes.append("(Alcuni passaggi sono stati trovati per significato: possono non contenere le parole della domanda.)") }
        let note = (notes + [status(db)]).joined(separator: " ")
        guard !ordered.isEmpty else {
            return "Nessun passaggio trovato per \"\(query)\": negli appunti indicizzati non c'è, o è detto con altre parole. Prova con sinonimi o in inglese. \(note)"
        }
        var perFile: [String: Int] = [:]
        var seenPages = Set<String>()
        var lines: [String] = []
        for hit in ordered {
            // The same book in two copies: the same page appears once.
            guard seenPages.insert(String(folded(hit.text).prefix(200))).inserted else { continue }
            perFile[hit.path, default: 0] += 1
            guard perFile[hit.path, default: 0] <= 2, lines.count < 6 else { continue }
            let file = (hit.path as NSString).lastPathComponent
            let folder = ((hit.path as NSString).deletingLastPathComponent as NSString).lastPathComponent
            lines.append("[\(lines.count + 1)] \(file), pagina \(hit.page) (cartella \(folder))\n\(fromMeaning.contains(key(hit)) ? meaningExcerpt(hit.text) : excerpt(hit.text, around: terms))")
        }
        return Security.external("appunti", lines.joined(separator: "\n\n")) + "\nI passaggi possono non rispondere alla domanda: controlla prima di citarli. Se ne usi uno, chiudi la risposta dicendo a voce il nome del documento e il numero di pagina, per esempio: \"È in Lezione 9, pagina 4.\" \(note)"
    }

    private static func key(_ hit: Hit) -> String { "\(hit.path)#\(hit.page)" }

    /// Rank fusion (reciprocal rank fusion): counts how high a passage is in each
    /// list, so scores of a different nature are not compared. Whoever is in both rises.
    /// Pages that have only some of the words count little: they often talk about something else.
    private static func merge(words: [Hit], partial: Set<String>, meaning: [Int64], in db: OpaquePointer) -> [Hit] {
        var scores: [String: Double] = [:]
        var found: [String: Hit] = [:]
        for (position, hit) in words.enumerated() {
            let weight = partial.contains(key(hit)) ? NotesVectors.partialWeight : NotesVectors.wordsWeight
            scores[key(hit), default: 0] += weight / (NotesVectors.rankOffset + Double(position))
            found[key(hit)] = hit
        }
        for (position, id) in meaning.enumerated() {
            NotesDatabase.query(db, "SELECT path, page, text FROM passages WHERE rowid = ?", [id]) { row in
                let hit = Hit(path: NotesDatabase.text(row, 0), page: Int(sqlite3_column_int(row, 1)), text: NotesDatabase.text(row, 2))
                scores[key(hit), default: 0] += 1 / (NotesVectors.rankOffset + Double(position))
                if found[key(hit)] == nil { found[key(hit)] = hit }
            }
        }
        return found.values.sorted { first, second in
            let (a, b) = (scores[key(first)] ?? 0, scores[key(second)] ?? 0)
            return a == b ? key(first) < key(second) : a > b
        }
    }

    private static func expression(_ terms: [Term], near: Bool) -> String {
        guard near else { return terms.map(\.match).joined(separator: " AND ") }
        return "NEAR(" + terms.map { "\"\($0.stem)\"*" }.joined(separator: " ") + ", 12)"
    }

    private static func folded(_ text: String) -> String {
        text.lowercased().folding(options: .diacriticInsensitive, locale: nil)
    }

    private static func passages(_ db: OpaquePointer, match: String, subject: String?) -> [Hit] {
        var found: [Hit] = []
        var sql = "SELECT path, page, text FROM passages WHERE passages MATCH ?"
        var values: [Any] = [match]
        if let subject, !subject.isEmpty {
            sql += " AND path LIKE ?"
            values.append("%\(subject)%")
        }
        sql += " ORDER BY bm25(passages, 4.0, 1.0) LIMIT 30"
        NotesDatabase.query(db, sql, values) { row in
            found.append(Hit(path: NotesDatabase.text(row, 0), page: Int(sqlite3_column_int(row, 1)), text: NotesDatabase.text(row, 2)))
        }
        return found
    }

    /// Pages that start with the topic rise; indexes and exam syllabi, which name everything, sink.
    private static func ranked(_ hits: [Hit], terms: [Term]) -> [Hit] {
        let scored = hits.enumerated().map { index, hit -> (Int, Hit) in
            let start = folded(String(hit.text.prefix(160)))
            var score = index
            if terms.allSatisfy({ start.contains($0.stem) }) { score -= 10 }
            let name = folded((hit.path as NSString).lastPathComponent)
            if ["trasparenza", "syllabus"].contains(where: name.contains) || start.hasPrefix("indice") { score += 30 }
            return (score, hit)
        }
        return scored.sorted { $0.0 < $1.0 }.map(\.1)
    }

    // MARK: Misheard words

    /// Whisper may write "Tevenin" or "Kirkoff": if a word is missing, look for the closest among
    /// those in the notes, and say which, so one can judge whether it is the right one.
    private static func corrected(_ terms: inout [Term], in db: OpaquePointer, notes: inout [String]) {
        for index in terms.indices {
            let term = terms[index]
            guard term.word.count >= 4, !term.word.contains(where: \.isNumber), !exists(term.match, in: db), let first = term.word.first else { continue }
            // "Karno" is the start of "Karnaugh": it is not misspelled, just cut short.
            if exists("\"\(term.word)\"*", in: db) {
                terms[index] = Term(word: term.word, stem: term.word)
                continue
            }
            let limit = term.word.count >= 7 ? 2 : 1
            let sound = sounds(term.word)
            var best: (distance: Int, documents: Int, word: String)?
            let next = String(UnicodeScalar(first.unicodeScalars.first!.value + 1)!)
            NotesDatabase.query(db, "SELECT term, doc FROM temp.vocabulary WHERE term >= ? AND term < ? AND length(term) BETWEEN ? AND ? AND doc >= 2",
                                [String(first), next, term.word.count - 2, term.word.count + 3]) { row in
                let candidate = NotesDatabase.text(row, 0)
                let documents = Int(sqlite3_column_int(row, 1))
                // Compare by sound: "Kirkoff" is closer to "Kirchhoff" than to "kickoff".
                let distance = editDistance(sound, sounds(candidate))
                guard distance <= limit else { return }
                if best == nil || distance < best!.distance || (distance == best!.distance && documents > best!.documents) {
                    best = (distance, documents, candidate)
                }
            }
            if let best {
                terms[index] = Term(word: best.word, stem: best.word)
                notes.append("(\"\(term.word)\" non c'è negli appunti: ho cercato \"\(best.word)\".)")
            }
        }
    }

    /// The word as it sounds: no "h" and no double letters, hard "ch" and "c" as "k", "j" as "i".
    private static func sounds(_ word: String) -> String {
        var text = word.replacingOccurrences(of: "ch", with: "k").replacingOccurrences(of: "ck", with: "k").replacingOccurrences(of: "ph", with: "f")
            .replacingOccurrences(of: "h", with: "").replacingOccurrences(of: "j", with: "i").replacingOccurrences(of: "y", with: "i").replacingOccurrences(of: "w", with: "v")
        var result = ""
        for letter in text where result.last != letter { result.append(letter) }
        text = result
        return text
    }

    private static func documents(_ term: Term, in db: OpaquePointer) -> Int {
        var count = 0
        NotesDatabase.query(db, "SELECT count(*) FROM (SELECT 1 FROM passages WHERE passages MATCH ? LIMIT 2000)", [term.match]) { count = Int(sqlite3_column_int($0, 0)) }
        return count
    }

    private static func exists(_ match: String, in db: OpaquePointer) -> Bool {
        var found = false
        NotesDatabase.query(db, "SELECT 1 FROM passages WHERE passages MATCH ? LIMIT 1", [match]) { _ in found = true }
        return found
    }

    private static func joinedTerms(_ terms: [Term], in db: OpaquePointer) -> [Term] {
        var result: [Term] = []
        var index = 0
        while index < terms.count {
            if index + 1 < terms.count {
                let whole = terms[index].word + terms[index + 1].word
                if exists("\"\(whole)\"", in: db) {
                    result.append(Term(word: whole, stem: whole))
                    index += 2
                    continue
                }
            }
            result.append(terms[index])
            index += 1
        }
        return result
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var row = Array(0...b.count)
        for i in 0..<a.count {
            var previous = row[0]
            row[0] = i + 1
            for j in 0..<b.count {
                let current = row[j + 1]
                row[j + 1] = a[i] == b[j] ? previous : min(previous, row[j], current) + 1
                previous = current
            }
        }
        return row[b.count]
    }

    /// A piece of page around the first searched word.
    private static func excerpt(_ text: String, around terms: [Term]) -> String {
        let lowered = folded(text)
        let position = terms.compactMap { lowered.range(of: $0.stem).map { lowered.distance(from: lowered.startIndex, to: $0.lowerBound) } }.min() ?? 0
        let characters = Array(text)
        let start = max(0, min(position, characters.count) - 300)
        let end = min(characters.count, start + 800)
        return (start > 0 ? "… " : "") + String(characters[start..<end]) + (end < characters.count ? " …" : "")
    }

    /// A passage found by meaning has no word to cut around: it is shown from the start, longer.
    private static func meaningExcerpt(_ text: String) -> String {
        text.count > 1600 ? String(text.prefix(1600)) + " …" : text
    }

    private static func status(_ db: OpaquePointer) -> String {
        var files = 0, waiting = 0
        NotesDatabase.query(db, "SELECT count(*) FROM files") { files = Int(sqlite3_column_int($0, 0)) }
        NotesDatabase.query(db, "SELECT count(*) FROM ocr_queue") { waiting = Int(sqlite3_column_int($0, 0)) }
        return waiting > 0 ? "(Indice: \(files) file; \(waiting) pagine scansionate ancora da leggere.)" : "(Indice: \(files) file.)"
    }
}

// MARK: Search by meaning

/// Every passage has a vector of 1024 numbers summing up its meaning, computed on the Mac by bge-m3 via
/// Ollama. It finds "shortest path in a graph" even where only Dijkstra is written. If Ollama or the model
/// are missing, search works by words only, as before.
enum NotesVectors {
    static let model = "bge-m3"
    static let dimensions = 1024
    // Values tuned on 30 questions phrased differently and checked on another 30 never used for tuning.
    /// The lower it is, the more the top places of each list weigh.
    static let rankOffset = 15.0
    /// When the exact term is already clear the model is not even called: here the words are
    /// almost always questions phrased in one's own way, and meaning matters more.
    static let wordsWeight = 0.5
    static let partialWeight = 0.25
    /// Below this similarity the passage is about something else: "today's horoscope" must find nothing.
    static let minimumSimilarity = 0.55
    private static let candidates = 30

    /// The text the vector comes from: the title gives the subject, beyond 1600 characters the meaning is already clear.
    static func input(title: String, text: String) -> String {
        String((title + "\n" + text).prefix(1600))
    }

    /// Numbers go from floats to one-byte integers: 1 KB per passage instead of 4, and it is enough to find neighbours.
    static func compressed(_ vector: [Double]) -> Data {
        let length = max(vector.reduce(0) { $0 + $1 * $1 }.squareRoot(), 1e-9)
        return Data(vector.map { UInt8(bitPattern: Int8(max(-127, min(127, ($0 / length * 127).rounded())))) })
    }

    /// Asks Ollama for the vectors. `keepAlive` says how long the model stays in memory afterwards.
    static func embed(_ texts: [String], keepAlive: String, timeout: TimeInterval) -> [[Double]]? {
        let base = JarvisConfig.load().ollamaURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/api/embed") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["model": model, "input": texts, "keep_alive": keepAlive, "truncate": true]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let finished = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: [[Double]]?
        URLSession.shared.dataTask(with: request) { data, _, _ in
            defer { finished.signal() }
            guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let vectors = json["embeddings"] as? [[Double]], vectors.count == texts.count else { return }
            result = vectors
        }.resume()
        finished.wait()
        return result
    }

    /// The passages closest to the question, nearest first. Nil if search by meaning is not possible.
    static func similar(to query: String, subject: String?, in db: OpaquePointer) -> [Int64]? {
        var count = 0
        NotesDatabase.query(db, "SELECT count(*) FROM sqlite_master WHERE name = 'vectors'") { count = Int(sqlite3_column_int($0, 0)) }
        guard count == 1 else { return nil }
        // The model stays loaded five minutes: follow-up questions often come right after.
        // The first load takes about 8 seconds.
        guard let vector = embed([query], keepAlive: "5m", timeout: 20)?.first, vector.count == dimensions else { return nil }
        let target = [Int8](compressed(vector).map { Int8(bitPattern: $0) })

        var sql = "SELECT id, v FROM vectors"
        var values: [Any] = []
        if let subject, !subject.isEmpty {
            sql = "SELECT v.id, v.v FROM vectors v JOIN passages p ON p.rowid = v.id WHERE p.path LIKE ?"
            values = ["%\(subject)%"]
        }
        // Scans the vectors without keeping them in memory: only the best are kept.
        var best: [(id: Int64, score: Int32)] = []
        var worst = Int32.min
        let threshold = Int32(minimumSimilarity * 127 * 127)
        NotesDatabase.query(db, sql, values) { row in
            guard sqlite3_column_bytes(row, 1) == Int32(dimensions), let blob = sqlite3_column_blob(row, 1) else { return }
            let other = blob.assumingMemoryBound(to: Int8.self)
            var score: Int32 = 0
            for i in 0..<dimensions { score &+= Int32(target[i]) &* Int32(other[i]) }
            guard score >= threshold, score > worst || best.count < candidates else { return }
            best.append((sqlite3_column_int64(row, 0), score))
            if best.count >= candidates * 2 {
                best.sort { $0.score > $1.score }
                best.removeLast(best.count - candidates)
                worst = best.last?.score ?? Int32.min
            }
        }
        best.sort { $0.score > $1.score }
        return best.prefix(candidates).map(\.id)
    }
}

// MARK: Process that builds the index

/// Started by JARVIS with `--index-notes folder…`. Exits with 75 if it used too much RAM: JARVIS restarts it
/// and it resumes where it stopped.
enum NotesIndexer {
    private static let memoryLimit = 1_200_000_000
    private static let needsRestart: Int32 = 75
    /// Scanned pages remain but cannot be read now: JARVIS tries again later.
    private static let tryLater: Int32 = 76

    static func run(folders: [String]) -> Never {
        // If JARVIS quits, this quits too.
        let parent = getppid()
        Thread.detachNewThread {
            while getppid() == parent { sleep(5) }
            exit(0)
        }
        guard let db = NotesDatabase.open(readOnly: false) else { exit(1) }
        NotesDatabase.run(db, """
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS files(path TEXT PRIMARY KEY, mtime REAL, size INTEGER);
            CREATE TABLE IF NOT EXISTS ocr_queue(path TEXT, page INTEGER, PRIMARY KEY(path, page));
            CREATE VIRTUAL TABLE IF NOT EXISTS passages USING fts5(title, text, path UNINDEXED, page UNINDEXED, tokenize="unicode61 remove_diacritics 2");
            CREATE TABLE IF NOT EXISTS vectors(id INTEGER PRIMARY KEY, v BLOB);
            """)
        let found = scan(folders)
        removeMissing(db, keeping: Set(found.map(\.path)))
        for file in found where isNew(db, file) {
            autoreleasepool { index(db, file) }
            if residentMemory() > memoryLimit { exit(needsRestart) }
        }
        readScannedPages(db)
        NotesDatabase.run(db, "DELETE FROM vectors WHERE id NOT IN (SELECT rowid FROM passages)")
        computeVectors(db)
        sqlite3_close(db)
        exit(0)
    }

    private struct File {
        let path: String
        let mtime: Double
        let size: Int
    }

    /// The same file in two folders (same name, same size) is indexed only once.
    private static func scan(_ folders: [String]) -> [File] {
        var files: [File] = []
        var seen = Set<String>()
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        for folder in folders {
            let root = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath)
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in walker where ["pdf", "docx", "pptx", "txt", "md"].contains(url.pathExtension.lowercased()) {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
                let size = values.fileSize ?? 0
                guard seen.insert("\(url.lastPathComponent.lowercased())|\(size)").inserted else { continue }
                files.append(File(path: url.path, mtime: values.contentModificationDate?.timeIntervalSince1970 ?? 0, size: size))
            }
        }
        return files
    }

    private static func isNew(_ db: OpaquePointer, _ file: File) -> Bool {
        var known = false
        NotesDatabase.query(db, "SELECT 1 FROM files WHERE path = ? AND mtime = ? AND size = ?", [file.path, file.mtime, file.size]) { _ in known = true }
        return !known
    }

    /// Removes from the index what no longer exists. Touches only the index, never the files.
    private static func removeMissing(_ db: OpaquePointer, keeping paths: Set<String>) {
        var gone: [String] = []
        NotesDatabase.query(db, "SELECT path FROM files") { row in
            let path = NotesDatabase.text(row, 0)
            if !paths.contains(path) { gone.append(path) }
        }
        for path in gone { forget(db, path) }
    }

    private static func forget(_ db: OpaquePointer, _ path: String) {
        NotesDatabase.query(db, "DELETE FROM vectors WHERE id IN (SELECT rowid FROM passages WHERE path = ?)", [path])
        NotesDatabase.query(db, "DELETE FROM passages WHERE path = ?", [path])
        NotesDatabase.query(db, "DELETE FROM ocr_queue WHERE path = ?", [path])
        NotesDatabase.query(db, "DELETE FROM files WHERE path = ?", [path])
    }

    private static func index(_ db: OpaquePointer, _ file: File) {
        NotesDatabase.run(db, "BEGIN")
        forget(db, file.path)
        let title = (((file.path as NSString).deletingLastPathComponent as NSString).lastPathComponent + " " + ((file.path as NSString).lastPathComponent as NSString).deletingPathExtension)
        let pages = extract(file.path) { page, text in
            add(db, title: title, text: text, path: file.path, page: page)
        } scanned: { page in
            NotesDatabase.query(db, "INSERT OR IGNORE INTO ocr_queue(path, page) VALUES(?, ?)", [file.path, page])
        }
        // A file that does not open is not retried on every round, until it changes.
        _ = pages
        NotesDatabase.query(db, "INSERT OR REPLACE INTO files(path, mtime, size) VALUES(?, ?, ?)", [file.path, file.mtime, file.size])
        NotesDatabase.run(db, "COMMIT")
    }

    private static func add(_ db: OpaquePointer, title: String, text: String, path: String, page: Int) {
        let clean = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !clean.isEmpty else { return }
        NotesDatabase.query(db, "INSERT INTO passages(title, text, path, page) VALUES(?, ?, ?, ?)", [title, clean, path, page])
    }

    // MARK: Extracting text

    private static func extract(_ path: String, text: (Int, String) -> Void, scanned: (Int) -> Void) -> Int {
        let url = URL(fileURLWithPath: path)
        switch url.pathExtension.lowercased() {
        case "pdf":
            guard let document = PDFDocument(url: url), !document.isLocked else { return 0 }
            for index in 0..<document.pageCount {
                autoreleasepool {
                    let content = document.page(at: index)?.string ?? ""
                    if content.trimmingCharacters(in: .whitespacesAndNewlines).count < 30 {
                        scanned(index + 1)
                    } else {
                        text(index + 1, content)
                    }
                }
            }
            return document.pageCount
        case "docx":
            guard let document = try? NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil) else { return 0 }
            return chunks(document.string, text: text)
        case "pptx":
            return slides(path, text: text)
        default:
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
            return chunks(content, text: text)
        }
    }

    /// Documents without pages: chunks of 3000 characters, numbered as if they were pages.
    private static func chunks(_ content: String, text: (Int, String) -> Void) -> Int {
        var number = 0
        var rest = Substring(content)
        while !rest.isEmpty {
            number += 1
            text(number, String(rest.prefix(3000)))
            rest = rest.dropFirst(3000)
        }
        return number
    }

    /// A presentation is a zip archive: in each slide the text is inside `<a:t>` tags.
    private static func slides(_ path: String, text: (Int, String) -> Void) -> Int {
        let names = output("/usr/bin/unzip", ["-Z1", path]).split(separator: "\n").map(String.init)
            .filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
        var count = 0
        for name in names {
            guard let number = Int(name.dropFirst("ppt/slides/slide".count).dropLast(4)) else { continue }
            let xml = output("/usr/bin/unzip", ["-p", path, name])
            let pieces = xml.components(separatedBy: "<a:t>").dropFirst().compactMap { $0.components(separatedBy: "</a:t>").first }
            let content = pieces.joined(separator: " ")
                .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            if !content.isEmpty {
                text(number, content)
                count += 1
            }
        }
        return count
    }

    private static func output(_ tool: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Scanned pages

    /// Pages without text are read with Vision, one at a time: only on mains power and
    /// with the Mac cool. If not possible, they resume on the next round.
    /// Computes missing vectors in small groups, with the same rules as scanned pages: mains
    /// power and Mac cool. Without Ollama or the model it retries on the next round.
    private static func computeVectors(_ db: OpaquePointer) {
        while true {
            var rows: [(id: Int64, title: String, text: String)] = []
            NotesDatabase.query(db, "SELECT p.rowid, p.title, p.text FROM passages p LEFT JOIN vectors v ON v.id = p.rowid WHERE v.id IS NULL LIMIT 16") { row in
                rows.append((sqlite3_column_int64(row, 0), NotesDatabase.text(row, 1), NotesDatabase.text(row, 2)))
            }
            guard !rows.isEmpty else { return }
            guard !onBattery() else { exit(tryLater) }
            while ProcessInfo.processInfo.thermalState != .nominal { sleep(60) }
            let done: Bool = autoreleasepool {
                guard let vectors = NotesVectors.embed(rows.map { NotesVectors.input(title: $0.title, text: $0.text) }, keepAlive: "30s", timeout: 120) else { return false }
                NotesDatabase.run(db, "BEGIN")
                for (row, vector) in zip(rows, vectors) {
                    NotesDatabase.query(db, "INSERT OR REPLACE INTO vectors(id, v) VALUES (?, ?)", [row.id, NotesVectors.compressed(vector)])
                }
                NotesDatabase.run(db, "COMMIT")
                return true
            }
            guard done else { return }
            if residentMemory() > memoryLimit { exit(needsRestart) }
        }
    }

    private static func readScannedPages(_ db: OpaquePointer) {
        while true {
            var next: (path: String, page: Int)?
            NotesDatabase.query(db, "SELECT path, page FROM ocr_queue ORDER BY path, page LIMIT 1") { row in
                next = (NotesDatabase.text(row, 0), Int(sqlite3_column_int(row, 1)))
            }
            guard let next else { return }
            guard !onBattery() else { exit(tryLater) }
            while ProcessInfo.processInfo.thermalState != .nominal { sleep(60) }
            autoreleasepool {
                let title = ((next.path as NSString).deletingLastPathComponent as NSString).lastPathComponent + " "
                    + ((next.path as NSString).lastPathComponent as NSString).deletingPathExtension
                NotesDatabase.run(db, "BEGIN")
                if let content = recognize(path: next.path, page: next.page) {
                    add(db, title: title, text: content, path: next.path, page: next.page)
                }
                NotesDatabase.query(db, "DELETE FROM ocr_queue WHERE path = ? AND page = ?", [next.path, next.page])
                NotesDatabase.run(db, "COMMIT")
            }
            if residentMemory() > memoryLimit { exit(needsRestart) }
            usleep(150_000)
        }
    }

    /// Reopening the same PDF for every page is costly and fills the RAM.
    nonisolated(unsafe) private static var openDocument: (path: String, document: PDFDocument)?

    private static func recognize(path: String, page number: Int) -> String? {
        if openDocument?.path != path {
            openDocument = PDFDocument(url: URL(fileURLWithPath: path)).map { (path, $0) }
        }
        guard let page = openDocument?.document.page(at: number - 1) else { return nil }
        let bounds = page.bounds(for: .cropBox)
        let turned = page.rotation % 180 != 0
        let size = turned ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(2.5, 2000 / max(size.width, size.height))
        guard let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: context)
        guard let image = context.makeImage() else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["it-IT", "en-US"]
        request.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: image).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.isEmpty ? nil : lines.joined(separator: " ")
    }

    private static func onBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return false }
        return (IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?) == kIOPMBatteryPowerKey
    }

    private static func residentMemory() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int(info.resident_size) : 0
    }
}

// MARK: Inside JARVIS

/// Starts the index process shortly after launch and then every 6 hours, for new or changed files.
@MainActor
final class NotesIndexRunner {
    private var process: Process?
    private var folders: () -> [String]

    init(folders: @escaping () -> [String]) {
        self.folders = folders
    }

    func start(after seconds: Double = 60) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            self?.launch()
        }
    }

    private func launch() {
        guard process == nil, let path = Bundle.main.executablePath else { return }
        let list = folders().filter { !$0.isEmpty }
        guard !list.isEmpty else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--index-notes"] + list
        process.qualityOfService = .background
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { @MainActor in
                self?.process = nil
                Diagnostics.log("appunti  indice uscito con \(status)")
                self?.start(after: status == 75 ? 2 : status == 76 ? 1800 : 6 * 3600)
            }
        }
        do {
            try process.run()
            self.process = process
            Diagnostics.log("appunti  indice avviato")
        } catch {
            Diagnostics.log("appunti  indice non avviato: \(error.localizedDescription)")
        }
    }
}
