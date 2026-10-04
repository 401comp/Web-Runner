<p align="center">
  <img src="icon.png" width="200" alt="Web-Runner">
</p>

# Web-Runner

A lightweight macOS search utility for surface-web results and image results.

## Features

- **Web and image search** -- surface-web searches use Bing, Brave, and DuckDuckGo; image results appear in an in-app grid.
- **Reliable image grid** -- thumbnails use an in-memory cache, eight-at-a-time loading, referrer retry, and full-image fallback when a thumbnail host fails.
- **Copy image links** -- image cards copy their source-page URL to the clipboard without opening a browser.
- **Verified HTTP-only mode** -- directly checks generated candidates and shows only sites that respond over HTTP without HTTPS.
- **Optional Tor proxy** -- route ordinary surface-web and image requests through a local SOCKS5 proxy on port 9050 or 9150.
- **Cache controls** -- recent result sets are held in memory for 10 minutes; the sidebar shows image-cache size in MB, clears both caches manually, and clears image data again on app quit.
- **Network status** -- shows whether macOS reports a VPN/tunnel interface and the current public IP address.
- **Exports** -- save visible web results as text or browser-compatible Netscape bookmark HTML with canonical URL de-duplication.
- **Native result table** -- sortable, resizable URL, title, source, and protocol columns.

Web-Runner searches the ordinary web only. It does not query, crawl, or return `.onion` services.

## Search Sources and Data

- **Web results** come directly from Bing, Brave Search, and DuckDuckGo. Web-Runner combines and de-duplicates the links those providers return; it does not maintain its own search index.
- **Image results** are discovered through Bing Images. Each grid tile loads its thumbnail directly from the returned image host, using the result page as its referrer when needed; the original image URL is used as a fallback.
- **Local data** is temporary. Search results and image thumbnails are held only in memory for the current app session; they are not uploaded to a Web-Runner service or saved as a persistent browsing history.

## Requirements

- macOS 10.15 Catalina or later
- Tor is optional. Install or run a local SOCKS5 service only when you want proxy routing.

## Building

```bash
./build.sh
```

The build creates:

- `dist/Web-Runner.app`
- `dist/Web-Runner.dmg`
- `dist/Web-Runner-<version>-macos.zip`

The app bundle includes `libswift_Concurrency.dylib` for Catalina compatibility and is ad-hoc signed during packaging. Set `UNIVERSAL=1` on a machine with full Xcode to produce a universal build.

## Network Routing

Web-Runner does not create, disable, or bypass a VPN. With the Tor proxy disabled, requests use macOS's normal network route, including a full-tunnel VPN when one is active. With the proxy enabled, requests first go to the local SOCKS5 service; Tor's outbound connection then follows the Mac's normal route.

## License

MIT. See `LICENSE`.
