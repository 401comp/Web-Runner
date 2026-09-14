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
- **Clickable results** -- domains and snippets open in your browser; all text is selectable
- **Export** -- save results to a text file at a location you choose
- **Concurrent scanning** -- 25 parallel requests direct, throttled to 6 over Tor

## Columns

| Column | Meaning |
| --- | --- |
| Domain | Clickable link to the site |
| Status | UP or DOWN (ping reachability) |
| HTTP | Status code with a short description |
| Type | HTTP Only, Redirects, or HTTP+HTTPS |
| HTTPS? | Shown in HTTP-Only mode; whether HTTPS exists |
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

This compiles in release mode, assembles `dist/Web-Runner.app`, embeds the Swift concurrency back-deploy runtime, ad-hoc signs, and produces `dist/Web-Runner.dmg`.

On a machine with full Xcode installed you can build a universal binary:

```bash
UNIVERSAL=1 ./build.sh
```

### Note on Catalina support

The app uses Swift `async`/`await`, whose runtime (`libswift_Concurrency.dylib`) ships inside macOS 12 and later but **does not exist on 10.15**. `build.sh` bundles the back-deploy copy of that dylib into `Contents/Frameworks/` and adds an `@executable_path/../Frameworks` rpath. Without this the app launches and then immediately dies on Catalina -- do not remove that step.

## Installation

Open `dist/Web-Runner.dmg` and drag the app to your Applications folder, or run it directly from the DMG.

## Usage

1. Type one or more keywords in the search bar (space-separated).
2. Press Return or click **Search**.
3. Click column headers to sort; toggle **HTTP-Only results** to filter.
4. **Export Results** saves the current (filtered) view to a text file.

Help is available in-app under **Help > Web-Runner Help** (⌘?).

## How It Works

For each candidate domain the app:

1. Sends an HTTP request without following redirects
2. Searches the domain, response headers, and stripped page text for all keywords
3. Checks whether HTTPS is available and pings the host, in parallel
4. Reports the result only if every keyword matched

## License

MIT
