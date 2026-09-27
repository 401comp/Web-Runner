<p align="center">
  <img src="icon.png" width="200" alt="Web-Runner">
</p>

# Web-Runner

A macOS desktop app that discovers HTTP websites by keyword. Enter one or more search terms; Web-Runner generates candidate domains, fetches each over plain HTTP, and reports the ones whose URL, response headers, or page content match **all** of your keywords.

## Features

- **Multi-keyword search** -- space-separated terms; a site is reported only if every keyword matches
- **Matches everywhere** -- searches the domain, the HTTP response headers, and the stripped page text, and tells you which one hit
- **HTTP-Only filter** -- narrow results to sites with no HTTPS at all, with an extra "HTTPS?" column so you can confirm
- **Tor support** -- route traffic through a local SOCKS5 proxy, auto-detecting Tor on ports 9050 (standalone) and 9150 (Tor Browser); `.onion` domains work when enabled
- **Sortable, resizable columns** -- native `NSTableView`; click any header to sort, drag dividers to resize
- **Ping diagnostics** -- reachability, resolved IP, and round-trip latency per result
- **Page and response metadata** -- title, description, content type, server header, and redirect target from the existing HTTP response
- **Clickable results** -- domains and snippets open in your browser; all text is selectable
- **Fast repeat searches** -- successful probes and misses are kept in a separate, clearable 10-minute in-memory cache
- **Export** -- save results to a text file at a location you choose
- **Concurrent scanning** -- 25 parallel requests direct, throttled to 6 over Tor

## Columns

| Column | Meaning |
| --- | --- |
| Domain | Clickable link to the site |
| Title | Page title or Open Graph title |
| Description | Page description, Open Graph description, or cleaned page-text fallback |
| Status | UP or DOWN (ping reachability) |
| HTTP | Status code with a short description |
| Type | HTTP Only, Redirects, or HTTP+HTTPS |
| HTTPS? | Shown in HTTP-Only mode; whether HTTPS exists |
| Content Type | Response media type |
| Server | Web server header, when exposed |
| Redirect Target | `Location` header destination, when present |
| Tag | Where the keyword matched (url, header, content) |
| Snippet | Context around the match |
| IP | Resolved IP address |
| Latency | Ping round-trip time in ms |

## Requirements

macOS 10.15 Catalina or later. Tor is optional -- install with `brew install tor` if you want proxy support.

## Building

```bash
cd Web-Runner
./build.sh
```

This compiles in release mode, assembles `dist/Web-Runner.app`, embeds the Swift concurrency back-deploy runtime, ad-hoc signs, and produces both `dist/Web-Runner.dmg` and the self-contained `dist/Web-Runner.zip`.

On a machine with full Xcode installed you can build a universal binary:

```bash
UNIVERSAL=1 ./build.sh
```

### Note on Catalina support

The app uses Swift `async`/`await`, whose runtime (`libswift_Concurrency.dylib`) ships inside macOS 12 and later but **does not exist on 10.15**. `build.sh` bundles the back-deploy copy of that dylib into `Contents/Frameworks/` and adds an `@executable_path/../Frameworks` rpath. Without this the app launches and then immediately dies on Catalina -- do not remove that step.

## Installation

Open `dist/Web-Runner.dmg` and drag the app to your Applications folder, or unzip `dist/Web-Runner.zip` and move the contained app to Applications.

## Usage

1. Type one or more keywords in the search bar (space-separated).
2. Press Return or click **Search**.
3. Click column headers to sort; toggle **HTTP-Only results** to filter.
4. **Clear Search Cache** forces subsequent searches to re-probe every domain; the cache otherwise expires after 10 minutes.
5. **Export Results** saves the current (filtered) view to a text file with full result columns followed by a URL-only section.

Help is available in-app under **Help > Web-Runner Help** (⌘?).

## How It Works

For each candidate domain the app:

1. Sends an HTTP request without following redirects
2. Searches the domain, response headers, and stripped page text for all keywords
3. Checks whether HTTPS is available and pings the host, in parallel
4. Reports the result only if every keyword matched

Recent probe results—including non-resolving domains—are cached in memory for
10 minutes. The cache is keyed by domain, search terms, and whether Tor is in
use, and can be cleared from the sidebar at any time.

## License

MIT

See `LICENSE` for the full text.
