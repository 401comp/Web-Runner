import SwiftUI
import AppKit
import Combine

private let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .medium
    return formatter
}()

private class ScrollPassthroughTextField: NSTextField {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}

private final class ClickableLinkField: ScrollPassthroughTextField {
    var linkURL: URL?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 1, let linkURL {
            NSWorkspace.shared.open(linkURL)
        } else {
            super.mouseDown(with: event)
        }
    }

    override func resetCursorRects() {
        if linkURL != nil { addCursorRect(bounds, cursor: .pointingHand) }
    }
}

struct ActivitySpinner: NSViewRepresentable {
    let isAnimating: Bool

    func makeNSView(context: Context) -> NSProgressIndicator {
        let indicator = NSProgressIndicator()
        indicator.style = .spinning
        indicator.controlSize = .small
        indicator.isDisplayedWhenStopped = false
        return indicator
    }

    func updateNSView(_ indicator: NSProgressIndicator, context: Context) {
        if isAnimating { indicator.startAnimation(nil) } else { indicator.stopAnimation(nil) }
    }
}

final class ImageMemoryCache: @unchecked Sendable {
    static let shared = ImageMemoryCache()

    private struct Entry {
        let image: NSImage
        let byteCount: Int
        var lastAccess: Date
    }

    private let lock = NSLock()
    private let byteLimit = 80 * 1024 * 1024
    private var entries: [String: Entry] = [:]
    private var totalBytes = 0

    func image(for key: String) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = entries[key] else { return nil }
        entry.lastAccess = Date()
        entries[key] = entry
        return entry.image
    }

    func store(_ image: NSImage, data: Data, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        if let previous = entries[key] { totalBytes -= previous.byteCount }
        entries[key] = Entry(image: image, byteCount: data.count, lastAccess: Date())
        totalBytes += data.count
        while totalBytes > byteLimit, let oldest = entries.min(by: { $0.value.lastAccess < $1.value.lastAccess }) {
            totalBytes -= oldest.value.byteCount
            entries[oldest.key] = nil
        }
    }

    func summary() -> (entries: Int, bytes: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (entries.count, totalBytes)
    }

    func clear() {
        lock.lock()
        entries.removeAll()
        totalBytes = 0
        lock.unlock()
    }
}

private actor ThumbnailLoader {
    static let shared = ThumbnailLoader()

    private let maximumConcurrentLoads = 8
    private var activeLoads = 0
    private var waitingLoads: [CheckedContinuation<Void, Never>] = []

    func load(thumbnailURL: URL, fallbackURL: URL, referrer: URL, socksPort: Int?) async -> NSImage? {
        for candidate in [thumbnailURL, fallbackURL] where ImageMemoryCache.shared.image(for: candidate.absoluteString) == nil {
            for referer in [referrer, nil] {
                await acquireSlot()
                let data = await requestData(from: candidate, referrer: referer, socksPort: socksPort)
                releaseSlot()
                if let data, let image = NSImage(data: data) {
                    ImageMemoryCache.shared.store(image, data: data, for: candidate.absoluteString)
                    return image
                }
            }
        }
        return ImageMemoryCache.shared.image(for: thumbnailURL.absoluteString)
            ?? ImageMemoryCache.shared.image(for: fallbackURL.absoluteString)
    }

    private func acquireSlot() async {
        if activeLoads < maximumConcurrentLoads {
            activeLoads += 1
            return
        }
        await withCheckedContinuation { continuation in
            waitingLoads.append(continuation)
        }
    }

    private func releaseSlot() {
        if let next = waitingLoads.first {
            waitingLoads.removeFirst()
            next.resume()
        } else {
            activeLoads -= 1
        }
    }

    private func requestData(from url: URL, referrer: URL?, socksPort: Int?) async -> Data? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        configuration.waitsForConnectivity = false
        if let socksPort {
            configuration.connectionProxyDictionary = [
                kCFNetworkProxiesSOCKSEnable as String: true,
                kCFNetworkProxiesSOCKSProxy as String: "127.0.0.1",
                kCFNetworkProxiesSOCKSPort as String: socksPort
            ]
        }
        var request = URLRequest(url: url)
        if let referrer { request.setValue(referrer.absoluteString, forHTTPHeaderField: "Referer") }
        request.setValue("Mozilla/5.0 Web-Runner/1.1", forHTTPHeaderField: "User-Agent")
        return await withCheckedContinuation { continuation in
            URLSession(configuration: configuration).dataTask(with: request) { data, response, error in
                guard error == nil,
                      let response = response as? HTTPURLResponse,
                      (200..<400).contains(response.statusCode) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: data)
            }.resume()
        }
    }
}

struct RemoteThumbnail: NSViewRepresentable {
    let url: URL
    let fallbackURL: URL
    let referrer: URL
    let socksPort: Int?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSImageView {
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        context.coordinator.load(url, fallbackURL: fallbackURL, referrer: referrer, socksPort: socksPort, into: imageView)
        return imageView
    }

    func updateNSView(_ imageView: NSImageView, context: Context) {
        context.coordinator.load(url, fallbackURL: fallbackURL, referrer: referrer, socksPort: socksPort, into: imageView)
    }

    final class Coordinator: @unchecked Sendable {
        private var loadedURL: URL?
        private var loadedFallbackURL: URL?
        private var loadedReferrer: URL?
        private var loadedSocksPort: Int?
        private var task: Task<Void, Never>?

        deinit { task?.cancel() }

        func load(_ url: URL, fallbackURL: URL, referrer: URL, socksPort: Int?, into imageView: NSImageView) {
            guard loadedURL != url || loadedFallbackURL != fallbackURL || loadedReferrer != referrer || loadedSocksPort != socksPort else { return }
            task?.cancel()
            loadedURL = url
            loadedFallbackURL = fallbackURL
            loadedReferrer = referrer
            loadedSocksPort = socksPort
            imageView.image = nil
            if let image = ImageMemoryCache.shared.image(for: url.absoluteString)
                ?? ImageMemoryCache.shared.image(for: fallbackURL.absoluteString) {
                imageView.image = image
                return
            }
            task = Task { [weak self, weak imageView] in
                guard let image = await ThumbnailLoader.shared.load(
                    thumbnailURL: url,
                    fallbackURL: fallbackURL,
                    referrer: referrer,
                    socksPort: socksPort
                ) else { return }
                DispatchQueue.main.async {
                    guard let self,
                          self.loadedURL == url,
                          self.loadedFallbackURL == fallbackURL,
                          self.loadedReferrer == referrer,
                          self.loadedSocksPort == socksPort else { return }
                    imageView?.image = image
                }
            }
        }
    }
}

struct ImageResultGrid: View {
    let results: [ImageResult]
    let socksPort: Int?
    let onCopy: (ImageResult) -> Void
    @State private var visibleCount = 100

    private var visibleResults: [ImageResult] { Array(results.prefix(visibleCount)) }

    var body: some View {
        GeometryReader { proxy in
            let spacing: CGFloat = 12
            let columns = max(Int(proxy.size.width / 210), 1)
            let tileWidth = (proxy.size.width - CGFloat(columns + 1) * spacing) / CGFloat(columns)
            let rows = Int(ceil(Double(visibleResults.count) / Double(columns)))

            ScrollView {
                VStack(spacing: spacing) {
                    ForEach(0..<rows, id: \.self) { row in
                        HStack(alignment: .top, spacing: spacing) {
                            ForEach(0..<columns, id: \.self) { column in
                                let index = row * columns + column
                                if index < visibleResults.count {
                                    ImageResultTile(
                                        result: visibleResults[index],
                                        socksPort: socksPort,
                                        onCopy: onCopy
                                    )
                                        .frame(width: tileWidth)
                                } else {
                                    Spacer().frame(width: tileWidth)
                                }
                            }
                        }
                    }
                    if visibleResults.count < results.count {
                        Button("Load 100 More") {
                            visibleCount = min(visibleCount + 100, results.count)
                        }
                    }
                }
                .padding(spacing)
            }
        }
    }
}

struct ImageResultTile: View {
    let result: ImageResult
    let socksPort: Int?
    let onCopy: (ImageResult) -> Void

    var body: some View {
        tile
    }

    private var tile: some View {
        VStack(alignment: .leading, spacing: 6) {
            RemoteThumbnail(url: result.thumbnailURL, fallbackURL: result.imageURL, referrer: result.pageURL, socksPort: socksPort)
                .frame(height: 145)
                .clipped()
            Text(result.title)
                .font(.caption)
                .lineLimit(2)
                .frame(height: 30, alignment: .topLeading)
            Text(result.pageURL.host ?? result.imageURL.host ?? "")
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
            Button("Copy Link") {
                onCopy(result)
            }
            .buttonStyle(BorderlessButtonStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 230, alignment: .top)
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25), lineWidth: 1))
    }
}

enum SearchMode: String, CaseIterable, Identifiable {
    case web = "Web"
    case images = "Image Search"

    var id: String { rawValue }
}

struct ExportEntry {
    let url: URL
    let imageURL: URL?
    let title: String
    let source: String
    let kind: String
}

private enum NetworkStatusReader {
    static func vpnOrTunnelPresent() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return output.range(of: "(?m)^utun[0-9]+:", options: .regularExpression) != nil
    }

    static func fetchPublicIPAddress(completion: @escaping (String?) -> Void) {
        guard let url = URL(string: "https://api64.ipify.org") else {
            completion(nil)
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("Web-Runner/1.1", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, _, _ in
            let address = data.flatMap { String(data: $0, encoding: .utf8) }?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            completion(address?.isEmpty == false ? address : nil)
        }.resume()
    }
}

final class ScannerViewModel: ObservableObject {
    @Published var results: [SearchResult] = []
    @Published var imageResults: [ImageResult] = []
    @Published var isSearching = false
    @Published var statusMessage = "Ready"
    @Published var searchQuery = "" {
        didSet {
            guard searchQuery != activeSearchQuery, !isSearching else { return }
            results.removeAll()
            imageResults.removeAll()
            statusMessage = "Ready to search"
        }
    }
    @Published var showHTTPOnly = false
    @Published var searchMode: SearchMode = .web
    @Published var useTor = false
    @Published var torStatus = "Checking..."
    @Published var torChecked = false
    @Published var activeTorPort = 0
    @Published var cacheEntryCount = 0
    @Published var cachedResultCount = 0
    @Published var imageCacheEntryCount = 0
    @Published var imageCacheBytes = 0
    @Published var vpnStatus = "Checking..."
    @Published var publicIPAddress = "Checking..."

    private let scanner = HTTPScanner()
    private var currentTask: Task<Void, Never>?
    private var activeSearchQuery = ""

    init() {
        scanner.useTor = false
        checkTorOnLaunch()
        refreshNetworkStatus()
    }

    var filteredResults: [SearchResult] {
        showHTTPOnly ? results.filter(\.isHTTPOnly) : results
    }

    var exportEntries: [ExportEntry] {
        if searchMode == .images {
            return imageResults.map {
                ExportEntry(
                    url: $0.pageURL,
                    imageURL: $0.imageURL,
                    title: $0.title,
                    source: $0.pageURL.host ?? "",
                    kind: "Image"
                )
            }
        }
        return filteredResults.map {
            ExportEntry(url: $0.url, imageURL: nil, title: $0.title, source: $0.source, kind: "Web")
        }
    }

    func checkTorOnLaunch() {
        Task {
            let (connected, port) = await scanner.checkTorConnection()
            await MainActor.run {
                torChecked = true
                activeTorPort = connected ? port : 0
                scanner.useTor = false
                torStatus = connected ? "Available :\(port)" : "Disconnected"
                if !isSearching { statusMessage = connected ? "Tor available on 127.0.0.1:\(port)" : "Ready" }
            }
        }
    }

    func setUseTor(_ enabled: Bool) {
        guard !enabled || activeTorPort != 0 else {
            useTor = false
            scanner.useTor = false
            torStatus = "Tor proxy unavailable"
            return
        }
        useTor = enabled
        scanner.useTor = enabled
        torStatus = enabled ? "Connected :\(activeTorPort)" : "Available :\(activeTorPort)"
    }

    func startSearch() {
        let label = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else {
            statusMessage = "Enter a search term"
            return
        }
        guard !isSearching else { return }
        guard !useTor || activeTorPort != 0 else {
            statusMessage = "Tor proxy is unavailable"
            return
        }

        isSearching = true
        results.removeAll()
        imageResults.removeAll()
        activeSearchQuery = label
        scanner.useTor = useTor

        currentTask = Task {
            do {
                if searchMode == .images {
                    await MainActor.run {
                        statusMessage = useTor ? "Searching images through Tor..." : "Searching images..."
                    }
                    let found = try await scanner.searchSurfaceImages(query: label)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        imageResults = found
                        refreshSearchCacheSummary()
                        isSearching = false
                        statusMessage = found.isEmpty ? "No image results found for \"\(label)\"" : "Done. \(found.count) image results for \"\(label)\"."
                    }
                } else {
                    await MainActor.run {
                        statusMessage = useTor ? "Searching the web through Tor..." : "Searching the web..."
                    }
                    let found: [SearchResult]
                    if showHTTPOnly {
                        await MainActor.run {
                            statusMessage = "Verifying HTTP-only candidates directly..."
                        }
                        found = try await scanner.searchVerifiedHTTPOnly(query: label)
                    } else {
                        found = try await scanner.searchSurfaceWeb(query: label)
                    }
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        results = found
                        refreshSearchCacheSummary()
                        isSearching = false
                        statusMessage = found.isEmpty
                            ? (showHTTPOnly
                                ? "No verified HTTP-only sites found for \"\(label)\""
                                : "No results found for \"\(label)\"")
                            : (showHTTPOnly
                                ? "Done. \(found.count) verified HTTP-only sites for \"\(label)\"."
                                : "Done. \(found.count) results for \"\(label)\" from \(sourceSummary(found)).")
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    isSearching = false
                    statusMessage = "\(searchMode.rawValue) search is unavailable right now"
                }
            }
        }
    }

    func stopSearch() {
        currentTask?.cancel()
        currentTask = nil
        isSearching = false
        statusMessage = searchMode == .images ? "Search cancelled." : "Search cancelled. \(results.count) results retained."
    }

    func clearResults() {
        currentTask?.cancel()
        results.removeAll()
        imageResults.removeAll()
        isSearching = false
        statusMessage = "Results cleared"
    }

    func copyImageLink(_ result: ImageResult) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        statusMessage = pasteboard.setString(result.pageURL.absoluteString, forType: .string)
            ? "Copied image result link"
            : "Could not copy image result link"
    }

    func clearSearchCache() {
        scanner.clearSearchCache()
        ImageMemoryCache.shared.clear()
        refreshSearchCacheSummary()
        statusMessage = "Search and image cache cleared"
    }

    private func refreshSearchCacheSummary() {
        let summary = scanner.searchCacheSummary()
        cacheEntryCount = summary.entries
        cachedResultCount = summary.results
        refreshImageCacheSummary()
    }

    func refreshImageCacheSummary() {
        let imageSummary = ImageMemoryCache.shared.summary()
        imageCacheEntryCount = imageSummary.entries
        imageCacheBytes = imageSummary.bytes
    }

    func refreshNetworkStatus() {
        vpnStatus = "Checking..."
        publicIPAddress = "Checking..."
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let vpnDetected = NetworkStatusReader.vpnOrTunnelPresent()
            NetworkStatusReader.fetchPublicIPAddress { address in
                DispatchQueue.main.async {
                    self?.vpnStatus = vpnDetected ? "VPN/tunnel detected" : "No VPN/tunnel detected"
                    self?.publicIPAddress = address ?? "Unavailable"
                }
            }
        }
    }

    private func sourceSummary(_ results: [SearchResult]) -> String {
        var sourceCounts: [String: Int] = [:]
        for result in results {
            for source in result.source.components(separatedBy: ", ") {
                sourceCounts[source, default: 0] += 1
            }
        }
        return sourceCounts
            .map { "\($0.key) (\($0.value))" }
            .sorted()
            .joined(separator: ", ")
    }

    func connectTor() {
        torStatus = "Starting..."
        statusMessage = "Launching Tor..."
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", "tor &"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            torStatus = "Failed"
            statusMessage = "Could not start tor -- is it installed?"
            return
        }
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            let (connected, port) = await scanner.checkTorConnection()
            await MainActor.run {
                activeTorPort = connected ? port : 0
                scanner.useTor = connected && useTor
                torStatus = connected ? "Connected :\(port)" : "Not ready"
                statusMessage = connected ? "Tor connected on 127.0.0.1:\(port)" : "Tor launched but is not ready yet"
            }
        }
    }

    func exportResults() {
        let panel = NSSavePanel()
        panel.title = "Export Results"
        panel.nameFieldStringValue = "WebRunner_Results.txt"
        panel.allowedFileTypes = ["txt"]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let entries = exportEntries
        let rows = entries.map { entry in
            [
                entry.kind,
                entry.url.absoluteString,
                entry.imageURL?.absoluteString ?? "",
                entry.title,
                entry.source,
                entry.url.scheme?.uppercased() ?? "-"
            ].joined(separator: "\t")
        }
        let text = ([
            "Web-Runner Results",
            "Generated: \(dateFormatter.string(from: Date()))",
            "",
            "Type\tURL\tImage URL\tTitle\tSource\tProtocol"
        ] + rows).joined(separator: "\n")
        do {
            try text.write(to: destination, atomically: true, encoding: .utf8)
            statusMessage = "Exported \(entries.count) results to \(destination.lastPathComponent)"
        } catch {
            statusMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    func exportBookmarks() {
        let panel = NSSavePanel()
        panel.title = "Export Bookmarks"
        panel.nameFieldStringValue = "WebRunner_Bookmarks.html"
        panel.allowedFileTypes = ["html"]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let timestamp = String(Int(Date().timeIntervalSince1970))
        var lines = [
            "<!DOCTYPE NETSCAPE-Bookmark-file-1>",
            "<!-- This is an automatically generated file. -->",
            "<META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; charset=UTF-8\">",
            "<TITLE>Web-Runner Results</TITLE>",
            "<H1>Web-Runner Results</H1>",
            "<DL><p>",
            "    <DT><H3 ADD_DATE=\"\(timestamp)\">Web-Runner Results</H3>",
            "    <DL><p>"
        ]
        let entries = exportEntries
        var seen = Set<String>()
        let uniqueEntries = entries.filter { seen.insert(bookmarkKey(for: $0.url)).inserted }
        for entry in uniqueEntries {
            lines.append("    <DT><A HREF=\"\(htmlEscaped(entry.url.absoluteString))\" ADD_DATE=\"\(timestamp)\">\(htmlEscaped(entry.title))</A>")
        }
        lines.append("    </DL><p>")
        lines.append("</DL><p>")
        do {
            try lines.joined(separator: "\n").write(to: destination, atomically: true, encoding: .utf8)
            statusMessage = "Exported \(uniqueEntries.count) unique bookmarks to \(destination.lastPathComponent)"
        } catch {
            statusMessage = "Bookmark export failed: \(error.localizedDescription)"
        }
    }

    private func htmlEscaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func bookmarkKey(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString.lowercased()
        }
        components.scheme = nil
        components.port = nil
        components.fragment = nil
        if let host = components.host?.lowercased() {
            components.host = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        components.path = components.path == "/" ? "" : components.path
        let trackingNames: Set<String> = ["fbclid", "gclid", "dclid", "msclkid", "igshid", "ref", "referrer"]
        components.queryItems = components.queryItems?.filter { item in
            let name = item.name.lowercased()
            return !name.hasPrefix("utm_") && !name.hasPrefix("mc_") && !name.hasPrefix("_hs") && !trackingNames.contains(name)
        }
        return components.string?.lowercased() ?? url.absoluteString.lowercased()
    }
}

final class ResultsTableDelegate: NSObject, NSTableViewDelegate, NSTableViewDataSource {
    var results: [SearchResult] = []
    private var sortedResults: [SearchResult] = []

    func applySort(_ descriptors: [NSSortDescriptor]) {
        guard let descriptor = descriptors.first, let key = descriptor.key else {
            sortedResults = results
            return
        }
        sortedResults = results.sorted { lhs, rhs in
            let comparison: ComparisonResult
            switch key {
            case "url": comparison = lhs.url.absoluteString.localizedCaseInsensitiveCompare(rhs.url.absoluteString)
            case "title": comparison = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
            case "source": comparison = lhs.source.localizedCaseInsensitiveCompare(rhs.source)
            case "protocol": comparison = (lhs.url.scheme ?? "").localizedCaseInsensitiveCompare(rhs.url.scheme ?? "")
            default: comparison = .orderedSame
            }
            return descriptor.ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { sortedResults.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < sortedResults.count, let id = tableColumn?.identifier.rawValue else { return nil }
        let result = sortedResults[row]
        switch id {
        case "url":
            let field = ClickableLinkField(labelWithString: result.url.absoluteString)
            field.linkURL = result.url
            return configure(field, font: .monospacedSystemFont(ofSize: 12, weight: .regular), color: .linkColor)
        case "title":
            return label(result.title)
        case "source":
            return label(result.source, color: .secondaryLabelColor)
        case "protocol":
            return label((result.url.scheme ?? "-").uppercased(), font: .monospacedSystemFont(ofSize: 11, weight: .medium), color: result.isHTTPOnly ? .systemOrange : .secondaryLabelColor, alignment: .center)
        default:
            return nil
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 24 }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        applySort(tableView.sortDescriptors)
        tableView.reloadData()
    }

    private func label(_ text: String, font: NSFont = .systemFont(ofSize: 12), color: NSColor = .labelColor, alignment: NSTextAlignment = .left) -> NSTextField {
        configure(ScrollPassthroughTextField(labelWithString: text), font: font, color: color, alignment: alignment)
    }

    private func configure(_ field: NSTextField, font: NSFont, color: NSColor, alignment: NSTextAlignment = .left) -> NSTextField {
        field.isSelectable = true
        field.isEditable = false
        field.drawsBackground = false
        field.isBordered = false
        field.lineBreakMode = .byTruncatingTail
        field.font = font
        field.textColor = color
        field.alignment = alignment
        return field
    }
}

struct ResultsTableView: NSViewRepresentable {
    let results: [SearchResult]

    func makeCoordinator() -> ResultsTableDelegate { ResultsTableDelegate() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        let tableView = NSTableView()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.allowsColumnResizing = true
        tableView.intercellSpacing = NSSize(width: 6, height: 2)
        for column in [
            ("url", "URL", 410.0, 180.0, 900.0),
            ("title", "Title", 260.0, 120.0, 600.0),
            ("source", "Source", 115.0, 75.0, 180.0),
            ("protocol", "Protocol", 75.0, 60.0, 100.0)
        ] {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.0))
            tableColumn.title = column.1
            tableColumn.width = CGFloat(column.2)
            tableColumn.minWidth = CGFloat(column.3)
            tableColumn.maxWidth = CGFloat(column.4)
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.0, ascending: true)
            tableView.addTableColumn(tableColumn)
        }
        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        scrollView.documentView = tableView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tableView = scrollView.documentView as? NSTableView else { return }
        context.coordinator.results = results
        context.coordinator.applySort(tableView.sortDescriptors)
        tableView.reloadData()
    }
}

struct ContentView: View {
    @ObservedObject private var vm = ScannerViewModel()

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 210).padding()
            Divider()
            VStack(spacing: 0) {
                searchBar.padding(.horizontal).padding(.vertical, 10)
                Divider()
                resultsArea
                Divider()
                statusBar.padding(.horizontal).padding(.vertical, 8)
            }
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            vm.refreshImageCacheSummary()
        }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if vm.isSearching {
                    Button(action: vm.stopSearch) {
                        Text("Stop").foregroundColor(.red).frame(maxWidth: .infinity)
                    }
                }
                Button(action: vm.clearResults) {
                    Text("Clear All").frame(maxWidth: .infinity)
                }
                .disabled(vm.isSearching || (vm.results.isEmpty && vm.imageResults.isEmpty))
                Button(action: vm.clearSearchCache) {
                    Text("Clear Search Cache").frame(maxWidth: .infinity)
                }
                .disabled(vm.isSearching)
                Text("Search cache: \(vm.cacheEntryCount) entries, \(vm.cachedResultCount) results (10 min)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(String(format: "Image cache: %d items, %.1f MB", vm.imageCacheEntryCount, Double(vm.imageCacheBytes) / 1_048_576))
                    .font(.caption)
                    .foregroundColor(.secondary)

                Divider()
                Text("Display").font(.headline)
                Toggle(
                    vm.searchMode == .images ? "Verified HTTP-only (disabled)" : "Verified HTTP-only",
                    isOn: $vm.showHTTPOnly
                )
                    .disabled(vm.searchMode == .images)

                Divider()
                Text("Tor Proxy").font(.headline)
                Toggle("Use Tor (SOCKS5)", isOn: Binding(get: { vm.useTor }, set: vm.setUseTor))
                    .disabled(vm.isSearching || vm.activeTorPort == 0)
                Text(vm.torStatus)
                    .font(.caption)
                    .foregroundColor(vm.torStatus.hasPrefix("Connected") ? .green : .orange)
                if vm.activeTorPort == 0 {
                    Button(action: vm.connectTor) {
                        Text("Connect").frame(maxWidth: .infinity)
                    }
                    .disabled(vm.torStatus == "Starting...")
                }

                Divider()
                Text("Network").font(.headline)
                Text(vm.vpnStatus)
                    .font(.caption)
                    .foregroundColor(vm.vpnStatus == "No VPN/tunnel detected" ? .secondary : .green)
                Text("Public IP: \(vm.publicIPAddress)")
                    .font(.caption)
                    .foregroundColor(.green)
                Button(action: vm.refreshNetworkStatus) {
                    Text("Refresh Network Status").frame(maxWidth: .infinity)
                }
                .disabled(vm.isSearching)

                Spacer(minLength: 20)
                Button(action: vm.exportResults) {
                    Text("Export Results").frame(maxWidth: .infinity)
                }
                .disabled(vm.exportEntries.isEmpty)
                Button(action: vm.exportBookmarks) {
                    Text("Export Bookmarks").frame(maxWidth: .infinity)
                }
                .disabled(vm.exportEntries.isEmpty)
            }
        }
    }

    private var searchBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Picker("Search mode", selection: $vm.searchMode) {
                    ForEach(SearchMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 190)
                .disabled(vm.isSearching)

                Spacer()
            }
            HStack(spacing: 8) {
                TextField("Search terms", text: $vm.searchQuery, onCommit: vm.startSearch)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                Button("Search", action: vm.startSearch)
                    .disabled(vm.isSearching || vm.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var resultsArea: some View {
        VStack(spacing: 0) {
            if vm.searchMode == .images && !vm.imageResults.isEmpty {
                ImageResultGrid(
                    results: vm.imageResults,
                    socksPort: vm.useTor ? vm.activeTorPort : nil,
                    onCopy: vm.copyImageLink
                )
                    .id(vm.imageResults.first?.id)
            } else if vm.searchMode == .web && !vm.filteredResults.isEmpty {
                ResultsTableView(results: vm.filteredResults)
            } else if !vm.isSearching {
                Spacer()
                Text("No Results").font(.title).foregroundColor(.secondary)
                Text("Enter search terms above.")
                    .font(.caption)
                    .foregroundColor(Color.secondary.opacity(0.7))
                    .padding(.top, 4)
                Spacer()
            } else {
                Spacer()
                Spacer()
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            if vm.isSearching {
                ActivitySpinner(isAnimating: true).frame(width: 16, height: 16)
            }
            Text(vm.statusMessage).font(.caption).foregroundColor(.secondary).lineLimit(1)
            Spacer()
            if vm.searchMode == .images && !vm.imageResults.isEmpty {
                Text("Images: \(vm.imageResults.count)").font(.caption).foregroundColor(.secondary)
            } else if !vm.results.isEmpty {
                Text(vm.showHTTPOnly ? "Showing: \(vm.filteredResults.count) of \(vm.results.count)" : "Results: \(vm.results.count)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}
