import AppKit
import Foundation

/// Web search, page reading and weather: free services without API keys.
enum WebActions {
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    private static func get(_ url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("it-IT,it;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        let (data, _) = try await URLSession.shared.data(for: request)
        return String(decoding: data, as: UTF8.self)
    }

    static func search(_ args: [String: Any]) async -> String {
        guard let query = args.string("query"),
              let url = URL(string: "https://html.duckduckgo.com/html/?q=" + (query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""))
        else { return "Ricerca mancante" }
        do {
            let html = try await get(url)
            let titles = matches(#"class="result__a"[^>]*href="([^"]+)"[^>]*>([\s\S]*?)</a>"#, in: html)
            let snippets = matches(#"class="result__snippet"[^>]*>([\s\S]*?)</a>"#, in: html)
            guard !titles.isEmpty else { return "Nessun risultato per \(query)" }
            return titles.prefix(6).enumerated().map { i, t in
                let title = stripTags(t.count > 1 ? t[1] : "")
                let link = decodeDuckLink(t.first ?? "")
                let snippet = i < snippets.count ? stripTags(snippets[i].first ?? "") : ""
                return "\(i + 1). \(title) — \(snippet) [\(link)]"
            }.joined(separator: "\n")
        } catch {
            return "Ricerca non riuscita: \(error.localizedDescription)"
        }
    }

    static func readPage(_ args: [String: Any]) async -> String {
        guard let link = args.string("url"), let url = URL(string: link) else { return "URL mancante" }
        do {
            var html = try await get(url)
            html = html.replacingOccurrences(of: #"<(script|style|nav|footer|header|svg)[\s\S]*?</\1>"#, with: " ", options: .regularExpression)
            let text = stripTags(html).replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            return String(text.prefix(5000))
        } catch {
            return "Pagina non raggiungibile: \(error.localizedDescription)"
        }
    }

    @MainActor
    static func openURL(_ args: [String: Any]) -> String {
        guard var link = args.string("url") else { return "URL mancante" }
        if !link.contains("://") { link = "https://" + link }
        guard let url = URL(string: link) else { return "URL non valido" }
        NSWorkspace.shared.open(url)
        return "Aperto \(link)"
    }

    static func weather(_ args: [String: Any]) async -> String {
        let place = args.string("location") ?? ""
        let encoded = place.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        guard let url = URL(string: "https://wttr.in/\(encoded)?format=j1&lang=it") else { return "Località non valida" }
        do {
            let text = try await get(url)
            guard let json = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  let current = (json["current_condition"] as? [[String: Any]])?.first else { return "Meteo non disponibile" }
            let area = ((json["nearest_area"] as? [[String: Any]])?.first?["areaName"] as? [[String: Any]])?.first?["value"] as? String ?? place
            let desc = ((current["lang_it"] as? [[String: Any]])?.first?["value"] as? String)
                ?? ((current["weatherDesc"] as? [[String: Any]])?.first?["value"] as? String) ?? ""
            var out = "Meteo a \(area): \(desc), \(current["temp_C"] ?? "?")°C (percepiti \(current["FeelsLikeC"] ?? "?")°C), umidità \(current["humidity"] ?? "?")%, vento \(current["windspeedKmph"] ?? "?") km/h."
            if let days = json["weather"] as? [[String: Any]] {
                for (i, day) in days.prefix(3).enumerated() {
                    let rain = (day["hourly"] as? [[String: Any]])?.compactMap { Int($0["chanceofrain"] as? String ?? "") }.max() ?? 0
                    let label = ["Oggi", "Domani", "Dopodomani"][i]
                    out += "\n\(label): min \(day["mintempC"] ?? "?")°C, max \(day["maxtempC"] ?? "?")°C, probabilità di pioggia fino al \(rain)%."
                }
            }
            return out
        } catch {
            return "Meteo non disponibile: \(error.localizedDescription)"
        }
    }

    // MARK: Utilities

    private static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            (1..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
        }
    }

    private static func stripTags(_ html: String) -> String {
        var s = html.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        for (entity, char) in ["&amp;": "&", "&quot;": "\"", "&#x27;": "'", "&#39;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " "] {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        return s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    private static func decodeDuckLink(_ href: String) -> String {
        guard let components = URLComponents(string: href.hasPrefix("//") ? "https:" + href : href),
              let target = components.queryItems?.first(where: { $0.name == "uddg" })?.value else { return href }
        return target
    }
}
