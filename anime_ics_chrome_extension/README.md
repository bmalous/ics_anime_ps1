# Anime ICS Provider Search for Chrome

This unpacked Chrome extension searches for a show or exports weekly bookmarks from either anime_ics script. It reads the clipboard only when you open its popup.

## Requirements

- Google Chrome 109 or later.
- The extension files in this folder.
- A show copied with **C** from the script's **Airing this week** view.
- Weekly bookmarks copied from the script's main menu.

## Install

1. Open `chrome://extensions` in Chrome.
2. Turn on **Developer mode**.
3. Click **Load unpacked**.
4. Select this `prime-video-clipboard-search` folder.
5. Open Chrome's Extensions menu and pin **Anime ICS Provider Search** to the toolbar.

The extension is loaded locally; it is not installed from the Chrome Web Store. After changing its files, return to `chrome://extensions` and click **Reload** on the extension card.

## Search a show or change channel settings

1. Open **Airing this week** in the PowerShell or Python script.
2. Highlight a show and press **C**. The script copies a compact `AICS1:` payload with the title and provider IDs.
3. Click the extension's pinned toolbar button. It searches Google, Bing, DuckDuckGo, and Yahoo in rotating order, skips blocked engines and sponsored results, then opens the first eligible result on the selected provider's site. Google, Bing, and Yahoo may show robot checks; the extension moves on when an engine is blocked.

When the clipboard does not contain a valid search title, the popup shows channel settings. Select a provider under **Prime Channels** or **YouTube Channels**; selecting an overlapping provider clears its checkmark in the other group. Choices are saved in Chrome. The extension validates the `AICS1:` marker and payload, searches the configured provider domain across multiple engines, opens an eligible organic result, and then clears the clipboard. A Prime/YouTube route is used only when that channel is selected; with its checkbox off, lookup uses the provider's own site. Native HIDIVE searches use `site:www.hidive.com/season` and only accept `/season/` page paths, excluding news subdomains and news pages.

## Export weekly bookmarks

In **Airing this week**, press **E** to copy the `AICB1:` schedule payload, then open the extension popup. The extension creates Monday-through-Sunday folders with airtime-ordered links and downloads `anime-airing-this-week-bookmarks.html`; days with no selected shows are omitted. It alternates Google, Bing, DuckDuckGo, and Yahoo as the first engine for each unique show, then tries the remaining engines if one is blocked or has no eligible result. It closes temporary search tabs, skips sponsored/ad results, and writes the first organic result on the provider's domain into the HTML file. Your configured Prime/YouTube channel choice sets the site domain.

**Bookmark creation is intentionally slow.** It searches engines one at a time and pauses between shows to reduce search-engine rate limits and robot checks. A large weekly list can take several minutes, especially when the engines block or fail to return a matching provider page. Shows without an eligible result are omitted, and no file is downloaded if none are found. Import the downloaded HTML from Chrome's Bookmarks menu. Reload the updated unpacked extension and allow its search engine site permissions.

## Prime Video and YouTube channels

When there is no search title on the clipboard, click the extension button to open channel settings. Crunchyroll is available in both groups; HIDIVE is currently listed under Prime Channels. Select a provider to route searches through that channel. For providers listed in both groups, selecting one automatically clears it from the other, so only one channel route is active. If neither is selected, searches use the provider's usual route. Channel availability depends on your region. [Crunchyroll availability through YouTube Primetime](https://help.crunchyroll.com/hc/en-us/articles/31077916133396-How-do-I-watch-Crunchyroll-on-YouTube-Primetime) varies by country.

## Files

- [`manifest.json`](manifest.json): Manifest V3 metadata, toolbar popup, Chrome 109 minimum, clipboard/download/storage/tab/script permissions, and search-engine host access for bookmark resolution.
- [`popup.html`](popup.html): popup layout and status messages.
- [`popup.js`](popup.js): clipboard reading, payload validation, channel settings, multi-engine result resolution, bookmark generation, and error reporting.
- [`providers.json`](providers.json): provider IDs, names, websites, native search routes, and Prime/YouTube channel availability.
- [`icon.png`](icon.png): extension toolbar icon.

## Troubleshooting

- **Invalid search:** copy a show again with **C** from Airing this week, then reopen the extension.
- **No supported provider:** the script's payload did not include a provider ID recognized in `providers.json`.
- **Popup or clipboard failure:** open the extension popup, then inspect the extension's service worker and popup consoles at `chrome://extensions`. Popup failures are also saved in Chrome extension storage as `lastClipboardSearchError`.
- **Changed extension files do not appear:** click **Reload** on the extension card at `chrome://extensions`.

## Related guides

- [PowerShell script guide](../README.md)
- [Python script guide](../../Ics_anime_py/README.md)
