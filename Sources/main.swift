import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var helpWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        setupMenuBar()

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Web-Runner"
        window.minSize = NSSize(width: 1140, height: 520)
        window.contentView = NSHostingView(rootView: ContentView())
        window.center()
        window.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func setupMenuBar() {
        let mainMenu = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Web-Runner", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Web-Runner", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(withTitle: "Web-Runner Help", action: #selector(showHelp(_:)), keyEquivalent: "?")
        let helpMenuItem = NSMenuItem()
        helpMenuItem.submenu = helpMenu
        mainMenu.addItem(helpMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func showHelp(_ sender: Any?) {
        if let w = helpWindow, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            return
        }

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = "Web-Runner Help"
        w.isReleasedWhenClosed = false

        let scroll = NSScrollView(frame: w.contentView!.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true

        let textView = NSTextView(frame: scroll.contentView.bounds)
        textView.autoresizingMask = [.width]
        textView.isEditable = false
        textView.isSelectable = true
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.font = .systemFont(ofSize: 13)

        let readme = """
        Web-Runner
        ==========

        A macOS app that discovers HTTP websites by keyword.

        HOW TO USE
        ----------
        1. Type one or more keywords in the search bar (space-separated).
        2. Press Return or click Search.
        3. The app generates candidate domain names from your keywords,
           fetches each one over HTTP, and checks the URL, headers,
           and page content for your keywords.
        4. Only sites where ALL keywords match are shown.

        COLUMNS
        -------
        • Domain    — clickable link to the site
        • Title     — page title or Open Graph title
        • Description — page description, Open Graph description, or page-text fallback
        • Status    — UP or DOWN (ping reachability)
        • HTTP      — HTTP status code with short description
        • Type      — HTTP Only, Redirects to HTTPS, or HTTP+HTTPS
        • HTTPS?    — appears in HTTP-Only mode; shows if HTTPS exists
        • Content Type — response media type
        • Server    — web server header, when exposed
        • Redirect Target — Location header destination, when present
        • Tag       — where the keyword matched (url, header, content)
        • Snippet   — context around the match (clickable)
        • IP        — resolved IP address
        • Latency   — ping round-trip time in ms

        Columns are resizable — drag the dividers in the header.

        SIDEBAR
        -------
        • Stop / Clear All — control scanning
        • Clear Search Cache — discard the recent (10-minute) probe cache
        • HTTP-Only results — filter to sites without HTTPS
        • Tor Proxy — route ordinary scan requests through Tor (SOCKS5)
        • Export Results — save to a file you choose

        TOR PROXY
        ---------
        Toggle "Use Tor" to route ordinary HTTP and HTTPS scan requests
        through a local Tor SOCKS5 proxy. The app auto-detects ports 9050
        (standalone) and 9150 (Tor Browser). This is a proxy setting only.

        KEYBOARD SHORTCUTS
        ------------------
        ⌘Q  Quit
        ⌘C  Copy
        ⌘V  Paste
        ⌘X  Cut
        ⌘A  Select All
        ⌘?  This help window

        REQUIREMENTS
        ------------
        macOS 10.15 Catalina or later.
        """

        textView.string = readme
        scroll.documentView = textView
        w.contentView = scroll
        w.center()
        w.makeKeyAndOrderFront(nil)
        helpWindow = w
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
