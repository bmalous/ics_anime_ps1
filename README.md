# Anime ICS calendar

`ics_anime.ps1` creates an iCalendar (`.ics`) file for seasonal anime available
from the streaming providers you choose. It includes a keyboard-driven picker for
providers, seasons, genre groups, and individual shows.

Anime metadata and Japanese broadcast times come from
[AniList](https://anilist.co). The script supplements streaming availability with
[LiveChart](https://www.livechart.me) and, optionally, official seasonal lineup
pages. Calendar times are stored in UTC and converted to local time by your calendar
application.

> AniList reports Japanese broadcast airtimes. A streaming release can be later,
> and provider availability varies by region.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7+
- Internet access when discovering providers or refreshing a season
- An interactive console for the menu interface

No PowerShell modules need to be installed.

## Quick start

```powershell
.\ics_anime.ps1
```

On a new database:

1. Open **Providers**.
2. Select **Update providers and shows** with `Space`. This scans the current and
   next seasons and discovers providers reported by AniList and LiveChart.
3. Enable the providers you use with `Space`.
4. Return to the main menu and choose **Create or update a calendar**.
5. Choose the season and genre view.
6. Open **Shows not added** and use `Space` to select shows.
7. Choose **Update ICS with modifications**, then select an output folder.

New shows are not selected automatically. Choices are stored in
`anime-ics-db.json` and reused on later runs.

The generated file is named `anime-calendar.ics` unless `-OutputPath` names a
specific `.ics` file.

## Interactive workflow

The main menu provides these areas:

- **Create or update a calendar** selects a season and genre view, then opens the
  show manager.
- **Providers** enables or disables streaming services and refreshes provider data.
- **Review updated shows** appears when the startup check finds a new show or a
  changed first release in a previously cached next season.
- **Export pending changes** appears after provider or show choices change.

Show changes are pending until you export. If you try to quit first, the script
offers to export them. Provider choices are saved immediately; selecting **Update
providers and shows** refreshes the current and next seasons and removes cached
provider links—and shows that have no remaining links—for disabled providers.

### Menu keys

| Key | Action |
| --- | --- |
| `Up` / `Down` | Move through a menu or list |
| `Home` / `End` | Jump to the first or last item |
| `PgUp` / `PgDn` | Move by one page in a show list |
| `Space` | Select a menu item, toggle a show/provider, or run provider update |
| `Right` / `Enter` | Select; `Right` also opens details where offered |
| `Left` | Go back |
| `/` | Filter a show list by title |
| `C` | Clear the show-list filter |
| `O` | Open the provider website from provider details |
| `Q` | Quit, with an export prompt if changes are pending |

## Command-line use

Use `-NoMenu` for automation. A fresh database has no selected providers or shows,
so a non-interactive run creates an empty calendar until those choices have been
supplied or saved by an interactive run.

```powershell
# Rebuild next season using saved providers and show selections
.\ics_anime.ps1 -NextSeason -NoMenu

# Refresh Summer 2026, include past episodes, and write a specific file
.\ics_anime.ps1 -Season SUMMER -Year 2026 -Refresh -IncludePastEpisodes `
  -OutputPath C:\Calendars\anime.ics -NoMenu

# Use explicit providers and create one event per episode
.\ics_anime.ps1 -Providers Crunchyroll,'Prime Video' -CombineProviders -NoMenu

# Inspect or clear the cache
.\ics_anime.ps1 -ListCache
.\ics_anime.ps1 -ClearCache
```

Passing `-Providers` replaces the saved enabled-provider list. It does not select
shows. `-AllDiscoveredProviders` enables every provider encountered during that
refresh and saves the resulting provider list.

## Parameters

| Parameter | Meaning |
| --- | --- |
| `-OutputPath <path>` | Output `.ics` file, or a directory in which `anime-calendar.ics` is written. Defaults to the remembered directory, then the Desktop. |
| `-Providers <name[]>` | Providers used for scraping and export. When supplied, replaces the saved enabled-provider list. |
| `-Season <name>` | `WINTER`, `SPRING`, `SUMMER`, or `FALL`. Defaults to the current season. |
| `-Year <year>` | Season year from 2000 through 2100. Defaults to the current year. |
| `-NextSeason` | Select the season immediately after the current one. Cannot be combined with explicit `-Season` or `-Year`. |
| `-IncludePastEpisodes` | Retain already-aired episodes. If the cache contains only future episodes, it is refreshed automatically. |
| `-CombineProviders` | Create one event listing all matching providers. By default, an episode gets one event per provider. |
| `-CategoryFilter <filter>` | `All`, `FantasyIsekaiReincarnation`, or `ExcludeFantasyIsekaiReincarnation`. Changes the picker view only; it does not select shows. |
| `-ProviderOverridesPath <csv>` | Apply regional provider/link corrections from a CSV file. |
| `-LineupSourcePath <csv>` | Add official seasonal lineup pages used when AniList and LiveChart have no provider link. |
| `-MergeFrom <path[]>` | Merge events from additional `.ics` files. Paths may contain wildcards. |
| `-Refresh` | Refresh the target season instead of using its cache. |
| `-ListProviders` | Print providers already present in the database, then exit. |
| `-ListCache` | Print database details and cached-season status, then exit. |
| `-ClearCache` | Remove cached seasons and shows while preserving selections. |
| `-Force` | With `-ClearCache`, also remove saved selections and known-show history. |
| `-AllDiscoveredProviders` | Accept and save every provider discovered while scraping. |
| `-MetricsPath <json>` | Write AniList request count and per-source download-byte totals for this run. |
| `-DatabasePath <json>` | Use a different database file. Defaults to `anime-ics-db.json` beside the script. |
| `-NoMenu` | Run without interactive menus. |
| `-SkipStartupUpdateCheck` | Skip the interactive startup refresh for an incomplete cached next season. |

PowerShell's built-in help also describes the principal options:

```powershell
Get-Help .\ics_anime.ps1 -Detailed
```

## Optional CSV files

### Provider overrides

Use `-ProviderOverridesPath` to assign a provider and watch URL to a specific
AniList title. The provider must also be enabled through `-Providers` or the saved
interactive selection.

```csv
AniListId,Provider,Url
21,Crunchyroll,https://www.crunchyroll.com/series/example
```

### Seasonal lineup sources

Use `-LineupSourcePath` to supply official provider lineup pages. A page is used
only for the matching season and year. If a title appears on it and has no link
from AniList or LiveChart, the lineup page becomes its provider URL.

```csv
Season,Year,Provider,Url
FALL,2026,HIDIVE,https://www.hidive.com/fall-2026
```

LiveChart is included automatically as a seasonal source; it does not need to be
listed in this CSV.

## Cache and refresh behavior

By default, `anime-ics-db.json` is created beside the script. It stores cached
seasons, show metadata, provider links, enabled providers, selected shows, the last
output directory, pending next-season updates, and scrape-byte totals.

The current schema version is 4. An unreadable database or one with a different
version is ignored and rebuilt from a fresh in-memory database. Use `-ListCache`
to see the active path, size, selection count, and cached seasons.

`-Refresh` applies to the first requested season load in a run. Interactive startup
also rechecks a cached next season when it still has undated or date-only releases,
unless `-SkipStartupUpdateCheck` is present.

## Calendar output

The exporter:

- writes CRLF lines, folds content at 75 UTF-8 octets, and emits UTF-8 without a
  byte-order mark;
- uses UTC for timed events and plain dates for all-day releases;
- includes the synopsis, providers, AniList link, and watch/lineup links;
- increments `SEQUENCE` when an airtime moves;
- adds 12-hour `REFRESH-INTERVAL` and `X-PUBLISHED-TTL` hints;
- marks events transparent so they do not make you appear busy.

If only a premiere month is known, the calendar gets an all-day placeholder on the
first of that month with `(date TBA)` in its title. A later refresh moves it to the
published date. Shows with no announced month remain selectable but produce no
event until a date becomes available.

Unless `-IncludePastEpisodes` is used, export keeps events from yesterday UTC
onward. The output file is always read back and merged so unrelated existing events
survive. Additional calendars are merged only when named by `-MergeFrom`; duplicate
UIDs or matching start/title pairs are skipped.

## Data sources and limitations

- AniList supplies titles, schedules, duration, tags, popularity, and most
  synopses. For sparse sequel descriptions, the script follows prequel relations.
- LiveChart can add provider links, schedules, synopses, and titles absent from the
  AniList season result.
- Provider attribution depends on third-party links and page markup. If LiveChart's
  markup changes, the script warns and continues with its other sources.
- AniList requests retry transient failures and rate limits with backoff.
- The script writes only its JSON database, requested calendar, and optional metrics
  file. It does not upload your selections.

## License

MIT
