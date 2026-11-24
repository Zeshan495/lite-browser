# LiteBrowser

A small, fast browser with **Google** as its search engine, a branded home page with your top sites, and smart fixes for DNS errors (the ones Chrome shows as `DNS_PROBE_POSSIBLE`).

| | Mac | Android |
|---|---|---|
| Engine | Apple WebKit (built into macOS) | Android System WebView |
| Size | ~1 MB | ~1 MB APK |
| Install | `brew install Zeshan495/tap/lite-browser` | APK from [Releases](../../releases/latest) |

## Install

**Mac** (Terminal, needs [Homebrew](https://brew.sh)):

```bash
brew install Zeshan495/tap/lite-browser
litebrowser
```

**Android:** open the [latest release](../../releases/latest) on your phone, download `LiteBrowser-x.y.z.apk`, open it and allow "Install unknown apps" if asked.

**Build it yourself on a Mac:** `./install.sh` (installs through Homebrew from this folder) or `make run`.

**Publish your own copy on GitHub:** see [docs/PUBLISHING.md](docs/PUBLISHING.md). It's one command: `./scripts/publish.sh`.

## Android app

- Modern mobile layout: rounded address bar on top, and back, forward, home, tabs and menu at the bottom within thumb reach
- Tab switcher with page previews, a menu sheet that slides up with an icon grid, a full-screen History page with search, and find in page

- Same home page as the Mac app, with the clock, a search box and top sites
- Tabs, history, search history, and clear browsing data
- Smart error pages: works out whether your DNS, your network or the site is the problem, and opens Android's **Private DNS** setting when DNS is to blame (you can enter a hostname like `love.dns.zeshanhaider.dev` there)
- Downloads, file uploads, full-screen video, desktop site mode, sharing
- Can be set as your default browser

## PIN lock (Mac and Android)

Turn it on in **Settings → PIN Lock** on Mac, or **Menu → App lock** on Android. LiteBrowser then asks for a 4–10 digit PIN every time it opens. On Mac it also asks after the Mac wakes from sleep, or when you press ⌃⌘L. On Android it also asks when you come back after more than a minute away.

**If a wrong PIN is entered 2 times in a row, LiteBrowser erases everything** (history, searches, sign-ins and cookies, site data, open tabs, the downloads list and all settings including the PIN) and starts fresh like a new install. Downloaded files are kept. The PIN is stored only as a salted PBKDF2 hash, and a forgotten PIN can't be recovered.

## Mac app

- **Smart address bar:** shows Google suggestions and matching pages from your history as you type, and autocompletes sites you visit (type `git` → `github.com`). Use the arrow keys and Enter to pick one.
- **Find on page:** ⌘F, with ⌘G / ⇧⌘G for next and previous

## Usage

```bash
litebrowser                     # opens Google
litebrowser github.com          # opens a site
litebrowser best biryani karachi   # searches Google
```

| Shortcut | Action |
|---|---|
| ⌘T / ⌘N | New tab / new window |
| ⇧⌘T | Reopen the last closed tab |
| ⌘1 … ⌘8 / ⌘9 | Jump to that tab / the last tab |
| ⌃Tab / ⌃⇧Tab or ⇧⌘] / ⇧⌘[ | Next / previous tab |
| ⇧⌘W | Close window |
| ⌘W | Close tab |
| ⌘L | Focus the address bar (type a URL or Google search) |
| ⌘R | Reload |
| ⌘[ / ⌘] | Back / forward |
| ⌘= / ⌘- / ⌘0 | Zoom |
| ⌘-click | Open link in background tab |
| ⌘, | Settings |
| ⌘Y / ⇧⌘Y | Show history / search history |
| ⇧⌘⌫ | Clear browsing data |

## Staying signed in

Logins (Google, Gmail, YouTube, GitHub and others) are saved on disk, the same way Safari saves them. They survive quitting the app, restarting the Mac and running `brew upgrade`. They're removed only by **Clear Browsing Data** (and only for sites you didn't choose to keep), by signing out on the site, or when the site's own login expires.

## Settings (⌘,)

- **History:** every page you visit, grouped by day, with a search box. Click a page to reopen it, or × to remove it. The History menu also lists your 15 most recent pages.
- **Searches:** your Google searches. Click one to search again, × to remove one, or clear them all.
- **Clear Data:** tick what to delete (history, searches, cookies and sign-ins, cache). The **Keep these sites signed in** list shows every site that has saved data. Tick the ones that should stay logged in, such as Gmail or GitHub, and everything else gets cleared. Your choices are remembered. Ticking Google also keeps YouTube and Gmail.
- **DNS:** shows which DNS servers your Mac is using. Pick a provider (Cloudflare, Google, Quad9, AdGuard ad-blocking, Cloudflare Family, OpenDNS) or type your own. **Test Speed** measures each server, and **Save & Use on This Mac** applies them system-wide.
  - **IP addresses** (`1.1.1.1`) are applied with your admin password.
  - **A secure DNS hostname** (`love.dns.example.dev`, the kind Android calls "Private DNS") uses DNS-over-TLS. A full `https://…/dns-query` address uses DNS-over-HTTPS. macOS only accepts these through a configuration profile. LiteBrowser creates `~/Downloads/LiteBrowser-DNS.mobileconfig` and opens System Settings. There you approve it under **Privacy & Security › Profiles** (older macOS: **General › Device Management**). **Reset to Automatic** removes it again.

History is stored in `~/Library/Application Support/LiteBrowser/history.json`.

## How DNS errors are handled

When a page fails because a site name can't be resolved:

1. **Silent retries.** The page is retried 3 times with backoff (0.75s, 1.5s, 3s). This hides most temporary DNS and Wi-Fi hiccups.
2. **Diagnosis.** If the retries also fail, LiteBrowser asks Cloudflare (`1.1.1.1`) and Google (`8.8.8.8`) directly over HTTPS, using their IP addresses. These lookups still work when your own DNS server is broken. The result decides which page you see:
   - **Site exists → "Your network's DNS isn't answering"**, with a **Fix DNS automatically** button. The button sets every network interface to Cloudflare and Google DNS and flushes the macOS DNS cache. macOS asks for your admin password first. The page then reloads.
   - **Site doesn't exist → "That site doesn't exist"**, with a **Search Google** button.
   - **No internet → "You're offline"**. This page reloads by itself when your connection comes back.
3. **Network menu:** *Fix DNS* and *Reset DNS to Automatic* (undo) are always available here.

No browser can load pages without a working internet connection. What LiteBrowser does is fix the most common cause of `DNS_PROBE_*` errors (a broken or slow DNS server from your ISP or router) and handle the rest without dead-end error screens.

## Build manually

```bash
make run        # build into build/LiteBrowser.app and launch it
make install    # copy to /Applications
```
