const status = document.getElementById("status");
const channelList = document.getElementById("channels");
const providerList = document.getElementById("providers");
const providerSection = document.getElementById("provider-section");
const CLIPBOARD_MARKER = "AICS1:";
const BOOKMARKS_MARKER = "AICB1:";
const CHANNELS = [
  { title: "Prime Channels", flag: "primeChannel", key: "primeChannelProviders" },
  { title: "YouTube Channels", flag: "youtubeChannel", key: "youtubeChannelProviders" }
];
let allProviders = [];
let primeChannels = new Set();
let youtubeChannels = new Set();
let searchEngineIndex = 0;

async function recordFailure(error, method) {
  const entry = {
    time: new Date().toISOString(), method,
    name: error?.name || "Error", message: error?.message || String(error), stack: error?.stack || ""
  };
  console.error("Anime calendar clipboard search failed:", entry);
  try { await chrome.storage.local.set({ lastClipboardSearchError: entry }); }
  catch (storageError) { console.error("Could not save clipboard search error:", storageError); }
}

function parseAnimePayload(text) {
  if (!text.startsWith(CLIPBOARD_MARKER)) return null;
  try {
    const payload = JSON.parse(text.slice(CLIPBOARD_MARKER.length));
    if (typeof payload?.t !== "string" || !payload.t.trim() || !Array.isArray(payload.p)) return null;
    return { title: payload.t.trim(), providers: [...new Set(payload.p.filter((id) => typeof id === "string"))] };
  } catch { return null; }
}

function selectedChannel(provider) {
  if (youtubeChannels.has(provider.id) && provider.youtubeChannel) return "youtube";
  if (primeChannels.has(provider.id) && provider.primeChannel) return "prime";
  return null;
}

function renderChannels() {
  channelList.replaceChildren();
  for (const channel of CHANNELS) {
    const group = document.createElement("div");
    group.className = "channel-group";
    const heading = document.createElement("strong");
    heading.textContent = channel.title;
    group.appendChild(heading);
    for (const provider of allProviders.filter((item) => item[channel.flag]).sort((a, b) => a.name.localeCompare(b.name))) {
      const label = document.createElement("label");
      const checkbox = document.createElement("input");
      checkbox.type = "checkbox";
      checkbox.checked = (channel.key === "primeChannelProviders" ? primeChannels : youtubeChannels).has(provider.id);
      checkbox.addEventListener("change", async () => {
        const current = channel.key === "primeChannelProviders" ? primeChannels : youtubeChannels;
        const other = channel.key === "primeChannelProviders" ? youtubeChannels : primeChannels;
        if (checkbox.checked) { current.add(provider.id); other.delete(provider.id); }
        else current.delete(provider.id);
        await chrome.storage.local.set({
          primeChannelProviders: [...primeChannels],
          youtubeChannelProviders: [...youtubeChannels]
        });
        renderChannels();
      });
      label.append(checkbox, document.createTextNode(provider.name));
      group.appendChild(label);
    }
    channelList.appendChild(group);
  }
}

async function searchProvider(title, provider, channel = null) {
  const url = providerSearchUrl(title, provider, channel);
  const tab = await chrome.tabs.create({ url: url.toString(), active: false });
  try {
    await navigator.clipboard.writeText("");
  } catch (error) {
    const textarea = document.createElement("textarea");
    textarea.value = "";
    textarea.setAttribute("readonly", "");
    textarea.style.cssText = "position:fixed;left:-10000px;top:0";
    document.body.appendChild(textarea);
    textarea.select();
    const cleared = document.execCommand("copy");
    textarea.remove();
    if (!cleared) console.warn("Search opened, but the clipboard could not be cleared:", error);
  }
  await chrome.tabs.update(tab.id, { active: true });
  await chrome.storage.local.remove("lastClipboardSearchError");
  window.close();
}

async function openResolvedProviderPage(url) {
  const tab = await chrome.tabs.create({ url, active: false });
  try {
    await navigator.clipboard.writeText("");
  } catch (error) {
    const textarea = document.createElement("textarea");
    textarea.value = "";
    textarea.setAttribute("readonly", "");
    textarea.style.cssText = "position:fixed;left:-10000px;top:0";
    document.body.appendChild(textarea);
    textarea.select();
    const cleared = document.execCommand("copy");
    textarea.remove();
    if (!cleared) console.warn("Page opened, but the clipboard could not be cleared:", error);
  }
  await chrome.tabs.update(tab.id, { active: true });
  await chrome.storage.local.remove("lastClipboardSearchError");
  window.close();
}

function providerSearchUrl(title, provider, channel = null) {
  if (channel === "youtube") {
    provider = { url: "https://www.youtube.com/", searchPath: "/results", queryParam: "search_query" };
  } else if (channel === "prime") {
    provider = { url: "https://www.primevideo.com/", searchPath: "/search/", queryParam: "phrase" };
  }
  let url;
  if (provider.searchPath && provider.queryParam) {
    url = new URL(provider.searchPath, provider.url);
    url.searchParams.set(provider.queryParam, title);
  } else {
    url = new URL("https://www.google.com/search");
    url.searchParams.set("q", `site:${new URL(provider.url).hostname} ${title}`);
  }
  return url;
}

function parseBookmarkPayload(text) {
  if (!text.startsWith(BOOKMARKS_MARKER)) return null;
  try {
    const payload = JSON.parse(text.slice(BOOKMARKS_MARKER.length));
    if (!Array.isArray(payload?.days)) return null;
    return payload.days.filter((day) => typeof day?.day === "string" && Array.isArray(day.shows));
  } catch { return null; }
}

function bookmarkProvider(show) {
  const providers = show.p.map((id) => allProviders.find((item) => item.id === id)).filter(Boolean);
  if (!providers.length) return null;
  const configured = providers.find((provider) => selectedChannel(provider));
  const provider = configured || providers.find((item) => item.id !== "PV" && item.id !== "YT") || providers[0];
  const channel = configured ? selectedChannel(provider) : null;
  if (channel === "prime") return { provider, domain: "primevideo.com", searchScope: "primevideo.com" };
  if (channel === "youtube") return { provider, domain: "youtube.com", searchScope: "youtube.com" };
  const domain = new URL(provider.url).hostname.replace(/^www\./, "");
  return {
    provider, domain, searchScope: provider.searchScope || domain,
    resultPathPrefix: provider.resultPathPrefix || ""
  };
}

async function findFirstOrganicProviderUrl(title, domain, searchScope = domain, resultPathPrefix = "") {
  const engines = [
    { id: "google", base: "https://www.google.com/search", param: "q" },
    { id: "bing", base: "https://www.bing.com/search", param: "q" },
    { id: "duckduckgo", base: "https://duckduckgo.com/", param: "q" },
    { id: "yahoo", base: "https://search.yahoo.com/search", param: "p" }
  ];
  const first = searchEngineIndex;
  searchEngineIndex = (searchEngineIndex + 1) % engines.length;
  const candidateHosts = new Set();
  const failures = [];
  for (let offset = 0; offset < engines.length; offset++) {
    const engine = engines[(first + offset) % engines.length];
    const searchUrl = new URL(engine.base);
    searchUrl.searchParams.set(engine.param, `site:${searchScope} ${title}`);
    if (engine.id === "google") {
      searchUrl.searchParams.set("udm", "14");
      searchUrl.searchParams.set("num", "10");
    }
    let tab;
    try {
      tab = await chrome.tabs.create({ url: searchUrl.toString(), active: false });
      await waitForTabLoad(tab.id);
      const results = await chrome.scripting.executeScript({
        target: { tabId: tab.id }, func: extractFirstOrganicResult,
        args: [engine.id, domain, resultPathPrefix]
      });
      const result = results?.[0]?.result;
      for (const host of result?.candidateHosts || []) candidateHosts.add(host);
      if (result?.url) return result;
      if (result?.captcha) failures.push(`${engine.id}: verification page`);
      else failures.push(`${engine.id}: no eligible result`);
    } catch (error) {
      failures.push(`${engine.id}: ${error.message || error}`);
    } finally {
      if (tab?.id) await chrome.tabs.remove(tab.id).catch(() => {});
    }
    if (offset + 1 < engines.length) await new Promise((resolve) => setTimeout(resolve, 600));
  }
  throw new Error(`NO_RESULT: No eligible ${domain} page found. Search engines tried: ${failures.join("; ")}. Candidate hosts: ${[...candidateHosts].slice(0, 8).join(", ") || "none"}.`);
}

async function waitForTabLoad(tabId) {
  const current = await chrome.tabs.get(tabId);
  if (current.status === "complete") return;
  await new Promise((resolve, reject) => {
    let finished = false;
    const finish = (error) => {
      if (finished) return;
      finished = true;
      clearTimeout(timeout);
      chrome.tabs.onUpdated.removeListener(onUpdated);
      if (error) reject(error);
      else resolve();
    };
    const timeout = setTimeout(() => finish(new Error("Search engine timed out.")), 20000);
    const onUpdated = (updatedId, changeInfo) => {
      if (updatedId === tabId && changeInfo.status === "complete") finish();
    };
    chrome.tabs.onUpdated.addListener(onUpdated);
    chrome.tabs.get(tabId).then((tab) => {
      if (tab.status === "complete") finish();
    }).catch(finish);
  });
}

function extractFirstOrganicResult(engine, domain, resultPathPrefix = "") {
  if (location.pathname.startsWith("/sorry/")
    || document.querySelector('#captcha-form, #recaptcha, form[action*="sorry"]')
    || /are you a robot|unusual traffic|automated queries|verify you are human/i.test(document.body?.innerText || "")) {
    return { captcha: true };
  }
  function belongsToProvider(value) {
    try {
      const host = new URL(value).hostname.toLowerCase();
      const url = new URL(value);
      const target = domain.toLowerCase();
      const hostMatches = resultPathPrefix
        ? (host === target || host === `www.${target}`)
        : (host === target || host.endsWith(`.${target}`));
      return hostMatches
        && (!resultPathPrefix || url.pathname.startsWith(resultPathPrefix));
    } catch { return false; }
  }
  function destination(href) {
    try {
      const url = new URL(href, location.href);
      if (engine === "google") {
        if (/\/(aclk|pagead)\b/i.test(url.pathname)) return "";
        if (url.hostname === "www.google.com" && url.pathname === "/goto") return { url: url.href, googleUrl: url.href };
        if (url.hostname.endsWith("google.com") && url.pathname === "/url") {
          const destinationUrl = url.searchParams.get("q") || url.searchParams.get("url")
            || url.searchParams.get("uddg") || url.searchParams.get("adurl") || "";
          if (!destinationUrl) return "";
          const nested = new URL(destinationUrl, "https://www.google.com");
          if (nested.hostname === "www.google.com" && nested.pathname === "/goto") {
            return { url: nested.href, googleUrl: nested.href };
          }
          return { url: destinationUrl, googleUrl: "" };
        }
      }
      if (engine === "duckduckgo" && url.hostname.endsWith("duckduckgo.com") && url.pathname === "/l/") {
        return url.searchParams.get("uddg") || "";
      }
      if (engine === "yahoo" && url.hostname.endsWith("search.yahoo.com")) {
        const match = url.pathname.match(/\/RU=([^/]+)/i);
        if (match) { try { return decodeURIComponent(match[1]); } catch { return match[1]; } }
      }
      if (engine === "bing" && url.hostname.endsWith("bing.com") && url.pathname.startsWith("/ck/a")) {
        const token = url.searchParams.get("u") || "";
        if (token.startsWith("a1")) {
          try {
            const encoded = token.slice(2).replace(/-/g, "+").replace(/_/g, "/");
            return atob(encoded.padEnd(Math.ceil(encoded.length / 4) * 4, "="));
          } catch { return ""; }
        }
      }
      return { url: url.href, googleUrl: "" };
    } catch { return ""; }
  }
  let selectors;
  if (engine === "google") selectors = ["#search h3 a[href]", "#search a[jsname='UWckNb'][href]", "h3 a[href]"];
  else if (engine === "bing") selectors = ["li.b_algo h2 a[href]", "#b_results li.b_algo a[href]"];
  else if (engine === "duckduckgo") selectors = ["a[data-testid='result-title-a'][href]", "article[data-testid='result'] a[href]"];
  else selectors = ["div.algo h3 a[href]", "#web h3 a[href]", "div.dd.algo a[href]"];
  const candidates = [...new Set(selectors.flatMap((selector) => Array.from(document.querySelectorAll(selector))))];
  const candidateHosts = [];
  for (const link of candidates) {
    if (link.closest('[data-text-ad], [data-ad], [aria-label="Sponsored"], [aria-label^="Sponsored "], .b_ad, .ad, .sponsored')) continue;
    const resultCard = link.closest("div.MjjYud");
    if (/^\s*(sponsored|advertisement)\b/i.test(resultCard?.innerText || "")) continue;
    const rawHref = link.getAttribute("href") || link.href;
    const target = destination(rawHref);
    const url = typeof target === "string" ? target : target?.url || "";
    try {
      if (url) candidateHosts.push(new URL(url).hostname);
    } catch { }
    if (belongsToProvider(url)) return { url, googleUrl: target?.googleUrl || "" };
  }
  return {
    noResult: true,
    candidateHosts: [...new Set(candidateHosts)].slice(0, 8),
    pageUrl: location.href,
    pageTitle: document.title
  };
}

async function bookmarkSearchTarget(show) {
  const target = bookmarkProvider(show);
  if (!target) return { url: "", resolved: false };
  try {
    const result = await findFirstOrganicProviderUrl(
      show.t, target.domain, target.searchScope, target.resultPathPrefix);
    if (result?.url) return { url: result.url, resolved: true };
  } catch (error) {
    console.warn(`Provider lookup failed for ${show.t}:`, error);
    return { url: "", resolved: false, error: error.message || String(error) };
  }
  return { url: "", resolved: false };
}

function escapeHtml(value) {
  return String(value).replaceAll("&", "&amp;").replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;").replaceAll('"', "&quot;").replaceAll("'", "&#39;");
}

async function exportBookmarks(days) {
  const lines = ["<!DOCTYPE NETSCAPE-Bookmark-file-1>",
    '<META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">',
    "<TITLE>Anime Airing This Week</TITLE>", "<H1>Anime Airing This Week</H1>", "<DL><p>"];
  let count = 0;
  let resolvedCount = 0;
  const pending = [];
  const seen = new Set();
  for (const day of days) {
    for (const show of day.shows) {
      const key = JSON.stringify([show.t, [...(show.p || [])].sort()]);
      if (!seen.has(key)) {
        seen.add(key);
        pending.push({ show, key });
      }
    }
  }
  const targets = new Map();
  for (const [index, item] of pending.entries()) {
      status.textContent = `Finding provider links across search engines (${index + 1}/${pending.length})...`;
    targets.set(item.key, await bookmarkSearchTarget(item.show));
    if (index + 1 < pending.length) await new Promise((resolve) => setTimeout(resolve, 1200));
  }
  for (const day of days) {
    const links = day.shows.map((show) => {
      const key = JSON.stringify([show.t, [...(show.p || [])].sort()]);
      return { show, ...targets.get(key) };
    })
      .filter((entry) => entry.url);
    if (!links.length) continue;
    lines.push(`    <DT><H3>${escapeHtml(day.day)}</H3>`, "    <DL><p>");
    for (const { show, url } of links) {
      const title = `${show.t}${show.e || ""} (${show.time || "TBA"})`;
      lines.push(`        <DT><A HREF="${escapeHtml(url)}">${escapeHtml(title)}</A>`);
      count++;
      const key = JSON.stringify([show.t, [...(show.p || [])].sort()]);
      if (targets.get(key)?.resolved) resolvedCount++;
    }
    lines.push("    </DL><p>");
  }
  if (!count) {
    const failure = [...targets.values()].find((target) => target.error)?.error;
    status.textContent = failure
      ? `Provider lookup failed: ${failure}. No bookmark file was created.`
      : "No eligible provider links were found. No bookmark file was created.";
    return;
  }
  lines.push("</DL><p>");
  const blob = new Blob([lines.join("\n") + "\n"], { type: "text/html;charset=utf-8" });
  const objectUrl = URL.createObjectURL(blob);
  try {
    await chrome.downloads.download({ url: objectUrl, filename: "anime-airing-this-week-bookmarks.html", saveAs: true });
  } finally {
    setTimeout(() => URL.revokeObjectURL(objectUrl), 60000);
  }
  try { await navigator.clipboard.writeText(""); } catch { /* Download has already started. */ }
  status.textContent = `Exported ${count} bookmarks; found ${resolvedCount} provider pages across search engines. ${pending.length - resolvedCount} shows had no eligible organic result and were omitted.`;
}

function addSearchButton(title, provider, label = provider.name, channel = selectedChannel(provider)) {
  const button = document.createElement("button");
  button.type = "button";
  button.textContent = label;
  button.addEventListener("click", () => searchProvider(title, provider, channel).catch(async (error) => {
    await recordFailure(error, "Search button");
    status.textContent = `Search failed (${error.name}): ${error.message}`;
  }));
  providerList.appendChild(button);
}

async function start() {
  try {
    const response = await fetch(chrome.runtime.getURL("providers.json"));
    if (!response.ok) throw new Error("Could not load the provider list.");
    allProviders = await response.json();
    const saved = await chrome.storage.local.get(["primeChannelProviders", "youtubeChannelProviders"]);
    primeChannels = new Set(saved.primeChannelProviders || []);
    youtubeChannels = new Set(saved.youtubeChannelProviders || []);
    // Repair any overlap left by an older extension version.
    for (const id of youtubeChannels) primeChannels.delete(id);

    let clipboardText = "";
    try { clipboardText = await navigator.clipboard.readText(); }
    catch { /* Clipboard access may be unavailable until a show is copied. */ }
    const bookmarkDays = parseBookmarkPayload(clipboardText.trim());
    if (bookmarkDays) {
      document.querySelector('[aria-label="Channel preferences"]').hidden = true;
      providerSection.hidden = true;
      status.textContent = "Building weekly bookmarks…";
      await exportBookmarks(bookmarkDays);
      return;
    }
    const payload = parseAnimePayload(clipboardText.trim());
    if (!payload) {
      renderChannels();
      status.textContent = "Copy a show with C from Airing this week to search.";
      return;
    }

    document.querySelector('[aria-label="Channel preferences"]').hidden = true;
    const target = bookmarkProvider({ t: payload.title, p: payload.providers });
    if (!target) {
      status.textContent = `No supported provider was included for “${payload.title}”.`;
      return;
    }
    providerSection.hidden = true;
    status.textContent = `Finding ${payload.title} on ${target.domain}…`;
    try {
      const result = await findFirstOrganicProviderUrl(
        payload.title, target.domain, target.searchScope, target.resultPathPrefix);
      const url = result?.googleUrl || result?.url;
      if (!url) {
        status.textContent = `No eligible organic result found for ${payload.title} on ${target.domain}.`;
        return;
      }
      await openResolvedProviderPage(url);
    } catch (error) {
      const message = error.message || String(error);
      status.textContent = `Could not resolve ${payload.title}: ${message.replace(/^NO_RESULT: /, "")}`;
    }
  } catch (error) {
    await recordFailure(error, "Popup initialization");
    status.textContent = `Could not load extension settings (${error.name}): ${error.message}`;
  }
}

start();
