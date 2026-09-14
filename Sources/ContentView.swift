import SwiftUI
import AppKit

private let dateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .medium
    return f
}()

// MARK: - Selectable Text (NSTextField wrapper for copy support)

private class ScrollPassthroughTextField: NSTextField {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}

struct SelectableText: NSViewRepresentable {
    let text: String
    var font: NSFont = .systemFont(ofSize: 12)
    var color: NSColor = .labelColor
    var alignment: NSTextAlignment = .left

    func makeNSView(context: Context) -> NSTextField {
        let field = ScrollPassthroughTextField(labelWithString: text)
        field.isSelectable = true
        field.isEditable = false
        field.drawsBackground = false
        field.isBordered = false
        field.lineBreakMode = .byTruncatingTail
        field.font = font
        field.textColor = color
        field.alignment = alignment
        field.setContentHuggingPriority(.defaultHigh, for: .vertical)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        nsView.stringValue = text
        nsView.font = font
        nsView.textColor = color
        nsView.alignment = alignment
    }

    static func mono(_ text: String, color: NSColor = .labelColor, alignment: NSTextAlignment = .left) -> SelectableText {
        SelectableText(
            text: text,
            font: .monospacedSystemFont(ofSize: 12, weight: .regular),
            color: color,
            alignment: alignment
        )
    }
}

// MARK: - View Model

final class ScannerViewModel: ObservableObject {
    @Published var results: [SiteResult] = []
    @Published var isScanning = false
    @Published var statusMessage = "Ready"
    @Published var progress: Double = 0
    @Published var domainsChecked = 0
    @Published var totalDomains = 0

    @Published var searchQuery = ""
    @Published var showHTTPOnly = false
    @Published var useTor = true
    @Published var torStatus = "Checking..."
    @Published var torChecked = false

    private let scanner = HTTPScanner()
    private var currentTask: Task<Void, Never>?

    init() {
        scanner.useTor = true
        checkTorOnLaunch()
    }

    func checkTorOnLaunch() {
        torStatus = "Checking..."
        Task {
            let (connected, port) = await scanner.checkTorConnection()
            await MainActor.run {
                torChecked = true
                if connected {
                    useTor = true
                    scanner.useTor = true
                    torStatus = "Connected :\(port)"
                    statusMessage = "Tor connected on 127.0.0.1:\(port)"
                } else {
                    useTor = false
                    scanner.useTor = false
                    torStatus = "Disconnected"
                    statusMessage = "Tor not detected -- click Connect to start"
                }
            }
        }
    }

    static let allTLDs = [
        "com", "net", "org", "info", "biz", "io", "xyz", "site", "us", "co",
        "fun", "online", "live", "tech", "dev", "app", "me", "tv", "cc", "in",
        "de", "uk", "ru", "cn", "jp", "fr", "au", "ca", "br", "nl",
        "eu", "ch", "se", "no", "fi", "dk", "pl", "cz", "at", "be",
        "club", "shop", "store", "blog", "page", "space", "top", "pro", "mobi",
        "name", "mx", "ar", "za", "kr", "tw", "sg", "hk", "nz", "il",
        "onion"
    ]

    var filteredResults: [SiteResult] {
        showHTTPOnly ? results.filter(\.isHTTPOnly) : results
    }

    func startSearch() {
        let keywords = searchQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
        guard !keywords.isEmpty else {
            statusMessage = "Enter a search term"
            return
        }
        guard !isScanning else { return }

        isScanning = true
        progress = 0
        domainsChecked = 0

        let scannerRef = scanner
        scannerRef.useTor = useTor
        let tlds = Self.allTLDs
        let label = keywords.joined(separator: " ")

        currentTask = Task {
            let allDomains = scannerRef.searchDomains(keywords: keywords, tlds: tlds)
            await MainActor.run { totalDomains = allDomains.count }
            let torLabel = scannerRef.useTor ? " (via Tor)" : ""
            await MainActor.run { statusMessage = "Searching \(allDomains.count) domains for \"\(label)\"\(torLabel)..." }

            await scanDomains(allDomains, scanner: scannerRef, searchKeywords: keywords)

            if !Task.isCancelled {
                await MainActor.run {
                    isScanning = false
                    statusMessage = "Done. \(results.count) sites contain \"\(label)\"."
                }
            }
        }
    }

    private func scanDomains(_ domains: [String], scanner scannerRef: HTTPScanner, searchKeywords: [String]? = nil) async {
        let maxConcurrent = useTor ? 6 : 25

        await withTaskGroup(of: SiteResult?.self) { group in
            var iterator = domains.makeIterator()

            for _ in 0..<min(maxConcurrent, domains.count) {
                if let domain = iterator.next() {
                    let kws = searchKeywords
                    group.addTask {
                        guard !Task.isCancelled else { return nil }
                        return await scannerRef.checkDomain(domain, searchKeywords: kws)
                    }
                }
            }

            for await result in group {
                guard !Task.isCancelled else { break }

                await MainActor.run {
                    domainsChecked += 1
                    progress = Double(domainsChecked) / Double(max(totalDomains, 1))
                    statusMessage = "Scanning... \(domainsChecked)/\(totalDomains)"

                    if let result = result {
                        results.append(result)
                    }
                }

                if let domain = iterator.next() {
                    let kws = searchKeywords
                    group.addTask {
                        guard !Task.isCancelled else { return nil }
                        return await scannerRef.checkDomain(domain, searchKeywords: kws)
                    }
                }
            }
        }
    }

    func stopScan() {
        currentTask?.cancel()
        currentTask = nil
        isScanning = false
        statusMessage = "Cancelled. Found \(results.count) sites so far."
    }

    func toggleTor() {
        useTor.toggle()
        scanner.useTor = useTor
        if useTor {
            torStatus = "Checking..."
            statusMessage = "Probing ports 9050, 9150..."
            Task {
                let (connected, port) = await scanner.checkTorConnection()
                await MainActor.run {
                    if connected {
                        torStatus = "Connected :\(port)"
                        statusMessage = "Tor proxy connected on 127.0.0.1:\(port)"
                    } else {
                        useTor = false
                        scanner.useTor = false
                        torStatus = "Disconnected"
                        statusMessage = "No Tor on ports 9050/9150 -- click Connect"
                    }
                }
            }
        } else {
            torStatus = "Off"
            statusMessage = "Tor disabled -- using direct connection"
        }
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
            statusMessage = "Could not start tor -- is it installed? (brew install tor)"
            return
        }

        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            let (connected, port) = await scanner.checkTorConnection()
            await MainActor.run {
                if connected {
                    useTor = true
                    scanner.useTor = true
                    torStatus = "Connected :\(port)"
                    statusMessage = "Tor started and connected on 127.0.0.1:\(port)"
                } else {
                    torStatus = "Not ready"
                    statusMessage = "Tor launched but not responding yet -- try toggling in a few seconds"
                }
            }
        }
    }

    func clearResults() {
        results.removeAll()
        progress = 0
        domainsChecked = 0
        totalDomains = 0
        statusMessage = "Results cleared"
    }

    func exportResults() {
        let panel = NSSavePanel()
        panel.title = "Export Results"
        panel.nameFieldStringValue = "WebRunner_Results.txt"
        panel.allowedFileTypes = ["txt"]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let resultsToSave = filteredResults
        var lines: [String] = []
        lines.append("Web-Runner Results")
        lines.append("Generated: \(dateFormatter.string(from: Date()))")
        lines.append(String(repeating: "=", count: 100))
        lines.append("")

        for result in resultsToSave {
            var line = "http://\(result.domain)"
            line += "  |  \(result.pingable ? "UP" : "DOWN")"
            line += "  |  \(httpCodeLabel(result.httpStatusCode))"
            if result.isHTTPOnly {
                line += "  |  HTTP-ONLY"
            } else if result.redirectsToHTTPS {
                line += "  |  REDIRECTS-TO-HTTPS"
            } else {
                line += "  |  HTTP+HTTPS"
            }
            if let tag = result.matchedTag {
                line += "  |  Tag: \(tag)"
            }
            if let snippet = result.matchedSnippet {
                line += "  |  \"\(snippet)\""
            }
            if let ip = result.pingIP { line += "  |  IP: \(ip)" }
            if let ms = result.pingLatencyMs { line += "  |  \(String(format: "%.0fms", ms))" }
            lines.append(line)
        }

        lines.append("")
        lines.append("Total: \(resultsToSave.count) sites")

        let content = lines.joined(separator: "\n")
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            statusMessage = "Exported \(resultsToSave.count) results to \(url.lastPathComponent)"
        } catch {
            statusMessage = "Export failed: \(error.localizedDescription)"
        }
    }

}

// MARK: - Progress Bar

struct ProgressBar: View {
    var value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle()
                    .foregroundColor(Color.gray.opacity(0.25))
                Rectangle()
                    .foregroundColor(.accentColor)
                    .frame(width: geo.size.width * CGFloat(min(max(value, 0), 1)))
            }
        }
        .frame(height: 6)
        .cornerRadius(3)
    }
}

// MARK: - HTTP Code Helper

private func httpCodeLabel(_ code: Int) -> String {
    switch code {
    case 200: return "\(code) OK"
    case 201: return "\(code) Created"
    case 204: return "\(code) No Content"
    case 301: return "\(code) Moved"
    case 302: return "\(code) Found"
    case 304: return "\(code) Not Modified"
    case 400: return "\(code) Bad Req"
    case 401: return "\(code) Unauth"
    case 403: return "\(code) Forbidden"
    case 404: return "\(code) Not Found"
    case 405: return "\(code) Not Allowed"
    case 408: return "\(code) Timeout"
    case 410: return "\(code) Gone"
    case 415: return "\(code) Bad Media"
    case 429: return "\(code) Too Many"
    case 500: return "\(code) Server Err"
    case 502: return "\(code) Bad GW"
    case 503: return "\(code) Unavail"
    case 504: return "\(code) GW Timeout"
    default:
        if code < 300 { return "\(code) OK" }
        if code < 400 { return "\(code) Redirect" }
        if code < 500 { return "\(code) Client Err" }
        return "\(code) Server Err"
    }
}

private func httpCodeColor(_ code: Int) -> NSColor {
    if code < 300 { return .systemGreen }
    if code < 400 { return .systemYellow }
    if code < 500 { return .systemOrange }
    return .systemRed
}

// MARK: - Clickable Link

private class ClickableLinkField: NSTextField {
    var linkURL: URL?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 1, let url = linkURL {
            NSWorkspace.shared.open(url)
        } else {
            super.mouseDown(with: event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

struct ClickableText: NSViewRepresentable {
    let text: String
    let url: URL?
    var font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular)
    var color: NSColor = .linkColor

    func makeNSView(context: Context) -> NSTextField {
        let field = ClickableLinkField(labelWithString: text)
        field.linkURL = url
        field.isSelectable = true
        field.isEditable = false
        field.drawsBackground = false
        field.isBordered = false
        field.lineBreakMode = .byTruncatingTail
        field.font = font
        field.textColor = color
        field.setContentHuggingPriority(.defaultHigh, for: .vertical)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        nsView.stringValue = text
        nsView.font = font
        nsView.textColor = color
        (nsView as? ClickableLinkField)?.linkURL = url
    }
}

// MARK: - Resizable Table View

class ResultsTableDelegate: NSObject, NSTableViewDelegate, NSTableViewDataSource {
    var results: [SiteResult] = []
    var sortedResults: [SiteResult] = []
    var showHTTPOnly = false

    func applySort(_ descriptors: [NSSortDescriptor]) {
        guard let desc = descriptors.first, let key = desc.key else {
            sortedResults = results
            return
        }
        let asc = desc.ascending
        sortedResults = results.sorted { a, b in
            let cmp: Bool
            switch key {
            case "domain":
                cmp = a.domain.localizedCaseInsensitiveCompare(b.domain) == .orderedAscending
            case "status":
                cmp = (a.pingable ? 1 : 0) < (b.pingable ? 1 : 0)
            case "http":
                cmp = a.httpStatusCode < b.httpStatusCode
            case "type":
                func typeRank(_ r: SiteResult) -> Int {
                    r.isHTTPOnly ? 0 : r.redirectsToHTTPS ? 1 : 2
                }
                cmp = typeRank(a) < typeRank(b)
            case "https":
                cmp = (a.httpsAvailable ? 1 : 0) < (b.httpsAvailable ? 1 : 0)
            case "tag":
                cmp = (a.matchedTag ?? "~") < (b.matchedTag ?? "~")
            case "snippet":
                cmp = (a.matchedSnippet ?? "~") < (b.matchedSnippet ?? "~")
            case "ip":
                cmp = (a.pingIP ?? "~") < (b.pingIP ?? "~")
            case "latency":
                cmp = (a.pingLatencyMs ?? .infinity) < (b.pingLatencyMs ?? .infinity)
            default:
                cmp = false
            }
            return asc ? cmp : !cmp
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { sortedResults.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < sortedResults.count, let colID = tableColumn?.identifier.rawValue else { return nil }
        let result = sortedResults[row]

        switch colID {
        case "domain":
            let field = ClickableLinkField(labelWithString: "http://\(result.domain)")
            field.linkURL = URL(string: "http://\(result.domain)")
            field.isSelectable = true
            field.isEditable = false
            field.drawsBackground = false
            field.isBordered = false
            field.lineBreakMode = .byTruncatingTail
            field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            field.textColor = .linkColor
            return field
        case "status":
            return makeLabel(result.pingable ? "UP" : "DOWN",
                             font: .monospacedSystemFont(ofSize: 11, weight: .bold),
                             color: result.pingable ? .systemGreen : .systemRed,
                             alignment: .center)
        case "http":
            return makeLabel(httpCodeLabel(result.httpStatusCode),
                             font: .monospacedSystemFont(ofSize: 11, weight: .regular),
                             color: httpCodeColor(result.httpStatusCode))
        case "type":
            let text = result.isHTTPOnly ? "HTTP Only" : result.redirectsToHTTPS ? "Redirects" : "HTTP+HTTPS"
            let color: NSColor = result.isHTTPOnly ? .systemOrange : result.redirectsToHTTPS ? .systemBlue : .secondaryLabelColor
            let font: NSFont = result.isHTTPOnly ? .monospacedSystemFont(ofSize: 11, weight: .semibold) : .systemFont(ofSize: 11)
            return makeLabel(text, font: font, color: color)
        case "https":
            let text = result.httpsAvailable ? "Yes" : "No"
            let color: NSColor = result.httpsAvailable ? .systemGreen : .secondaryLabelColor
            return makeLabel(text, font: .systemFont(ofSize: 11, weight: .medium), color: color, alignment: .center)
        case "tag":
            return makeLabel(result.matchedTag ?? "-",
                             color: result.matchedTag != nil ? .systemPurple : .tertiaryLabelColor,
                             alignment: .center)
        case "snippet":
            if let snippet = result.matchedSnippet {
                let field = ClickableLinkField(labelWithString: snippet)
                field.linkURL = URL(string: "http://\(result.domain)")
                field.isSelectable = true
                field.isEditable = false
                field.drawsBackground = false
                field.isBordered = false
                field.lineBreakMode = .byTruncatingTail
                field.font = .systemFont(ofSize: 11)
                field.textColor = .linkColor
                return field
            }
            return makeLabel("-", color: .tertiaryLabelColor)
        case "ip":
            return makeLabel(result.pingIP ?? "-",
                             font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                             color: result.pingIP != nil ? .labelColor : .tertiaryLabelColor)
        case "latency":
            return makeLabel(result.pingLatencyMs.map { String(format: "%.0f", $0) + "ms" } ?? "-",
                             font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                             color: result.pingLatencyMs != nil ? .secondaryLabelColor : .tertiaryLabelColor,
                             alignment: .right)
        default:
            return nil
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 22 }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        applySort(tableView.sortDescriptors)
        tableView.reloadData()
    }

    private func makeLabel(_ text: String, font: NSFont = .systemFont(ofSize: 12), color: NSColor = .labelColor, alignment: NSTextAlignment = .left) -> NSTextField {
        let field = ScrollPassthroughTextField(labelWithString: text)
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
    let results: [SiteResult]
    let showHTTPOnly: Bool

    func makeCoordinator() -> ResultsTableDelegate {
        ResultsTableDelegate()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true

        let tableView = NSTableView()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.allowsColumnResizing = true
        tableView.allowsColumnReordering = false
        tableView.intercellSpacing = NSSize(width: 6, height: 2)
        tableView.rowHeight = 22

        addColumns(to: tableView, showHTTPOnly: showHTTPOnly)

        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator

        scrollView.documentView = tableView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tableView = scrollView.documentView as? NSTableView else { return }

        let httpsCol = tableView.tableColumns.first { $0.identifier.rawValue == "https" }
        if showHTTPOnly && httpsCol == nil {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("https"))
            col.title = "HTTPS?"
            col.width = 52
            col.minWidth = 40
            col.maxWidth = 100
            col.sortDescriptorPrototype = NSSortDescriptor(key: "https", ascending: true)
            let typeIndex = tableView.tableColumns.firstIndex { $0.identifier.rawValue == "type" } ?? 3
            tableView.addTableColumn(col)
            tableView.moveColumn(tableView.column(withIdentifier: col.identifier), toColumn: typeIndex + 1)
        } else if !showHTTPOnly, let existing = httpsCol {
            tableView.removeTableColumn(existing)
        }

        context.coordinator.results = results
        context.coordinator.applySort(tableView.sortDescriptors)
        context.coordinator.showHTTPOnly = showHTTPOnly
        tableView.reloadData()
    }

    private func addColumns(to tableView: NSTableView, showHTTPOnly: Bool) {
        let cols: [(id: String, title: String, width: CGFloat, min: CGFloat, max: CGFloat)] = [
            ("domain",  "Domain",     220, 120, 600),
            ("status",  "Status",      46,  36,  80),
            ("http",    "HTTP",        90,  60, 150),
            ("type",    "Type",        80,  55, 140),
            ("tag",     "Tag",         70,  40, 140),
            ("snippet", "Snippet",    200, 100, 800),
            ("ip",      "IP Address", 115,  80, 180),
            ("latency", "Latency",     55,  40, 100),
        ]
        for c in cols {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(c.id))
            col.title = c.title
            col.width = c.width
            col.minWidth = c.min
            col.maxWidth = c.max
            col.sortDescriptorPrototype = NSSortDescriptor(key: c.id, ascending: true)
            tableView.addTableColumn(col)
        }

        if showHTTPOnly {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("https"))
            col.title = "HTTPS?"
            col.width = 52
            col.minWidth = 40
            col.maxWidth = 100
            col.sortDescriptorPrototype = NSSortDescriptor(key: "https", ascending: true)
            let typeIndex = tableView.tableColumns.firstIndex { $0.identifier.rawValue == "type" } ?? 3
            tableView.addTableColumn(col)
            tableView.moveColumn(tableView.column(withIdentifier: col.identifier), toColumn: typeIndex + 1)
        }
    }
}

// MARK: - Main View

struct ContentView: View {
    @ObservedObject private var vm = ScannerViewModel()

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 210)
                .padding()

            Divider()

            VStack(spacing: 0) {
                searchBar
                    .padding(.horizontal)
                    .padding(.vertical, 10)

                Divider()

                resultsArea

                Divider()

                statusBar
                    .padding(.horizontal)
                    .padding(.vertical, 8)
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if vm.isScanning {
                    Button(action: vm.stopScan) {
                        Text("Stop")
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity)
                    }
                }

                Button(action: vm.clearResults) {
                    Text("Clear All")
                        .frame(maxWidth: .infinity)
                }
                .disabled(vm.isScanning || vm.results.isEmpty)

                Divider()

                Text("Display")
                    .font(.headline)

                Toggle("HTTP-Only results", isOn: $vm.showHTTPOnly)

                Divider()

                Text("Tor Proxy")
                    .font(.headline)

                Toggle("Use Tor (SOCKS5)", isOn: Binding(
                    get: { vm.useTor },
                    set: { _ in vm.toggleTor() }
                ))
                .disabled(vm.isScanning)

                if !vm.torStatus.isEmpty {
                    Text(vm.torStatus)
                        .font(.caption)
                        .foregroundColor(vm.torStatus.hasPrefix("Connected") ? .green : .orange)
                }

                if !vm.useTor && vm.torChecked {
                    Button(action: vm.connectTor) {
                        Text("Connect")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(vm.torStatus == "Starting...")
                }

                Spacer(minLength: 20)

                Button(action: vm.exportResults) {
                    Text("Export Results")
                        .frame(maxWidth: .infinity)
                }
                .disabled(vm.filteredResults.isEmpty)
            }
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Text("Search:")
                .foregroundColor(.secondary)

            TextField("keywords (e.g. weather news shop)",
                      text: $vm.searchQuery,
                      onCommit: vm.startSearch)
                .textFieldStyle(RoundedBorderTextFieldStyle())

            Button("Search", action: vm.startSearch)
                .disabled(vm.isScanning || vm.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    // MARK: - Results

    private var resultsArea: some View {
        VStack(spacing: 0) {
            if vm.filteredResults.isEmpty && !vm.isScanning {
                Spacer()
                Text("No Results")
                    .font(.title)
                    .foregroundColor(.secondary)
                Text("Enter keywords above to find HTTP sites.")
                    .font(.caption)
                    .foregroundColor(Color.secondary.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
                Spacer()
            } else {
                ResultsTableView(results: vm.filteredResults, showHTTPOnly: vm.showHTTPOnly)
            }
        }
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack(spacing: 12) {
            if vm.isScanning {
                ProgressBar(value: vm.progress)
                    .frame(width: 140)
            }

            Text(vm.statusMessage)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)

            Spacer()

            if !vm.results.isEmpty {
                Text("Results: \(vm.filteredResults.count)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(Color.gray.opacity(0.2))
                    )
            }
        }
    }
}
