import Foundation

struct PingInfo {
    let reachable: Bool
    let ip: String?
    let latencyMs: Double?
    let ttl: Int?
}

struct TagMatch {
    let tag: String
    let snippet: String
}

struct SiteResult: Identifiable, Hashable {
    let id = UUID()
    let domain: String
    let httpStatusCode: Int
    let redirectsToHTTPS: Bool
    let httpsAvailable: Bool
    let responseTime: TimeInterval
    let timestamp: Date
    let pingable: Bool
    let pingIP: String?
    let pingLatencyMs: Double?
    let pingTTL: Int?
    let matchedTag: String?
    let matchedSnippet: String?

    var isHTTPOnly: Bool {
        !redirectsToHTTPS && !httpsAvailable
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: SiteResult, rhs: SiteResult) -> Bool { lhs.id == rhs.id }
}

extension URLSession {
    func asyncData(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = self.dataTask(with: request) { data, response, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let data = data, let response = response {
                    continuation.resume(returning: (data, response))
                } else {
                    continuation.resume(throwing: URLError(.unknown))
                }
            }
            task.resume()
        }
    }

    func asyncData(from url: URL) async throws -> (Data, URLResponse) {
        try await asyncData(for: URLRequest(url: url))
    }
}

final class HTTPScanner: @unchecked Sendable {
    private let httpSession: URLSession
    private let httpsSession: URLSession
    private var torHttpSession: URLSession?
    private var torHttpsSession: URLSession?
    private let noRedirectDelegate = NoRedirectDelegate()
    var useTor: Bool = false
    private(set) var torPort: Int = 0

    static let wordList: [String] = [
        "ace", "air", "app", "art", "bay", "bee", "big", "bit", "box", "bug",
        "bus", "buy", "car", "cat", "cup", "day", "dog", "dot", "dry", "duo",
        "ear", "eat", "egg", "end", "era", "eye", "fan", "fig", "fin", "fit",
        "fly", "fog", "fox", "fun", "gap", "gas", "gem", "gin", "god", "gym",
        "hat", "hen", "hip", "hit", "hop", "hot", "hub", "ice", "ink", "ivy",
        "jam", "jar", "jet", "job", "joy", "key", "kid", "kit", "lab", "law",
        "leg", "lip", "log", "map", "max", "mix", "mod", "net", "new", "nut",
        "oak", "oil", "old", "one", "orb", "ore", "out", "owl", "pad", "pal",
        "pan", "pay", "pen", "pet", "pie", "pin", "pit", "pod", "pop", "pot",
        "pro", "pub", "ram", "rap", "rat", "raw", "ray", "red", "rig", "rim",
        "rod", "row", "rug", "rum", "run", "rye", "sea", "set", "ski", "sky",
        "spa", "spy", "sub", "sum", "sun", "tab", "tag", "tan", "tap", "tax",
        "tea", "ten", "tie", "tin", "tip", "toe", "ton", "top", "toy", "try",
        "tub", "two", "van", "vet", "vim", "war", "wax", "way", "web", "wet",
        "win", "wit", "wow", "yak", "zen", "zip", "zoo",
        "ball", "band", "bank", "base", "best", "bike", "blog", "blue", "boat",
        "bold", "bond", "book", "boss", "buzz", "cafe", "cake", "call", "calm",
        "camp", "card", "care", "case", "cash", "chat", "chip", "city", "clip",
        "club", "code", "coin", "cool", "copy", "core", "cost", "cube", "cure",
        "dark", "data", "date", "dawn", "deal", "demo", "desk", "dock", "dome",
        "door", "down", "drop", "drum", "duck", "dust", "earn", "ease", "east",
        "easy", "echo", "edge", "edit", "face", "fact", "fair", "fame", "farm",
        "fast", "fate", "fear", "feed", "file", "film", "find", "fine", "fire",
        "firm", "fish", "flag", "flat", "flex", "flip", "flow", "fold", "folk",
        "food", "form", "fort", "free", "fuel", "full", "fund", "fuse", "gain",
        "game", "gate", "gear", "gene", "gift", "glad", "glow", "glue", "goat",
        "gold", "golf", "good", "grab", "grid", "grip", "grow", "gulf", "guru",
        "hack", "hair", "half", "hall", "hand", "hard", "haze", "head", "heal",
        "heat", "help", "hero", "hide", "high", "hike", "hill", "hint", "hire",
        "hold", "hole", "home", "hook", "hope", "host", "huge", "hunt", "hype",
        "icon", "idea", "info", "iron", "isle", "item", "jade", "jazz", "jobs",
        "join", "joke", "jump", "keen", "keep", "kick", "kind", "king", "kite",
        "know", "lack", "lake", "lamp", "land", "lane", "last", "late", "lawn",
        "lead", "leaf", "lean", "left", "lens", "life", "lift", "like", "lime",
        "line", "link", "lion", "list", "live", "load", "loan", "lock", "logo",
        "long", "look", "loop", "love", "luck", "lure", "mail", "main", "make",
        "mark", "mask", "maze", "meal", "menu", "mesh", "mile", "milk", "mind",
        "mine", "mint", "mist", "mode", "mood", "moon", "more", "moss", "move",
        "muse", "myth", "nail", "name", "navy", "neat", "neck", "need", "nest",
        "news", "next", "nice", "nine", "node", "noon", "nose", "note", "nova",
        "open", "pack", "page", "park", "path", "peak", "pick", "pine", "pipe",
        "plan", "play", "plot", "plug", "poem", "pole", "pool", "port", "post",
        "pull", "pump", "pure", "push", "race", "rack", "rage", "rail", "rain",
        "rank", "rare", "rate", "read", "real", "reef", "rent", "rest", "rich",
        "ride", "ring", "rise", "risk", "road", "rock", "role", "roll", "roof",
        "room", "root", "rope", "rose", "rule", "rush", "safe", "sail", "sale",
        "salt", "sand", "save", "scan", "seal", "seat", "seed", "seek", "self",
        "sell", "send", "ship", "shop", "show", "side", "sign", "silk", "sing",
        "sink", "site", "size", "skin", "skip", "slim", "slip", "slot", "slow",
        "snap", "snow", "soap", "soft", "soil", "sole", "song", "sort", "soul",
        "spin", "spot", "star", "stay", "stem", "step", "stop", "surf", "swap",
        "sync", "tail", "tale", "talk", "tank", "tape", "task", "team", "tech",
        "term", "test", "text", "tide", "tile", "time", "tiny", "tire", "tone",
        "tool", "tour", "town", "trap", "tree", "trim", "trip", "true", "tube",
        "tune", "turn", "type", "unit", "user", "vast", "vice", "view", "vine",
        "void", "volt", "vote", "wage", "wait", "wake", "walk", "wall", "want",
        "warm", "warn", "wash", "wave", "weak", "wear", "week", "well", "west",
        "wide", "wiki", "wild", "will", "wind", "wine", "wing", "wire", "wise",
        "wish", "wolf", "wood", "word", "work", "yard", "year", "yoga", "zero",
        "zone", "zoom"
    ]

    static func searchEverywhere(domain: String, html: String, headers: [String: String], keywords: [String]) -> TagMatch? {
        let lowerKws = keywords.map { $0.lowercased() }

        let domainLower = domain.lowercased()
        if lowerKws.allSatisfy({ domainLower.contains($0) }) {
            return TagMatch(tag: "url", snippet: domain)
        }

        let headerText = headers.map { "\($0.key): \($0.value)" }.joined(separator: " ").lowercased()
        if !headerText.isEmpty, lowerKws.allSatisfy({ headerText.contains($0) }) {
            return TagMatch(tag: "header", snippet: cleanSnippet(headerText, around: lowerKws[0]))
        }

        let stripped = html.lowercased()
            .replacingOccurrences(of: "<script[^>]*>[\\s\\S]*?</script>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "<style[^>]*>[\\s\\S]*?</style>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)

        if lowerKws.allSatisfy({ stripped.contains($0) }) {
            return TagMatch(tag: "content", snippet: cleanSnippet(stripped, around: lowerKws[0]))
        }

        return nil
    }

    private static func extractTagContent(_ html: String, tag: String) -> String? {
        guard let openEnd = html.range(of: "<\(tag)")?.upperBound,
              let contentStart = html[openEnd...].range(of: ">")?.upperBound,
              let closeStart = html[contentStart...].range(of: "</\(tag)")?.lowerBound else { return nil }
        let content = String(html[contentStart..<closeStart])
        return content.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractMetaContent(_ html: String, name: String) -> String? {
        let patterns = [
            "<meta[^>]*name=\"\(name)\"[^>]*content=\"([^\"]*)\"",
            "<meta[^>]*content=\"([^\"]*)\"[^>]*name=\"\(name)\""
        ]
        return matchMetaPatterns(html, patterns: patterns)
    }

    private static func extractMetaContent(_ html: String, property: String) -> String? {
        let patterns = [
            "<meta[^>]*property=\"\(property)\"[^>]*content=\"([^\"]*)\"",
            "<meta[^>]*content=\"([^\"]*)\"[^>]*property=\"\(property)\""
        ]
        return matchMetaPatterns(html, patterns: patterns)
    }

    private static func matchMetaPatterns(_ html: String, patterns: [String]) -> String? {
        for pattern in patterns {
            if let range = html.range(of: pattern, options: .regularExpression) {
                let match = String(html[range])
                if let cStart = match.range(of: "content=\"")?.upperBound,
                   let cEnd = match[cStart...].firstIndex(of: "\"") {
                    return String(match[cStart..<cEnd])
                }
            }
        }
        return nil
    }

    private static func cleanSnippet(_ text: String, around keyword: String) -> String {
        let collapsed = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let kwRange = collapsed.range(of: keyword, options: .caseInsensitive) else {
            return String(collapsed.prefix(80))
        }
        let center = collapsed.distance(from: collapsed.startIndex, to: kwRange.lowerBound)
        let snippetStart = max(0, center - 30)
        let startIdx = collapsed.index(collapsed.startIndex, offsetBy: snippetStart)
        let endIdx = collapsed.index(startIdx, offsetBy: min(80, collapsed.distance(from: startIdx, to: collapsed.endIndex)))
        var snippet = String(collapsed[startIdx..<endIdx])
        if snippetStart > 0 { snippet = "..." + snippet }
        if endIdx < collapsed.endIndex { snippet += "..." }
        return snippet
    }

    init() {
        let httpCfg = URLSessionConfiguration.ephemeral
        httpCfg.timeoutIntervalForRequest = 3
        httpCfg.timeoutIntervalForResource = 5
        httpCfg.waitsForConnectivity = false
        self.httpSession = URLSession(configuration: httpCfg, delegate: noRedirectDelegate, delegateQueue: nil)

        let httpsCfg = URLSessionConfiguration.ephemeral
        httpsCfg.timeoutIntervalForRequest = 3
        httpsCfg.timeoutIntervalForResource = 5
        httpsCfg.waitsForConnectivity = false
        self.httpsSession = URLSession(configuration: httpsCfg)

    }

    private func buildTorSessions(port: Int) {
        let torProxy: [AnyHashable: Any] = [
            kCFNetworkProxiesSOCKSEnable as String: true,
            kCFNetworkProxiesSOCKSProxy as String: "127.0.0.1",
            kCFNetworkProxiesSOCKSPort as String: port,
        ]

        let torHttpCfg = URLSessionConfiguration.ephemeral
        torHttpCfg.timeoutIntervalForRequest = 20
        torHttpCfg.timeoutIntervalForResource = 40
        torHttpCfg.waitsForConnectivity = false
        torHttpCfg.connectionProxyDictionary = torProxy
        torHttpCfg.httpMaximumConnectionsPerHost = 2
        self.torHttpSession = URLSession(configuration: torHttpCfg, delegate: noRedirectDelegate, delegateQueue: nil)

        let torHttpsCfg = URLSessionConfiguration.ephemeral
        torHttpsCfg.timeoutIntervalForRequest = 20
        torHttpsCfg.timeoutIntervalForResource = 40
        torHttpsCfg.waitsForConnectivity = false
        torHttpsCfg.connectionProxyDictionary = torProxy
        torHttpsCfg.httpMaximumConnectionsPerHost = 2
        self.torHttpsSession = URLSession(configuration: torHttpsCfg)

        self.torPort = port
    }

    private var activeHttpSession: URLSession { useTor ? (torHttpSession ?? httpSession) : httpSession }
    private var activeHttpsSession: URLSession { useTor ? (torHttpsSession ?? httpsSession) : httpsSession }

    func checkTorConnection() async -> (Bool, Int) {
        for port in [9050, 9150] {
            buildTorSessions(port: port)
            guard let url = URL(string: "http://check.torproject.org") else { continue }
            do {
                let (data, _) = try await torHttpSession!.asyncData(from: url)
                let body = String(data: data, encoding: .utf8) ?? ""
                if body.contains("Congratulations") || body.contains("configured to use Tor") {
                    return (true, port)
                }
            } catch {
                continue
            }
        }
        torHttpSession = nil
        torHttpsSession = nil
        torPort = 0
        return (false, 0)
    }

    static let searchPrefixes = [
        "my", "the", "go", "get", "best", "top", "pro", "all", "new", "try",
        "free", "cool", "real", "web", "i", "e", "a", "big", "hot", "use"
    ]

    static let searchSuffixes = [
        "hub", "app", "dev", "web", "hq", "now", "box", "zone", "spot", "base",
        "site", "net", "pro", "lab", "world", "city", "bay", "go", "ly", "ify"
    ]

    func searchDomains(keywords: [String], tlds: [String]) -> [String] {
        guard !tlds.isEmpty, !keywords.isEmpty else { return [] }

        var domains: [String] = []
        var seen = Set<String>()

        for keyword in keywords {
            let sanitized = keyword.lowercased()
                .filter { $0.isLetter || $0.isNumber || $0 == "-" }
            guard !sanitized.isEmpty else { continue }

            for tld in tlds {
                let exact = "\(sanitized).\(tld)"
                if seen.insert(exact).inserted { domains.append(exact) }

                for prefix in Self.searchPrefixes {
                    let d = "\(prefix)\(sanitized).\(tld)"
                    if seen.insert(d).inserted { domains.append(d) }
                }

                for suffix in Self.searchSuffixes {
                    let d = "\(sanitized)\(suffix).\(tld)"
                    if seen.insert(d).inserted { domains.append(d) }
                }
            }
        }

        return domains
    }

    func generateRandomDomains(tlds: [String], count: Int) -> [String] {
        guard !tlds.isEmpty else { return [] }
        var domains: [String] = []
        var seen = Set<String>()
        let maxAttempts = count * 3
        var attempts = 0
        while domains.count < count && attempts < maxAttempts {
            attempts += 1
            let word = Self.wordList.randomElement()!
            let tld = tlds.randomElement()!
            let domain = "\(word).\(tld)"
            if seen.insert(domain).inserted {
                domains.append(domain)
            }
        }
        return domains
    }

    func checkDomain(_ domain: String, searchKeywords: [String]? = nil) async -> SiteResult? {
        guard let httpURL = URL(string: "http://\(domain)") else { return nil }

        let isOnion = domain.hasSuffix(".onion")
        let start = Date()
        let httpResponse: HTTPURLResponse
        let httpData: Data
        do {
            let request = URLRequest(url: httpURL)
            let (data, response) = try await activeHttpSession.asyncData(for: request)
            guard let resp = response as? HTTPURLResponse else { return nil }
            httpResponse = resp
            httpData = data
        } catch {
            return nil
        }
        let httpTime = Date().timeIntervalSince(start)

        var tagMatch: TagMatch?
        if let keywords = searchKeywords, !keywords.isEmpty {
            let html = String(data: httpData, encoding: .utf8) ?? String(data: httpData, encoding: .ascii) ?? ""
            var headers: [String: String] = [:]
            for (key, value) in httpResponse.allHeaderFields {
                headers["\(key)"] = "\(value)"
            }
            tagMatch = Self.searchEverywhere(domain: domain, html: html, headers: headers, keywords: keywords)
            if tagMatch == nil { return nil }
        }

        let redirectsToHTTPS: Bool
        if let location = httpResponse.value(forHTTPHeaderField: "Location") {
            redirectsToHTTPS = location.lowercased().hasPrefix("https://")
        } else {
            redirectsToHTTPS = false
        }

        async let httpsResult = checkHTTPS(domain: domain)
        async let pingResult: PingInfo = isOnion
            ? PingInfo(reachable: false, ip: nil, latencyMs: nil, ttl: nil)
            : pingDomain(domain)

        let httpsAvailable = await httpsResult
        let ping = await pingResult

        return SiteResult(
            domain: domain,
            httpStatusCode: httpResponse.statusCode,
            redirectsToHTTPS: redirectsToHTTPS,
            httpsAvailable: httpsAvailable,
            responseTime: httpTime,
            timestamp: Date(),
            pingable: ping.reachable,
            pingIP: ping.ip,
            pingLatencyMs: ping.latencyMs,
            pingTTL: ping.ttl,
            matchedTag: tagMatch?.tag,
            matchedSnippet: tagMatch?.snippet
        )
    }

    private func checkHTTPS(domain: String) async -> Bool {
        guard let url = URL(string: "https://\(domain)") else { return false }
        do {
            let (_, response) = try await activeHttpsSession.asyncData(from: url)
            if let http = response as? HTTPURLResponse {
                return http.statusCode < 400
            }
            return false
        } catch {
            return false
        }
    }

    func pingDomain(_ domain: String) async -> PingInfo {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/sbin/ping")
            process.arguments = ["-c", "1", "-W", "2000", domain]

            let outPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = Pipe()

            process.terminationHandler = { proc in
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""

                if proc.terminationStatus == 0 {
                    continuation.resume(returning: Self.parsePingOutput(output))
                } else {
                    let ip = Self.parseIP(from: output)
                    continuation.resume(returning: PingInfo(reachable: false, ip: ip, latencyMs: nil, ttl: nil))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(returning: PingInfo(reachable: false, ip: nil, latencyMs: nil, ttl: nil))
            }
        }
    }

    private static func parsePingOutput(_ output: String) -> PingInfo {
        let ip = parseIP(from: output)

        var latencyMs: Double?
        var ttl: Int?

        if let range = output.range(of: "ttl=(\\d+)", options: .regularExpression) {
            let str = String(output[range]).replacingOccurrences(of: "ttl=", with: "")
            ttl = Int(str)
        }

        if let range = output.range(of: "time=([\\d.]+)", options: .regularExpression) {
            let str = String(output[range]).replacingOccurrences(of: "time=", with: "")
            latencyMs = Double(str)
        }

        return PingInfo(reachable: true, ip: ip, latencyMs: latencyMs, ttl: ttl)
    }

    private static func parseIP(from output: String) -> String? {
        guard let openParen = output.firstIndex(of: "("),
              let closeParen = output[output.index(after: openParen)...].firstIndex(of: ")"),
              openParen < closeParen else { return nil }

        let candidate = String(output[output.index(after: openParen)..<closeParen])
        let parts = candidate.split(separator: ".")
        if parts.count == 4, parts.allSatisfy({ Int($0) != nil }) {
            return candidate
        }
        return nil
    }
}

final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
