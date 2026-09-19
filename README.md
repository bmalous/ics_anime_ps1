# Anime ICS Calendar — PowerShell

[`ics_anime.ps1`](ics_anime.ps1) builds an `.ics` calendar from anime schedules and lets you choose which streaming providers and shows to follow. It includes an interactive keyboard interface, persistent selections, a local JSON cache, and a chronological view of selected episodes airing this week.

For the Python implementation, see [README.md](README.md).

## Contents

- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Main menu](#main-menu)
- [Providers and removal confirmations](#providers-and-removal-confirmations)
- [Seasons and genres](#seasons-and-genres)
- [Selecting shows and exporting changes](#selecting-shows-and-exporting-changes)
- [Review updated shows](#review-updated-shows)
- [Airing this week](#airing-this-week)
- [Keyboard controls](#keyboard-controls)
- [Dates, completed shows, and duplicates](#dates-completed-shows-and-duplicates)
- [Calendar contents and merging](#calendar-contents-and-merging)
- [Cache, refreshes, and data counters](#cache-refreshes-and-data-counters)
- [Command-line reference](#command-line-reference)
- [Command examples](#command-examples)
- [Optional CSV sources](#optional-csv-sources)
- [Automation and calendar subscriptions](#automation-and-calendar-subscriptions)
- [Troubleshooting](#troubleshooting)
- [Tests](#tests)

## Requirements

- PowerShell **5.1 or later**. The script declares `#Requires -Version 5.1`; regression checks have been run with Windows PowerShell 5.1.
- A console capable of reading individual keys for the interactive menus. Windows Terminal or a normal PowerShell console is suitable. PowerShell ISE and redirected input do not provide the same interactive console interface.
- Internet access when fetching or refreshing schedules and provider information.
- Write access to the database location and output calendar folder.

No additional PowerShell modules or API credentials are required. The script uses AniList, LiveChart, and any optional lineup pages you configure. Provider availability depends on those sources and may differ by region. Episode timestamps describe published broadcast schedules; they are not a guarantee of the exact release time on each streaming service.

## Quick start

Download `ics_anime.ps1` to a folder where it can create its cache, then open PowerShell in that folder:

```powershell
.\ics_anime.ps1
```

For a new database:

1. Open **Providers**.
2. Select **Update providers and shows** with Space. This discovers providers and caches the current and next seasons.
3. Highlight each provider you use and press Space to enable it. New databases start with all providers disabled.
4. Return to the main menu with Left Arrow.
5. Choose **Create or update a calendar**, then a season and genre filter.
6. Open **Shows not added** and press Space on the shows you want. `[x]` means selected; `[ ]` means not selected.
7. Return to the management menu and choose **Update ICS with modifications** or **Export calendar**.
8. Choose an output folder. The default calendar filename is `anime-calendar.ics`.

Selecting a provider makes its shows available to browse; it does **not** select all of those shows for export. New discoveries are never automatically added to your calendar.

The default database is `anime-ics-db.json` beside the script. The output directory is remembered in that database. When no output directory has been saved, the Desktop is the normal fallback.

## Main menu

| Option | Function |
| --- | --- |
| Create or update a calendar | Opens season selection, genre selection, and show management. Explicit command-line season options can bypass season selection. |
| Providers | Enables/disables services, refreshes cached provider/show information, and opens provider details. |
| Review updated shows | Appears when eligible update notifications are available. Shows their count. |
| Update ICS with modifications / Export pending changes | Appears when there are changes waiting to be exported. |
| Airing this week | Opens a local-time schedule of selected shows. It is positioned above Quit. |
| Quit | Exits. The Q shortcut offers an export/back choice when changes are pending; the explicit Quit menu item exits without exporting. |

Below Quit is a nonselectable footer:

```text
Data Scraped (Total/Session): 12.34 MB / 0.56 MB
```

**Total** is the accumulated amount recorded in this database. **Session** covers the current process only. Both display in MB, calculated as bytes divided by 1,048,576. These are decoded response-content tallies, not measurements of every byte transferred over the network.

## Providers and removal confirmations

Provider names are discovered from streaming links and normalized where recognized. Common services include Crunchyroll, HIDIVE, Prime Video, Netflix, and Disney+. The directory can grow as sources report additional services.

Enabling a provider immediately reveals its cached shows. Disabling it immediately removes shows that no longer have an enabled provider from browsing lists. Provider attribution stays in the cache, so ordinary toggles do not need another scrape. Older caches that discarded disabled-provider information need a one-time refresh when enabling a provider.

**Update providers and shows** refreshes the current and next seasons plus seasons already present in the cache. Merely displaying a future season in the season menu does not fetch it.

### Removing a provider with selected shows

Two separate decisions are presented:

1. **Remove the provider?** A paginated list shows its selected titles. No keeps the provider enabled. Yes proceeds to the calendar question.
2. **Also remove its shows from the ICS?**

| Answer to the second question | Result |
| --- | --- |
| No — keep existing ICS entries | The provider is disabled. Existing entries for shows losing their last enabled provider are preserved during subsequent merges, subject to the calendar's normal date-retention rules. This does not generate new episodes for those deselected shows. |
| Yes — remove and update ICS now | The provider is disabled and the script exports the calendar immediately, applying **all** pending calendar changes. |

Shows carried by another enabled provider remain selected. If a provider is later re-enabled, retained shows available through it are restored to the selected set.

Right Arrow on a provider opens its details, including a website and up to five popular currently airing titles from the current cached season. O opens its website in the default browser.

## Seasons and genres

The season menu offers **Current**, **Next**, and **Future**. Calendar seasons are:

| Season | Months |
| --- | --- |
| WINTER | January–March |
| SPRING | April–June |
| SUMMER | July–September |
| FALL | October–December |

The computer's date supplies the base current season. When the cached current season is confirmed finished, the menu advances its labels. For example, Summer 2026, Fall 2026, and Winter 2027 can become Current Fall 2026, Next Winter 2027, and Future Spring 2027. Unknown completion dates do not by themselves establish that a season has finished.

An uncached future season is fetched after you choose it and a genre. Returning between menus normally reuses the cache. Continuing shows can appear in another season when cached episode dates place them there; matching a series title alone does not automatically select its sequel.

The genre choices are:

- **All anime**.
- **Fantasy, isekai and reincarnation**: the Fantasy genre or qualifying, non-spoiler tags for the related themes.
- **Non-fantasy / non-isekai / non-reincarnation**: the inverse group.

Genre filtering controls visibility, not selection or export scope. Choosing one genre does not remove previously selected shows in another genre. Likewise, the season being browsed controls what is loaded/displayed; an export can include selected shows across cached seasons.

## Selecting shows and exporting changes

The management menu contains **Shows in the calendar**, **Shows not added**, and an export action.

List membership and counts reflect the **last successful export**. Checkboxes reflect your **current pending selections**. A newly checked title can therefore remain in Shows not added until you export; this lets you revise multiple choices before applying them.

- Space toggles a show.
- `/` opens a case-insensitive title filter; C clears it.
- Right Arrow opens the title, selected status, enabled providers, next known release, and synopsis.
- Left Arrow returns to management, genre selection, or the preceding screen.

Choices are kept in the database and flushed during normal navigation or exit. Checking a box does not itself rewrite the ICS. Export applies those choices, records the applied selection set, and clears the pending-export flag. The provider-removal **Yes** action is an exception: it explicitly requests immediate export.

## Review updated shows

At interactive startup, the script can recheck an **already cached next season** when its schedule is incomplete or contains all-day placeholders. The comparison looks for new dated shows and changes to a show's earliest known release. It is not a notification feed for every episode-level change.

Review entries show a title/provider label and update reason. Space selects a show and immediately removes it from review. Currently selected and previously selected IDs are suppressed using persistent selection history, including known duplicate aliases. Disabled-provider and completed-show entries are not displayed.

D dismisses the current pending notification collection. A later update can produce a new notification for a dismissed, never-selected show. Previously selected shows remain suppressed by history. Right Arrow opens details.

Old databases can seed history from current and last-exported selections. They cannot reconstruct removed selections that were never recorded.

Navigation reuses a snapshot of the review list; it does not rescan every cached episode on each arrow press. Completion is rechecked when the menu opens or its local snapshot crosses a UTC date boundary.

## Airing this week

This is a read-only view of **current selections**, including changes that have not yet been exported. It reads cached schedules; opening it or pressing R does not scrape the websites.

The window covers **today and the next six calendar days in the computer's timezone**. Timed episodes earlier than the current instant are omitted. Rows are grouped by weekday and date and sorted chronologically, with episode numbers and provider labels.

```text
Saturday, September 19
  9:00 PM  Example Show (Crunchyroll) - Episode 11
  TBA  Another Show (HIDIVE)
Sunday, September 20
  1:00 AM  Example Show (Crunchyroll) - Episode 12
```

- Each timestamp is converted to local time, including daylight-saving transitions.
- A confirmed date without an airtime stays on that date and displays **TBA**, after timed entries for the day.
- A completely unknown date or month-only placeholder cannot be assigned to a day and is omitted.
- Duplicate copies of the same show/episode are collapsed.
- Long lists scroll; a day heading is repeated when its entries continue beyond the visible page.
- R rebuilds the view from the current cache and clock. Use a scrape/refresh action first if the cached schedule is stale.

## Keyboard controls

| Screen | Controls |
| --- | --- |
| Standard choice menus | Up/Down move; Home/End jump; Right/Enter/Space choose; Left returns where available; Q requests quit. |
| Provider list | Up/Down move; Space toggles or runs Update; Right opens details; Left returns; Q requests quit. |
| Provider details | Up/Down select a title; Right opens show details; O opens website; Left returns. |
| Show lists | Up/Down move; Page Up/Down page; Home/End jump; Space toggles; Right opens details; `/` filters; C clears filter; Left returns; Q requests quit. |
| Review updated shows | Up/Down move; Space selects; Right opens details; D dismisses notifications; Left returns; Q requests quit. |
| Airing this week | Up/Down scroll; Page Up/Down page; Home/End jump; R refreshes the cached view; Left/Escape return; Q requests quit. |
| Quit prompt | E exports pending changes; Q quits without exporting; Left returns. |

On supported consoles, cursor movement repaints only changed rows. Paging, resizing, and returning from another screen trigger full redraws. Long rows are clipped to avoid wrapping. Consoles without usable cursor positioning fall back to ordinary redraws.

## Dates, completed shows, and duplicates

Precise timed episodes are stored in UTC. Date-only releases use calendar dates. A month-only premiere is exported as an all-day placeholder on the month's first day, with **(date TBA)** in the summary. A title with no date can still be selected, but it cannot generate an event until a date is available.

Completion checks consider cached future airings, a confirmed final episode, a complete end date, and the source's FINISHED status. A known final date must be past before the date-based check hides the show. Missing dates, invalid strings, and old cached `{}` end-date values are treated as unknown rather than crashing the picker. Hiding a completed title does not erase its saved selection or all historical calendar entries.

Duplicate reconciliation links a negative-ID LiveChart fallback to a positive-ID AniList record when:

1. Their normalized titles match, including any season number.
2. They share a provider.
3. Exactly one AniList candidate matches.

Case, repeated whitespace, and Unicode compatibility differences are normalized. Different season numbers, provider-disjoint records, and ambiguous AniList matches remain separate. This is deliberately conservative, not fuzzy matching of arbitrary similar titles.

Reconciliation runs on startup and after scraping. It remaps season references, selections, selection history, and existing-calendar IDs, preferring the AniList record while preserving additional provider information. It works across cached seasons, including an AniList title listed in Fall and its duplicate LiveChart fallback listed in Winter.

## Calendar contents and merging

Generated events include a stable UID, summary, synopsis, provider links, source link, start/end information, and sequence metadata. Synopsis resolution can walk prequel relationships to find a fuller series description when a sequel description is sparse.

By default, one event is generated per episode **per enabled provider**. `-CombineProviders` creates one event per episode listing its enabled services. Multiple providers are intentional calendar entries; they are separate from duplicate source records.

The existing output ICS is merged automatically. `-MergeFrom` adds explicitly named files or wildcard matches. Other nearby ICS files are not scanned automatically. Known deselections and removed-provider rules apply during merging, with the explicit retained-entry exception described above.

Without `-IncludePastEpisodes`, the implementation's retention cutoff is the start of the **previous UTC day**, allowing a short grace period around local-day boundaries. This is different from the weekly view, which excludes timed episodes that have already aired. With `-IncludePastEpisodes`, cached past episodes and eligible older merged events can be kept. Re-scraping cannot recover history that the upstream source no longer supplies.

## Cache, refreshes, and data counters

The version-4 database stores provider preferences, show metadata, seasonal events, selected/applied IDs, selection history, pending updates, retained calendar IDs, duplicate aliases, the output directory, and scrape totals. It is compatible with the current [Python script](ics_anime.py).

Run options such as `-CombineProviders`, `-IncludePastEpisodes`, explicit season/year, genre filter, and custom CSV paths are not saved as a reusable command configuration. Supply them again when needed, including in scheduled commands. The cached seasons remain available even when you start a later run without those season options.

Use only one process at a time with a shared database/output: neither implementation provides multi-process locking. A separate `-DatabasePath` creates an independent profile.

Network access can occur when:

- A requested season is not cached.
- You supply `-Refresh` (applied to the first season load in that run).
- You use the provider Update action, which also refreshes previously cached seasons.
- The interactive next-season startup update check runs.
- An older cache needs provider-data migration or lacks past airings requested by `-IncludePastEpisodes`.

`-SkipStartupUpdateCheck` suppresses only the startup check. It is not a guarantee that every other action will stay offline.

`-MetricsPath` writes a session JSON report with `AniListRequests`, `Sources`, and `TotalBytes` when a normal run completes. Metric byte values are raw integers; only the menu formats them as MB. Report-only actions that return early, such as listing or clearing the cache, do not run the final metrics-writing step.

`-ClearCache` removes cached shows, seasons, aliases, and pending notifications while keeping selections by default. Adding `-Force` also clears selected/applied IDs, known-show IDs, and retained-calendar IDs. It does **not** reset every preference: provider settings, scrape totals, and selection history remain. Neither command deletes the output ICS. For a completely separate starting state, use a new database path and output path.

## Command-line reference

| Parameter | Purpose |
| --- | --- |
| `-OutputPath <path>` | Output `.ics` file or directory. A directory receives `anime-calendar.ics`. |
| `-Providers <string[]>` | Sets enabled providers and saves that preference. Does not select shows. |
| `-Season <name>` | `WINTER`, `SPRING`, `SUMMER`, or `FALL`. |
| `-Year <year>` | Year from 2000 through 2100. |
| `-NextSeason` | Loads the season after the computer-date-derived current season. Cannot be combined with explicit `-Season` or `-Year`. |
| `-IncludePastEpisodes` | Requests past schedules and retains eligible older events. |
| `-CombineProviders` | Creates one event per episode instead of one per provider. |
| `-CategoryFilter <value>` | `All` (default), `FantasyIsekaiReincarnation`, or `ExcludeFantasyIsekaiReincarnation`. A browsing filter. |
| `-ProviderOverridesPath <csv>` | Adds/replaces provider attribution using an override CSV. |
| `-LineupSourcePath <csv>` | Adds seasonal provider lineup pages. |
| `-MergeFrom <string[]>` | Additional ICS paths or wildcard patterns. |
| `-Refresh` | Forces the first requested season load to scrape again. |
| `-ListProviders` | Prints the cached provider directory and exits; does not discover providers by itself. |
| `-ListCache` | Prints database location, size, counts, and seasonal cache status; exits. |
| `-ClearCache` | Clears scraped cache content and exits. |
| `-Force` | With `-ClearCache`, also clears the selection-related fields described above. |
| `-AllDiscoveredProviders` | Enables discovered providers when a scrape runs. Use with `-Refresh` to apply it to an already cached season. Does not select shows. |
| `-MetricsPath <json>` | Destination for the end-of-run session metrics report. |
| `-DatabasePath <json>` | Overrides the default database beside the script. |
| `-NoMenu` | Uses saved selections and command-line options without prompts. A new database has no selected shows. |
| `-SkipStartupUpdateCheck` | Skips the interactive next-season update check. |
| `-Verbose` | Standard PowerShell diagnostic output, including request retry messages. |

For the built-in help:

```powershell
Get-Help .\ics_anime.ps1 -Full
```

## Command examples

Open normally, suppressing only the automatic startup update:

```powershell
.\ics_anime.ps1 -SkipStartupUpdateCheck
```

Browse an explicitly chosen season; the year below is an example, not a fixed default:

```powershell
.\ics_anime.ps1 -Season WINTER -Year 2027 -CategoryFilter FantasyIsekaiReincarnation
```

Refresh and export saved selections without menus:

```powershell
.\ics_anime.ps1 -NoMenu -Refresh -OutputPath 'C:\AnimeCalendar\anime-calendar.ics'
```

Set providers and combine their events. In PowerShell, commas construct the string array:

```powershell
.\ics_anime.ps1 -Providers 'Crunchyroll','Prime Video' -CombineProviders -Refresh
```

Keep available past airings and write metrics:

```powershell
.\ics_anime.ps1 -NoMenu -IncludePastEpisodes -Refresh -MetricsPath '.\metrics.json'
```

Use an independent profile and merge one extra calendar:

```powershell
.\ics_anime.ps1 -DatabasePath '.\profile-two.json' -OutputPath '.\profile-two.ics' -MergeFrom '.\extra.ics'
```

Inspect or clear the cache:

```powershell
.\ics_anime.ps1 -ListProviders
.\ics_anime.ps1 -ListCache
.\ics_anime.ps1 -ClearCache
# Also clear current/applied selections, known-show IDs, and retained-calendar IDs:
.\ics_anime.ps1 -ClearCache -Force
```

## Optional CSV sources

Provider overrides use these column names:

```csv
AniListId,Provider,Url
123456,Crunchyroll,https://example.com/watch/example-show
```

Replace the example ID and URL with real values. Use one row per AniList ID: the current override lookup retains the last row for a repeated ID. Overrides add or replace the specified provider link; they do not remove every other discovered provider.

Seasonal lineup sources use:

```csv
Season,Year,Provider,Url
WINTER,2027,Crunchyroll,https://example.com/winter-lineup
```

Use uppercase season names. Matching rows supply pages whose text is checked for show titles. One provider/page mapping is used per season; repeated matching provider rows replace earlier ones. LiveChart is included automatically.

```powershell
.\ics_anime.ps1 -ProviderOverridesPath '.\overrides.csv' -LineupSourcePath '.\lineups.csv' -Refresh
```

## Automation and calendar subscriptions

First select shows interactively. Then run `-NoMenu -Refresh` from a scheduler to update the file using those saved choices. Use absolute script, database, and output paths in scheduled jobs so the working directory is unambiguous.

Example Windows Task Scheduler command:

```text
powershell.exe -NoProfile -File "C:\AnimeCalendar\ics_anime.ps1" -NoMenu -Refresh -DatabasePath "C:\AnimeCalendar\anime-ics-db.json" -OutputPath "C:\AnimeCalendar\anime-calendar.ics"
```

The script writes a local ICS file; it does not upload or host it. Importing a file into a calendar app normally creates a snapshot. To obtain ongoing subscription updates, publish the generated file at a stable reachable URL and subscribe using a calendar application that supports ICS feeds. Hosting, scheduling, and client refresh behavior are outside this script.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| Empty calendar on first use | Enable providers, explicitly select shows, then export. `-NoMenu` and `-AllDiscoveredProviders` do not select titles. |
| A checked show remains in Shows not added | The list uses last-exported membership. Export pending changes to update the grouping. |
| Nothing in Airing this week | Confirm selections, enabled providers, and cached dated episodes within today plus six days. Undated/month-only premieres are excluded. R refreshes the view, not the source data. |
| Provider is missing | Run Update providers and shows. Attribution depends on streaming links and page parsing; an override CSV can add a missing link. |
| Duplicate title remains | Only unambiguous matching LiveChart/AniList records sharing a provider are reconciled. Different season numbers or ambiguous candidates remain separate. |
| Future shows lack episodes | Announcements often precede schedules. Select the title if desired and refresh later. |
| Unexpected startup network activity | Use `-SkipStartupUpdateCheck`; uncached loads and cache migrations can still require fetching. |
| Rate limits or temporary failures | AniList requests retry transient errors with backoff. Use `-Verbose` for details and retry a refresh later if the source remains unavailable. |
| Arrow keys do not work | Use a normal console with nonredirected input. Unsupported hosts fall back to noninteractive operation. |
| Old date-parsing crash | Current code tolerates `{}` and invalid end dates. Update the script; clearing the cache is not needed for that known issue. |
| Menu pauses | Use the current script. Review navigation caches rows, and season completion uses an episode index and stops at the first unfinished show. A real scrape still takes network time. |
| Script execution is blocked | Review the file and follow your system's PowerShell execution-policy/signing requirements. |

## Tests

The regression scripts load function definitions and use fixtures or temporary files rather than running the normal interactive entry point against your calendar:

```powershell
Get-ChildItem .\tests\ics_anime*.Tests.ps1 | ForEach-Object { & $_.FullName }
```

They cover cache/selection behavior, rendering, provider confirmations, ICS merging, duplicates, weekly schedules and DST, malformed dates, and season-menu performance behavior.

For an in-memory review-navigation timing sample:

```powershell
.\tests\benchmark_review.ps1
```

The benchmark excludes actual terminal rendering and uses synthetic shows and episodes; its numbers are not a guarantee of performance on another machine.
