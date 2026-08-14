# ics_anime.ps1

A PowerShell script that builds an `.ics` calendar of current- or next-season anime
episodes for the streaming services you choose, with an interactive show picker.

Episode airtimes, titles and synopses come from [AniList](https://anilist.co).
Streaming attribution comes from AniList external links, [LiveChart](https://www.livechart.me),
and optional per-season lineup pages. All times are written in UTC; your calendar
application converts them to local time.

## Features

- **Interactive picker** — arrow-key menus for choosing the season, the streaming
  providers, and the individual shows that go into the calendar.
- **Nothing is added by default** — a newly discovered title is listed under
  *Shows not added* until you add it with `Space`. Your choices persist, so a later
  scrape never re-adds a show you removed or quietly adds one you never picked.
- **Handles unannounced premieres** — a show whose premiere is known only to the
  month gets an all-day placeholder on the 1st marked `(date TBA)`. When the real
  date is published the entry moves and `SEQUENCE` increments, so subscribed
  calendar clients follow the change instead of ignoring it.
- **Offline cache** — scraped data is stored in a JSON database beside the script,
  so repeat runs are instant. Shows are stored once and episodes reference them.
- **Merging** — the output file is merged into itself so existing entries survive,
  and extra `.ics` files can be folded in with `-MergeFrom`.
- **RFC 5545 output** — correct 75-octet line folding, UTF-8 without BOM, plain
  dates for all-day events (no off-by-one-day shift east of UTC), and
  `REFRESH-INTERVAL` / `X-PUBLISHED-TTL` hints for subscription clients.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7+
- Internet access on first run for each season (subsequent runs use the cache)

## Quick start

```powershell
# Interactive picker
.\ics_anime.ps1
```

On a fresh database:

1. Open **Providers**, press `Space` on *Update providers and shows* to discover
   which streaming services AniList and LiveChart report, then `Space` to enable
   the ones you subscribe to.
2. Choose **Create or update a calendar**, pick a season and a genre filter.
3. Under **Shows not added**, press `Space` on the titles you want.
4. Choose **Export calendar** and pick an output folder.

The result is `anime-calendar.ics`, which you can import into or subscribe to from
any calendar application.

### Non-interactive

```powershell
# Rebuild next season's calendar with no prompts, using shows already chosen
.\ics_anime.ps1 -NextSeason -NoMenu

# Re-scrape, keep already-aired episodes, one event per episode
.\ics_anime.ps1 -Providers Crunchyroll,'Prime Video' -CombineProviders -IncludePastEpisodes -Refresh
```

Running with `-NoMenu` on a fresh database produces an **empty** calendar, because
no shows have been chosen yet.

## Menu keys

| Key | Action |
| --- | --- |
| `Up` / `Down` | Move |
| `PgUp` / `PgDn`, `Home` / `End` | Page and jump |
| `Space` | Toggle (add/remove a show, enable/disable a provider) |
| `Right` / `Enter` | Details |
| `Left` / `Esc` / `Backspace` | Back |
| `/` | Filter the list by title |
| `C` | Clear the filter |
| `O` | Open a provider's website (provider details view) |
| `Q` | Quit (prompts if changes have not been exported) |

## Parameters

| Parameter | Description |
| --- | --- |
| `-OutputPath` | Destination `.ics` file, or a folder to write `anime-calendar.ics` into. Defaults to the remembered output folder, then the Desktop. |
| `-Providers` | Streaming services to include in non-interactive runs. Interactive choices are saved in the database. |
| `-Season` | `WINTER`, `SPRING`, `SUMMER` or `FALL`. Defaults to the current season. |
| `-Year` | Four-digit year (2000–2100). Defaults to the current year. |
| `-NextSeason` | Target the season after the current one. Cannot be combined with `-Season` or `-Year`. |
| `-IncludePastEpisodes` | Keep episodes that have already aired. Combine with `-Refresh` the first time — a season cached without this switch holds no past airings. |
| `-CombineProviders` | One event per episode listing every service, instead of one event per episode per service. |
| `-CategoryFilter` | `All`, `FantasyIsekaiReincarnation`, or `ExcludeFantasyIsekaiReincarnation`. Controls only what the picker displays; it never adds anything. |
| `-ProviderOverridesPath` | CSV with `AniListId,Provider,Url` columns for regional corrections. |
| `-LineupSourcePath` | CSV with `Season,Year,Provider,Url` columns pointing at official seasonal lineup pages. A title found on such a page is attributed to that provider when AniList and LiveChart have no link. |
| `-MergeFrom` | Additional `.ics` files or wildcards to fold into the output. |
| `-Refresh` | Re-scrape the target season even when cached. |
| `-ListProviders` | Print providers discovered from cached AniList and LiveChart links, then exit. |
| `-ListCache` | Print database location, size and cached seasons, then exit. |
| `-ClearCache` | Drop cached seasons and shows. Add `-Force` to clear saved selections too. |
| `-AllDiscoveredProviders` | Enable every discovered provider instead of the saved selection. |
| `-MetricsPath` | Write a JSON summary of request counts and bytes downloaded. |
| `-DatabasePath` | Override the cache location. Defaults to `anime-ics-db.json` beside the script. |
| `-NoMenu` | Run non-interactively using the supplied parameters. |
| `-SkipStartupUpdateCheck` | Skip the startup re-scrape that looks for new or rescheduled next-season shows. |

## Optional CSV inputs

**Provider overrides** (`-ProviderOverridesPath`) — force a specific service and
watch URL for a given AniList id, useful for regional differences:

```csv
AniListId,Provider,Url
21,Crunchyroll,https://www.crunchyroll.com/series/example
```

**Lineup sources** (`-LineupSourcePath`) — official per-season lineup pages that are
scanned for titles when neither AniList nor LiveChart has a link:

```csv
Season,Year,Provider,Url
FALL,2026,HIDIVE,https://www.hidive.com/fall-2026
```

## Data and files

| File | Purpose |
| --- | --- |
| `anime-ics-db.json` | Cache of scraped seasons, show records, provider directory, and your selections. Created beside the script unless `-DatabasePath` says otherwise. |
| `anime-calendar.ics` | Generated calendar (name fixed when an output folder is chosen). |

The database is schema version 4. A file written by an older version is reported
and replaced with a fresh cache rather than being read incorrectly.

## Notes and caveats

- AniList publishes **Japanese broadcast airtimes**. Streaming releases may happen
  later, and availability differs by region.
- An upcoming season is mostly titles that have been announced but not scheduled.
  Those still appear in the picker and gain a calendar entry once they get a date.
- Provider attribution depends on third-party markup. If LiveChart changes its
  page structure, the script warns and falls back to AniList links alone.
- AniList allows roughly 90 requests a minute; the client retries `429` and `5xx`
  responses with backoff and honours `Retry-After`.
- The script only reads from the network and writes the calendar and its own
  database — nothing is uploaded anywhere.

## History

This is a rewrite of `New-CurrentSeasonAnimeCalendar.ps1`. Behaviour differences
worth knowing about:

- All-day release dates are stored as plain dates, so they no longer shift by a day
  for users east of UTC.
- `-IncludePastEpisodes` is actually honoured.
- Events carry a `SEQUENCE` that increments when an airtime changes, so subscribed
  clients apply the new time.
- Only the output file is merged by default; other calendars are merged only with
  `-MergeFrom`.
- Menus navigate in place instead of relaunching the script.

## License

MIT
