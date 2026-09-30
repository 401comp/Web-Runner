import Foundation

private extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}

struct SearchResult: Identifiable, Hashable, Sendable {
    let id = UUID()
    let url: URL
    let title: String
    var source: String
    let httpStatusCode: Int?
    let redirectsToHTTPS: Bool
    let httpsAvailable: Bool?

    init(
        url: URL,
        title: String,
        source: String,
        httpStatusCode: Int? = nil,
        redirectsToHTTPS: Bool = false,
        httpsAvailable: Bool? = nil
    ) {
        self.url = url
        self.title = title
        self.source = source
        self.httpStatusCode = httpStatusCode
        self.redirectsToHTTPS = redirectsToHTTPS
        self.httpsAvailable = httpsAvailable
    }

    /// A plain HTTP link from an index is not proof that HTTPS is unavailable.
    var isHTTPOnly: Bool {
        httpStatusCode != nil && !redirectsToHTTPS && httpsAvailable == false
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
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

struct ImageResult: Identifiable, Hashable, Sendable {
    let id = UUID()
    let thumbnailURL: URL
    let imageURL: URL
    let pageURL: URL
    let title: String
}

private enum SearchCacheKind: Hashable {
    case surfaceWeb
    case verifiedHTTPOnly
    case surfaceImages
}

private struct SearchCacheKey: Hashable {
    let query: String
    let kind: SearchCacheKind
}

private struct CachedWebResults {
    let createdAt: Date
    let results: [SearchResult]
}

private struct CachedImageResults {
    let createdAt: Date
    let results: [ImageResult]
}

private final class SearchResultCache: @unchecked Sendable {
    private let lifetime: TimeInterval = 10 * 60
    private let lock = NSLock()
    private var webResults: [SearchCacheKey: CachedWebResults] = [:]
    private var imageResults: [SearchCacheKey: CachedImageResults] = [:]

    func cachedWebResults(for key: SearchCacheKey) -> [SearchResult]? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = webResults[key] else { return nil }
        guard Date().timeIntervalSince(entry.createdAt) < lifetime else {
            webResults[key] = nil
            return nil
        }
        return entry.results
    }

    func cachedImageResults(for key: SearchCacheKey) -> [ImageResult]? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = imageResults[key] else { return nil }
        guard Date().timeIntervalSince(entry.createdAt) < lifetime else {
            imageResults[key] = nil
            return nil
        }
        return entry.results
    }

    func store(webResults results: [SearchResult], for key: SearchCacheKey) {
        lock.lock()
        webResults[key] = CachedWebResults(createdAt: Date(), results: results)
        lock.unlock()
    }

    func store(imageResults results: [ImageResult], for key: SearchCacheKey) {
        lock.lock()
        imageResults[key] = CachedImageResults(createdAt: Date(), results: results)
        lock.unlock()
    }

    func clear() {
        lock.lock()
        webResults.removeAll()
        imageResults.removeAll()
        lock.unlock()
    }

    func summary() -> (entries: Int, results: Int) {
        lock.lock()
        defer { lock.unlock() }
        let cutoff = Date().addingTimeInterval(-lifetime)
        webResults = webResults.filter { $0.value.createdAt >= cutoff }
        imageResults = imageResults.filter { $0.value.createdAt >= cutoff }
        let resultCount = webResults.values.reduce(0) { $0 + $1.results.count }
            + imageResults.values.reduce(0) { $0 + $1.results.count }
        return (webResults.count + imageResults.count, resultCount)
    }
}

extension URLSession {
    func asyncData(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, let response {
                    continuation.resume(returning: (data, response))
                } else {
                    continuation.resume(throwing: URLError(.unknown))
                }
            }
            task.resume()
        }
    }
}

final class HTTPScanner: @unchecked Sendable {
    private static let bingWebSearchURL = "https://www.bing.com/search"
    private static let duckDuckGoWebSearchURL = "https://html.duckduckgo.com/html/"
    private static let braveWebSearchURL = "https://search.brave.com/search"
    private static let bingImageSearchURL = "https://www.bing.com/images/search"
    private static let linkPattern = try! NSRegularExpression(
        pattern: "(?i)<a\\b[^>]*href\\s*=\\s*[\\\"']([^\\\"']+)[\\\"']",
        options: []
    )
    private static let braveResultPatterns = [
        try! NSRegularExpression(
            pattern: "(?is)<a\\s+href=\\\"(https?://[^\\\"]+)\\\"[^>]*class=\\\"[^\\\"]*(?:l1|title)[^\\\"]*\\\"",
            options: []
        ),
        try! NSRegularExpression(
            pattern: "(?is)<a\\s+class=\\\"[^\\\"]*(?:l1|title)[^\\\"]*\\\"[^>]*href=\\\"(https?://[^\\\"]+)\\\"",
            options: []
        )
    ]
    private static let bingResultPattern = try! NSRegularExpression(
        pattern: "(?is)<li\\b[^>]*\\bclass\\s*=\\s*[\\\"'][^\\\"']*\\bb_algo\\b[^\\\"']*[\\\"'][^>]*>.*?<h2\\b[^>]*>\\s*<a\\b[^>]*href\\s*=\\s*[\\\"']([^\\\"']+)[\\\"']",
        options: []
    )
    private static let duckDuckGoResultPattern = try! NSRegularExpression(
        pattern: "(?is)<a\\b[^>]*\\bclass\\s*=\\s*[\\\"'][^\\\"']*\\bresult__a\\b[^\\\"']*[\\\"'][^>]*href\\s*=\\s*[\\\"']([^\\\"']+)[\\\"']|<a\\b[^>]*href\\s*=\\s*[\\\"']([^\\\"']+)[\\\"'][^>]*\\bclass\\s*=\\s*[\\\"'][^\\\"']*\\bresult__a\\b[^\\\"']*[\\\"']",
        options: []
    )
    private static let imageMetadataPattern = try! NSRegularExpression(
        pattern: "(?is)\\bm\\s*=\\s*[\\\"'](\\{.*?\\})[\\\"']",
        options: []
    )
    private static let maxSearchResults = 1500
    private static let webResultsPerPage = 10
    private static let imageResultsPerPage = 35
    private static let maxSurfaceResultsPerSource = maxSearchResults / 3
    private static let maxSurfaceIndexPages = (maxSurfaceResultsPerSource + webResultsPerPage - 1) / webResultsPerPage
    private static let maxSurfaceImagePages = (maxSearchResults + imageResultsPerPage - 1) / imageResultsPerPage
    private static let httpVerificationConcurrency = 24
    private static let httpVerificationTLDs = [
        "com", "net", "org", "info", "biz", "io", "xyz", "site", "us", "co",
        "fun", "online", "live", "tech", "dev", "app", "me", "tv", "cc", "in",
        "de", "uk", "ru", "cn", "jp", "fr", "au", "ca", "br", "nl",
        "eu", "ch", "se", "no", "fi", "dk", "pl", "cz", "at", "be",
        "club", "shop", "store", "blog", "page", "space", "top", "pro", "mobi",
        "name", "mx", "ar", "za", "kr", "tw", "sg", "hk", "nz", "il"
    ]
    private static let httpDiscoveryPrefixes = [
        "my", "the", "go", "get", "best", "top", "pro", "all", "new", "try",
        "free", "cool", "real", "web", "big", "hot", "use"
    ]
    private static let httpDiscoverySuffixes = [
        "hub", "app", "dev", "web", "hq", "now", "box", "zone", "spot", "base",
        "site", "net", "pro", "lab", "world", "city", "bay", "go", "ly", "ify"
    ]

    private let directSession: URLSession
    private let noRedirectDelegate = NoRedirectDelegate()
    private let noRedirectSession: URLSession
    private let searchCache = SearchResultCache()
    private var torSession: URLSession?
    private(set) var torPort = 0
    var useTor = false

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 25
        configuration.waitsForConnectivity = false
        directSession = URLSession(configuration: configuration)

        let verificationConfiguration = URLSessionConfiguration.ephemeral
        verificationConfiguration.timeoutIntervalForRequest = 3
        verificationConfiguration.timeoutIntervalForResource = 5
        verificationConfiguration.waitsForConnectivity = false
        noRedirectSession = URLSession(
            configuration: verificationConfiguration,
            delegate: noRedirectDelegate,
            delegateQueue: nil
        )
    }

    private var activeSession: URLSession { useTor ? (torSession ?? directSession) : directSession }

    private func buildTorSession(port: Int) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        configuration.connectionProxyDictionary = [
            kCFNetworkProxiesSOCKSEnable as String: true,
            kCFNetworkProxiesSOCKSProxy as String: "127.0.0.1",
            kCFNetworkProxiesSOCKSPort as String: port
        ]
        torSession = URLSession(configuration: configuration)
        torPort = port
    }

    func checkTorConnection() async -> (Bool, Int) {
        for port in [9050, 9150] {
            buildTorSession(port: port)
            guard let url = URL(string: "https://check.torproject.org") else { continue }
            do {
                let (data, _) = try await torSession!.asyncData(for: URLRequest(url: url))
                let body = String(data: data, encoding: .utf8) ?? ""
                if body.contains("Congratulations") || body.contains("configured to use Tor") {
                    return (true, port)
                }
            } catch {
                continue
            }
        }
        torSession = nil
        torPort = 0
        return (false, 0)
    }

    func searchSurfaceWeb(query: String) async throws -> [SearchResult] {
        let cacheKey = SearchCacheKey(query: normalizedQuery(query), kind: .surfaceWeb)
        if let cached = searchCache.cachedWebResults(for: cacheKey) { return cached }
        let sources: [(name: String, endpoint: String, queryItems: [URLQueryItem])] = [
            ("Bing", Self.bingWebSearchURL, [URLQueryItem(name: "q", value: query)]),
            ("Brave", Self.braveWebSearchURL, [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "offset", value: "0")
            ]),
            ("DuckDuckGo", Self.duckDuckGoWebSearchURL, [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "kp", value: "-2"),
                URLQueryItem(name: "s", value: "0")
            ])
        ]
        var results: [SearchResult] = []
        var resultIndexByURL: [String: Int] = [:]
        var lastError: Error?

        for source in sources where results.count < Self.maxSearchResults {
            do {
                let sourceResults = try await searchSurfacePages(
                    name: source.name,
                    endpoint: source.endpoint,
                    queryItems: source.queryItems,
                    limit: min(Self.maxSurfaceResultsPerSource, Self.maxSearchResults - results.count)
                )
                for result in sourceResults {
                    let key = result.url.absoluteString
                    if let index = resultIndexByURL[key] {
                        let existingSources = Set(results[index].source.components(separatedBy: ", "))
                        if !existingSources.contains(result.source) {
                            results[index].source += ", \(result.source)"
                        }
                    } else {
                        resultIndexByURL[key] = results.count
                        results.append(result)
                        if results.count == Self.maxSearchResults { break }
                    }
                }
            } catch {
                lastError = error
            }
        }

        if results.isEmpty, let lastError { throw lastError }
        searchCache.store(webResults: results, for: cacheKey)
        return results
    }

    /// Restores the original direct-probe behavior for HTTP-only discovery.
    /// Candidate generation is local; a search index is never used to decide
    /// whether a result belongs in this mode.
    func searchVerifiedHTTPOnly(query: String) async throws -> [SearchResult] {
        let cacheKey = SearchCacheKey(query: normalizedQuery(query), kind: .verifiedHTTPOnly)
        if let cached = searchCache.cachedWebResults(for: cacheKey) { return cached }

        let terms = normalizedQuery(query)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        let candidates = Self.httpDiscoveryCandidates(for: terms)
        guard !candidates.isEmpty else { return [] }

        let results = await withTaskGroup(of: SearchResult?.self, returning: [SearchResult].self) { group in
            var iterator = candidates.makeIterator()
            for _ in 0..<min(Self.httpVerificationConcurrency, candidates.count) {
                if let domain = iterator.next() {
                    group.addTask { [self] in await verifyHTTPOnly(domain: domain, terms: terms) }
                }
            }

            var verified: [SearchResult] = []
            for await result in group {
                if let result { verified.append(result) }
                if let domain = iterator.next() {
                    group.addTask { [self] in await verifyHTTPOnly(domain: domain, terms: terms) }
                }
            }
            return verified.sorted { $0.url.host ?? "" < $1.url.host ?? "" }
        }
        searchCache.store(webResults: results, for: cacheKey)
        return results
    }

    private func verifyHTTPOnly(domain: String, terms: [String]) async -> SearchResult? {
        guard let httpURL = URL(string: "http://\(domain)") else { return nil }
        var request = URLRequest(url: httpURL)
        request.setValue("Web-Runner/1.1", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await noRedirectSession.asyncData(for: request),
              let httpResponse = response as? HTTPURLResponse,
              (200..<400).contains(httpResponse.statusCode) else { return nil }

        let redirectsToHTTPS = httpResponse.value(forHTTPHeaderField: "Location")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasPrefix("https://") ?? false
        guard !redirectsToHTTPS else { return nil }

        let httpsAvailable = await isHTTPSAvailable(for: domain)
        guard !httpsAvailable else { return nil }

        let document = Self.htmlString(from: data)
        let html = document.lowercased()
        let matchesTerms = terms.allSatisfy {
            domain.localizedCaseInsensitiveContains($0) || html.contains($0)
        }
        guard matchesTerms else { return nil }

        return SearchResult(
            url: httpURL,
            title: Self.pageTitle(from: document) ?? domain,
            source: "Verified HTTP",
            httpStatusCode: httpResponse.statusCode,
            redirectsToHTTPS: false,
            httpsAvailable: false
        )
    }

    private func isHTTPSAvailable(for domain: String) async -> Bool {
        guard let httpsURL = URL(string: "https://\(domain)") else { return false }
        var request = URLRequest(url: httpsURL)
        request.setValue("Web-Runner/1.1", forHTTPHeaderField: "User-Agent")
        guard let (_, response) = try? await directSession.asyncData(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return (200..<400).contains(http.statusCode)
    }

    private static func httpDiscoveryCandidates(for terms: [String]) -> [String] {
        let seeds = Array(Set(terms + [terms.joined(separator: "-"), terms.joined()]))
            .filter { !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } }
            .sorted()
        var candidates: [String] = []
        var seen = Set<String>()
        func append(_ name: String) {
            for tld in httpVerificationTLDs where candidates.count < maxSearchResults {
                let domain = "\(name).\(tld)"
                if seen.insert(domain).inserted { candidates.append(domain) }
            }
        }
        for seed in seeds { append(seed) }
        for seed in seeds {
            for prefix in httpDiscoveryPrefixes where candidates.count < maxSearchResults {
                append("\(prefix)\(seed)")
            }
        }
        for seed in seeds {
            for suffix in httpDiscoverySuffixes where candidates.count < maxSearchResults {
                append("\(seed)\(suffix)")
            }
        }
        return candidates
    }

    private static func extractBingResults(from data: Data) -> [SearchResult] {
        extractResults(from: data, pattern: bingResultPattern, source: "Bing")
    }

    private static func extractDuckDuckGoResults(from data: Data) -> [SearchResult] {
        extractResults(from: data, pattern: duckDuckGoResultPattern, source: "DuckDuckGo")
    }

    private static func extractResults(
        from data: Data,
        pattern: NSRegularExpression,
        source: String
    ) -> [SearchResult] {
        let html = htmlString(from: data)
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        var results: [SearchResult] = []
        var seen = Set<String>()
        for match in pattern.matches(in: html, range: range) {
            let hrefRange = (1..<match.numberOfRanges)
                .compactMap { Range(match.range(at: $0), in: html) }
                .first
            guard let hrefRange else { continue }
            let rawHref = String(html[hrefRange]).replacingOccurrences(of: "&amp;", with: "&")
            let href = rawHref.hasPrefix("//") ? "https:\(rawHref)" : rawHref
            guard let sourceURL = URL(string: href),
                  let targetURL = destinationURL(from: sourceURL),
                  let host = targetURL.host?.lowercased(),
                  !host.contains("bing.com"),
                  !host.contains("duckduckgo.com"),
                  !host.hasSuffix(".onion"),
                  targetURL.scheme == "http" || targetURL.scheme == "https",
                  seen.insert(targetURL.absoluteString).inserted else { continue }
            results.append(SearchResult(url: targetURL, title: host, source: source))
        }
        return results
    }

    private static func destinationURL(from sourceURL: URL) -> URL? {
        if let components = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false),
           let redirected = components.queryItems?.first(where: { $0.name == "uddg" })?.value {
            return URL(string: redirected)
        }
        return decodedBingTargetURL(from: sourceURL) ?? sourceURL
    }

    private static func nextSearchPageURL(from data: Data, baseURL: URL) -> URL? {
        let html = htmlString(from: data)
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        for match in linkPattern.matches(in: html, range: range) {
            guard let matchRange = Range(match.range, in: html),
                  let hrefRange = Range(match.range(at: 1), in: html) else { continue }
            let start = matchRange.lowerBound
            let afterStart = matchRange.upperBound
            let end = html.range(of: "</a>", range: afterStart..<html.endIndex)?.upperBound ?? afterStart
            let anchor = html[start..<end].lowercased()
            guard anchor.contains("sb_pagn") || anchor.contains("next page") || anchor.contains("aria-label=\"next\"") else { continue }
            let rawHref = String(html[hrefRange]).replacingOccurrences(of: "&amp;", with: "&")
            guard !rawHref.hasPrefix("javascript:"),
                  let url = URL(string: rawHref, relativeTo: baseURL)?.absoluteURL,
                  url.host?.lowercased() == baseURL.host?.lowercased() else { continue }
            return url
        }
        return nil
    }

    private static func bingPageURL(
        endpoint: String,
        queryItems: [URLQueryItem],
        token: String,
        page: Int
    ) -> URL? {
        guard var components = URLComponents(string: endpoint) else { return nil }
        components.queryItems = queryItems + [
            URLQueryItem(name: "FPIG", value: token),
            URLQueryItem(name: "first", value: String(page * webResultsPerPage + 1)),
            URLQueryItem(name: "FORM", value: "PERE\(page - 1)")
        ]
        return components.url
    }

    private static func offsetPageURL(
        endpoint: String,
        queryItems: [URLQueryItem],
        itemName: String,
        offset: Int
    ) -> URL? {
        guard var components = URLComponents(string: endpoint) else { return nil }
        components.queryItems = queryItems.filter { $0.name != itemName } + [
            URLQueryItem(name: itemName, value: String(offset))
        ]
        return components.url
    }

    func clearSearchCache() {
        searchCache.clear()
    }

    func searchCacheSummary() -> (entries: Int, results: Int) {
        searchCache.summary()
    }

    private func normalizedQuery(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func searchSurfacePages(
        name: String,
        endpoint: String,
        queryItems: [URLQueryItem],
        limit: Int
    ) async throws -> [SearchResult] {
        var results: [SearchResult] = []
        var seen = Set<String>()
        guard var components = URLComponents(string: endpoint) else { throw URLError(.badURL) }
        components.queryItems = queryItems
        guard var nextPageURL = components.url else { throw URLError(.badURL) }
        var bingPage = 0
        var bingPaginationToken: String?
        var duckDuckGoPage = 0

        for _ in 0..<Self.maxSurfaceIndexPages where results.count < limit {
            let data = try await requestData(nextPageURL)
            let pageResults: [SearchResult]
            switch name {
            case "Bing":
                pageResults = Self.extractBingResults(from: data)
            case "Brave":
                pageResults = Self.extractBraveResults(from: data)
            case "DuckDuckGo":
                pageResults = Self.extractDuckDuckGoResults(from: data)
            default:
                pageResults = Self.extractSurfaceResults(from: data, source: name)
            }
            let before = results.count
            for result in pageResults where seen.insert(result.url.absoluteString).inserted {
                results.append(result)
                if results.count == limit { break }
            }
            guard results.count > before else { break }
            if name == "DuckDuckGo" {
                duckDuckGoPage += 1
                guard let next = Self.offsetPageURL(
                    endpoint: endpoint,
                    queryItems: queryItems,
                    itemName: "s",
                    offset: duckDuckGoPage * Self.webResultsPerPage
                ) else { break }
                nextPageURL = next
                continue
            }

            guard let providerNextURL = Self.nextSearchPageURL(from: data, baseURL: nextPageURL) else { break }
            if name == "Bing" {
                if bingPaginationToken == nil {
                    bingPaginationToken = URLComponents(url: providerNextURL, resolvingAgainstBaseURL: false)?
                        .queryItems?.first(where: { $0.name.caseInsensitiveCompare("FPIG") == .orderedSame })?.value
                }
                bingPage += 1
                if bingPage == 1 {
                    nextPageURL = providerNextURL
                } else if let bingPaginationToken,
                          let numberedPageURL = Self.bingPageURL(
                            endpoint: endpoint,
                            queryItems: queryItems,
                            token: bingPaginationToken,
                            page: bingPage
                          ) {
                    nextPageURL = numberedPageURL
                } else {
                    break
                }
            } else {
                guard providerNextURL != nextPageURL else { break }
                nextPageURL = providerNextURL
            }
        }
        return results
    }

    func searchSurfaceImages(query: String) async throws -> [ImageResult] {
        let cacheKey = SearchCacheKey(query: normalizedQuery(query), kind: .surfaceImages)
        if let cached = searchCache.cachedImageResults(for: cacheKey) { return cached }
        var results: [ImageResult] = []
        var seen = Set<String>()
        var first = 1

        for _ in 0..<Self.maxSurfaceImagePages where results.count < Self.maxSearchResults {
            guard var components = URLComponents(string: Self.bingImageSearchURL) else { throw URLError(.badURL) }
            components.queryItems = [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "adlt", value: "off"),
                URLQueryItem(name: "first", value: String(first))
            ]
            guard let url = components.url else { throw URLError(.badURL) }
            let pageResults = Self.extractImageResults(from: try await requestData(url))
            let before = results.count
            for result in pageResults where seen.insert(result.imageURL.absoluteString).inserted {
                results.append(result)
                if results.count == Self.maxSearchResults { break }
            }
            guard results.count > before else { break }
            first += Self.imageResultsPerPage
        }
        return results
    }

    private func requestData(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Web-Runner/1.1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await activeSession.asyncData(for: request)
        guard let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private static func extractSurfaceResults(from data: Data, source: String) -> [SearchResult] {
        let html = htmlString(from: data)
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        var results: [SearchResult] = []
        var seen = Set<String>()
        for match in linkPattern.matches(in: html, range: range) {
            guard let hrefRange = Range(match.range(at: 1), in: html) else { continue }
            let rawHref = String(html[hrefRange]).replacingOccurrences(of: "&amp;", with: "&")
            let href = rawHref.hasPrefix("//") ? "https:\(rawHref)" : rawHref
            guard let sourceURL = URL(string: href) else { continue }
            let targetURL: URL?
            if let components = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false),
               let redirected = components.queryItems?.first(where: { $0.name == "uddg" })?.value {
                targetURL = URL(string: redirected)
            } else {
                targetURL = decodedBingTargetURL(from: sourceURL) ?? sourceURL
            }
            guard let targetURL,
                  let host = targetURL.host?.lowercased(),
                  !host.contains("bing.com"),
                  !host.contains("duckduckgo.com"),
                  !host.hasSuffix(".onion"),
                  targetURL.scheme == "http" || targetURL.scheme == "https",
                  seen.insert(targetURL.absoluteString).inserted else { continue }
            results.append(SearchResult(url: targetURL, title: host, source: source))
            if results.count == maxSearchResults { break }
        }
        return results
    }

    private static func decodedBingTargetURL(from url: URL) -> URL? {
        guard url.host?.lowercased().contains("bing.com") == true,
              let encoded = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "u" })?.value,
              encoded.hasPrefix("a1") else { return nil }
        var base64 = String(encoded.dropFirst(2))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64), let destination = String(data: data, encoding: .utf8) else {
            return nil
        }
        return URL(string: destination)
    }

    private static func extractBraveResults(from data: Data) -> [SearchResult] {
        let html = htmlString(from: data)
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        var results: [SearchResult] = []
        var seen = Set<String>()
        for pattern in braveResultPatterns {
            for match in pattern.matches(in: html, range: range) {
                guard let urlRange = Range(match.range(at: 1), in: html),
                      let url = URL(string: String(html[urlRange]).replacingOccurrences(of: "&amp;", with: "&")),
                      let host = url.host?.lowercased(),
                      !host.hasSuffix(".onion"),
                      seen.insert(url.absoluteString).inserted else { continue }
                results.append(SearchResult(url: url, title: host, source: "Brave"))
                if results.count == maxSearchResults { return results }
            }
        }
        return results
    }

    private static func extractImageResults(from data: Data) -> [ImageResult] {
        let html = htmlString(from: data)
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        var results: [ImageResult] = []
        var seen = Set<String>()
        for match in imageMetadataPattern.matches(in: html, range: range) {
            guard let metadataRange = Range(match.range(at: 1), in: html) else { continue }
            let json = String(html[metadataRange])
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&amp;", with: "&")
            guard let jsonData = json.data(using: .utf8),
                  let metadata = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let thumbnailString = metadata["turl"] as? String,
                  let imageString = metadata["murl"] as? String,
                  let pageString = metadata["purl"] as? String,
                  let thumbnailURL = URL(string: thumbnailString),
                  let imageURL = URL(string: imageString),
                  let pageURL = URL(string: pageString),
                  !thumbnailURL.host.orEmpty.hasSuffix(".onion"),
                  !imageURL.host.orEmpty.hasSuffix(".onion"),
                  !pageURL.host.orEmpty.hasSuffix(".onion"),
                  seen.insert(imageURL.absoluteString).inserted else { continue }
            let title = (metadata["t"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            results.append(ImageResult(
                thumbnailURL: thumbnailURL,
                imageURL: imageURL,
                pageURL: pageURL,
                title: title?.isEmpty == false ? title! : (pageURL.host ?? "Image")
            ))
        }
        return results
    }

    private static func htmlString(from data: Data) -> String {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    private static func pageTitle(from html: String) -> String? {
        guard let match = html.range(
            of: "<title[^>]*>(.*?)</title>",
            options: [.regularExpression, .caseInsensitive]
        ) else { return nil }
        let title = String(html[match])
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : String(title.prefix(160))
    }
}
