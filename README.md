# Anime ICS Calendar — PowerShell

[`ics_anime.ps1`](ics_anime.ps1) builds an `.ics` calendar from anime schedules and lets you choose which streaming providers and shows to follow. It includes an interactive keyboard interface, persistent selections, a local JSON cache, and a chronological view of selected episodes airing this week.

For the Python implementation, see [Python](https://github.com/bmalous/ics_anime_py).

## Contents

- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Main menu](#main-menu)
- [Providers and removal confirmations](#providers-and-removal-confirmations)
- [LiveChart schedule priority](#livechart-schedule-priority)
- [Seasons and genres](#seasons-and-genres)
- [Selecting shows and exporting changes](#selecting-shows-and-exporting-changes)
- [Review updated shows](#review-updated-shows)
- [Airing this week](#airing-this-week)
- [Keyboard controls](#keyboard-controls)
- [Dates, completed shows, and duplicates](#dates-completed-shows-and-duplicates)
- [Calendar contents and merging](#calendar-contents-and-merging)
- [Cache, refreshes, and data counters](#cache-refreshes-and-data-counters)
- [Use cases](#use-cases)
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

No additional PowerShell modules or API credentials are required. The script uses AniList, LiveChart, provider lineup pages, and Tsuzuki for confirmed English dub schedules. Published LiveChart dates and times take priority over AniList. When LiveChart has no release time, provider schedules can refine the AniList broadcast fallback. Availability and schedules can differ by region.

### Provider release times

Season refreshes try to discover Crunchyroll's official seasonal lineup page and read explicit **Sub Airtime** schedules. A Crunchyroll row in `-LineupSourcePath` can supply the page directly. Matching is by exact show title (case-insensitive); dub-only times and TBA schedules are ignored. These weekly schedules are limited to the page's season. If a page is blocked or its markup is unsupported, published LiveChart times still take priority; otherwise AniList broadcast times remain the fallback.

The adjacent `provider-release-times.csv` also accepts verified weekly schedules for any provider. It ships with Heavy Knight's Crunchyroll Thursday 09:00 Pacific schedule for July–December 2026, including the official source URL. Columns are `Provider,AniListId,Title,Weekday,Time,Timezone,WindowsTimezone,ValidFrom,ValidTo,SourceUrl`. Use 24-hour time, IANA and Windows timezone names, inclusive ISO dates, and a source URL. Matching uses AniListId when supplied, otherwise the exact title. Restart after editing this file. Fresh parsed schedules take precedence over these local rows.

LiveChart releases keep their published timestamps in the weekly view and exports. For AniList fallback events, both views apply the provider timezone's DST rules for each episode. For these AniList fallback events, separate provider events keep separate times; combined entries and the weekly row use the earliest known release among enabled providers. If none is known, they use broadcast time. Calendar descriptions identify the source or **broadcast fallback**. Rules apply only to timed episodes within 36 hours after broadcast; undated/all-day entries are unchanged. This does not infer dub episode numbers or guarantee unexpected delays are reflected.

Refresh a season to fetch new lineup schedules, then export again. The bundled Heavy Knight correction also works with AniList fallback events in existing caches; it does not override published LiveChart timestamps. Re-exporting preserves event UIDs and increases `SEQUENCE` when the time changes in the existing output file.

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
8. Choose an output folder. **Save in this folder** defaults to the working folder from which you launched the script. **Desktop**, directly below it, opens your desktop folder; choose **Save in this folder** there to confirm. The default filename is `anime-calendar.ics`.
9. After saving, choose **Back to previous menu** to return to the menu that started the export, or **Quit**.

Selecting a provider makes its shows available to browse; it does **not** select all of those shows for export. New discoveries are never automatically added to your calendar.

The default database is `anime-ics-db.json` beside the script. The default output location is the working folder from which you launched the script, which can differ from the folder containing the script. Each save picker starts there, including updates launched from the main menu. The last output directory is recorded in the database but does not override this default. An explicit output-path argument takes precedence, including in noninteractive runs.

The **Desktop** shortcut uses the current user's Windows desktop setting (including redirected locations), the home Desktop folder on macOS, or `XDG_DESKTOP_DIR` from Linux's `user-dirs.dirs` under `XDG_CONFIG_HOME` or `~/.config`. Without a configured desktop location, it falls back to `Desktop` inside the user's home folder.

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

Running this refresh does not mark an export as pending when selections are unchanged. With no selected shows and no existing pending changes, it adds neither an export option to the main menu nor an export prompt when you press Q. Existing pending changes are preserved; removing a selection because its providers are disabled still marks an export as pending.

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

## LiveChart schedule priority

Season refreshes match LiveChart cards to AniList IDs and prefer LiveChart's published episode times. The premiere date and the next-episode countdown are parsed separately. Episode ranges such as `EP1-2` produce two episode events at the announced time. Day-only premiere dates stay date-only when no precise time is available.

If a LiveChart correction contradicts the AniList schedule, the conflicting episode and later AniList dates are withheld until LiveChart publishes them. The scripts do not guess a shifted weekly schedule. Earlier confirmed LiveChart releases are retained as the countdown advances, and an unavailable page does not overwrite saved corrections with AniList data. AniList remains the fallback where there is no known conflict or LiveChart date.

Older season caches refresh once to adopt this policy. A corrected episode keeps its ICS UID and increases its sequence when the time moves. Disputed events are removed from other cached seasons and cannot reappear through calendar merging. Announced dates still depend on source updates; seasons with disputed dates are checked again on later days.

## Seasons and genres

The season menu offers **Last** (when applicable), **Current**, **Next**, and **Future**. Calendar seasons supply the initial reference point:

| Season | Months |
| --- | --- |
| WINTER | January–March |
| SPRING | April–June |
| SUMMER | July–September |
| FALL | October–December |

The source lineup determines which season a show belongs to. A Fall show premiering in September stays in Fall. Episode dates no longer copy shows into other season lists.

### Last season and automatic rollover

When the first Current simulcast finishes, **Last** appears above Current for that same season. Each finished simulcast moves there; ongoing simulcasts remain in Current. Last offers **Shows in the calendar** and **Shows not added**, each sorted alphabetically by title. Unfinished English dubs stay selectable; ended shows display a disabled `[-]` checkbox. The `(Ended mm/dd/yy)` date appears at the top of the synopsis in show details, without changing the title line. A known final episode disables the row at its release time. If a source reports completion without any usable date, the label says `(Ended date unknown)`.

When the first next-season premiere airs, that season becomes Current. All remaining shows from the outgoing season are available in Last, including unfinished simulcasts and dubs. For example, the labels become Last Summer 2026, Current Fall 2026, Next Winter 2027, and Future Spring 2027. This continues across year boundaries. Older unfinished shows remain accessible through Last on later rollovers. Date-only placeholders and unknown completion dates do not establish an exact premiere or finale time.

For example, the picker changes as follows:

| Event | Last | Current | Next | Future |
| --- | --- | --- | --- | --- |
| First Summer simulcast ends | SUMMER 2026 | SUMMER 2026 | FALL 2026 | WINTER 2027 |
| First Fall premiere airs | SUMMER 2026 | FALL 2026 | WINTER 2027 | SPRING 2027 |

Last and Current can show the same season name while containing different shows. Menu labels include the prefix, for example **Last - SUMMER 2026**. Last is an interactive view; explicit season/year arguments load the source season, and the command-line next-season option uses calendar quarters.

### Refreshes and English dubs

Entering the season picker refreshes missing or stale lifecycle metadata for the previous, current, and next seasons once per UTC day. Older seasons with unfinished shows are also refreshed. Future remains available on demand. Successful metadata refreshes retain past episodes for premiere/finale detection; the export option still controls whether past episodes are included in the ICS. Returning between menus normally reuses the cache. Season views preserve saved selections and event identities.

English dub announcements are read from available Crunchyroll lineup sections. Confirmed dub episode schedules come from [Tsuzuki](https://tsuzuki.top/api/), using [AniList](https://anilist.co/) IDs. Coverage depends on those sources: absence from the schedule does not prove that no dub exists. Announced dubs with an unknown final episode or an unpublished release date remain selectable. Failed requests preserve the previous successful schedule. Dub events export with a separate UID and an **English Dub** label, using their published times. They are not shifted by simulcast provider timing rules.

### Genre filters and browsing speed

The genre choices are:

- **All anime**.
- **Fantasy, isekai, and reincarnation**: the Fantasy genre or qualifying, non-spoiler tags for the related themes.
- **Other**: shows outside that group.

For command-line genre filtering, use `All`, `FantasyIsekaiReincarnation`, or `ExcludeFantasyIsekaiReincarnation`, respectively. **Other** is the menu label, not a command-line value.

Genre filters are applied before completion checks. Loaded lists and release calculations are reused, so scrolling does not scan every cached episode on each keypress. Reopening a genre reuses its list until selections or provider settings change, a relevant release occurs, or the UTC date changes. Completion is checked again when needed before toggling a row or opening details. The first load can still take longer, and uncached seasons or refreshes require network time.

Genre filtering controls visibility, not selection or export scope. Choosing one genre does not remove previously selected shows in another genre. Likewise, the season being browsed controls what is loaded/displayed; an export can include selected shows across cached seasons.

## Selecting shows and exporting changes

The management menu contains **Shows in the calendar**, **Shows not added**, and an export action.

List membership and counts reflect the **last successful export**. Checkboxes reflect your **current pending selections**. A newly checked title can therefore remain in Shows not added until you export; this lets you revise multiple choices before applying them.

- Space toggles a selectable show immediately, updating only its selection. Ended rows marked `[-]` cannot be toggled.
- `/` opens a case-insensitive title filter; C clears it.
- Right Arrow opens the title, selected status, enabled providers, next known release, and synopsis. For an ended show, the ended date is at the top of the synopsis; titles stay alphabetical.
- Left Arrow returns to management, genre selection, or the preceding screen.

Choices are updated in memory and written to the database during normal navigation or exit. Checking a box does not itself rewrite the ICS. Selection history and review notifications are updated as you toggle. Export applies those choices, records the applied selection set, and clears the pending-export flag. The provider-removal **Yes** action is an exception: it explicitly requests immediate export.

The export action reads **Update ICS with modifications** when selections differ from the last successful export. In show management it otherwise reads **Export calendar**; on the main menu, an existing pending-export flag without selection differences uses **Export pending changes**.

After a successful export, **Back to previous menu** returns to the menu that launched it. An export from the main menu returns there, even if you previously visited a season. An export from a season's show-management menu returns to that season and genre, with list membership updated to reflect the saved calendar. Canceling the output-folder picker also returns to the originating menu.

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
| Show lists | Up/Down move; Page Up/Down page; Home/End jump; Space toggles selectable rows; Right opens details; `/` filters; C clears filter; Left returns; Q requests quit. |
| Review updated shows | Up/Down move; Space selects; Right opens details; D dismisses notifications; Left returns; Q requests quit. |
| Airing this week | Up/Down scroll; Page Up/Down page; Home/End jump; R refreshes the cached view; Left/Escape return; Q requests quit. |
| Quit prompt | E exports pending changes; Q quits without exporting; Left returns. |

On supported consoles, cursor movement repaints only changed rows. Paging, resizing, and returning from another screen trigger full redraws. Long rows are clipped to avoid wrapping. Consoles without usable cursor positioning fall back to ordinary redraws.

## Dates, completed shows, and duplicates

Precise timed episodes are stored in UTC. Date-only releases use calendar dates. A month-only premiere is exported as an all-day placeholder on the month's first day, with **(date TBA)** in the summary. A title with no date can still be selected, but it cannot generate an event until a date is available.

Simulcast completion checks consider cached future airings, the final episode's release time, a complete end date, and the source's FINISHED status. A timed finale counts as aired at its release time; a date-only end date counts after that day. Missing dates, invalid strings, and old cached `{}` end-date values are treated as unknown rather than crashing the picker. Completed simulcasts move to Last. An announced English dub keeps the row selectable until its final episode airs. These views preserve saved selections and historical calendar entries. An AniList end date disputed by a LiveChart correction cannot prematurely mark a show complete.

Duplicate reconciliation links a negative-ID LiveChart fallback to a positive-ID AniList record when:

1. Their normalized titles match, including any season number.
2. They share a provider.
3. Exactly one AniList candidate matches.

Case, repeated whitespace, and Unicode compatibility differences are normalized. Different season numbers, provider-disjoint records, and ambiguous AniList matches remain separate. This is deliberately conservative, not fuzzy matching of arbitrary similar titles.

Reconciliation runs on startup and after scraping. It remaps season references, selections, selection history, and existing-calendar IDs, preferring the AniList record while preserving additional provider information. It works across cached seasons, including an AniList title listed in Fall and its duplicate LiveChart fallback listed in Winter.

## Calendar contents and merging

Generated events include a stable UID, summary, synopsis, provider links, source link, start/end information, and sequence metadata. LiveChart-timed events identify LiveChart as their timing source. Confirmed English dub episodes use separate UIDs and an **English Dub** label. Synopsis resolution can walk prequel relationships to find a fuller series description when a sequel description is sparse.

By default, one event is generated per episode **per enabled provider**. `-CombineProviders` creates one event per episode listing its enabled services. Multiple providers are intentional calendar entries; they are separate from duplicate source records.

The existing output ICS is merged automatically. `-MergeFrom` adds explicitly named files or wildcard matches. Other nearby ICS files are not scanned automatically. Known deselections and removed-provider rules apply during merging, with the explicit retained-entry exception described above.

Without `-IncludePastEpisodes`, the implementation's retention cutoff is the start of the **previous UTC day**, allowing a short grace period around local-day boundaries. This is different from the weekly view, which excludes timed episodes that have already aired. With `-IncludePastEpisodes`, cached past episodes and eligible older merged events can be kept. Re-scraping cannot recover history that the upstream source no longer supplies.

## Cache, refreshes, and data counters

The version-4 database stores provider preferences, show metadata, seasonal events, selected/applied IDs, selection history, pending updates, retained calendar IDs, duplicate aliases, the output directory, and scrape totals. It is compatible with the current [Python script](../Ics_anime_py/ics_anime.py).

Run options such as `-CombineProviders`, `-IncludePastEpisodes`, explicit season/year, genre filter, and custom CSV paths are not saved as a reusable command configuration. Supply them again when needed, including in scheduled commands. The cached seasons remain available even when you start a later run without those season options.

Use only one process at a time with a shared database/output: neither implementation provides multi-process locking. A separate `-DatabasePath` creates an independent profile.

Network access can occur when:

- A requested season is not cached.
- You supply `-Refresh` (applied to the first season load in that run).
- You use the provider Update action, which also refreshes previously cached seasons.
- The interactive next-season startup update check runs.
- Opening the season picker triggers its daily season metadata and English dub refresh.
- An older season cache needs the one-time LiveChart priority migration.
- A season with disputed AniList dates is loaded on a later UTC day.
- An older cache needs provider-data migration or lacks past airings requested by `-IncludePastEpisodes`.

`-SkipStartupUpdateCheck` suppresses only the startup check. Daily season-picker refreshes, conflict checks, and other fetches still run when needed.

`-MetricsPath` writes a session JSON report with `AniListRequests`, `Sources`, and `TotalBytes` when a normal run completes. Metric byte values are raw integers; only the menu formats them as MB. Report-only actions that return early, such as listing or clearing the cache, do not run the final metrics-writing step.

`-ClearCache` removes cached shows, seasons, aliases, and pending notifications while keeping selections by default. Adding `-Force` also clears selected/applied IDs, known-show IDs, and retained-calendar IDs. It does **not** reset every preference: provider settings, scrape totals, and selection history remain. Neither command deletes the output ICS. For a completely separate starting state, use a new database path and output path.

## Use cases

### Follow an English dub after the simulcast ends

1. Start normally and open **Create or update a calendar** to prepare the season picker.
2. Choose **Last - SUMMER 2026** once Summer shows begin finishing, then choose a genre.
3. Open **Shows not added** to select an unfinished English dub, or **Shows in the calendar** to review previously exported shows.
4. Press Space on a selectable title, then return and export.

An announced dub remains selectable while its finale is unknown or still upcoming. Once its confirmed final episode airs, the row becomes `[-]`. Open details with Right Arrow to see the ended date above the synopsis. Both lists remain sorted by title.

### Keep following shows when the season changes

Open the season picker after the first Fall premiere airs. **Next - FALL 2026** becomes **Current - FALL 2026**, **Next - WINTER 2027** follows it, and **Future - SPRING 2027** appears. Find unfinished Summer simulcasts and English dubs under **Last - SUMMER 2026**. Existing selections carry over; choose new Fall titles and export to update the calendar.

### Apply a LiveChart correction to an existing calendar

Refresh the affected season, then export to the same ICS path. For example, the Magical Explorer correction uses LiveChart's October 3, 2026 premiere for episodes 1 and 2 instead of AniList's conflicting October 2 episode 2 entry. Multi-episode premieres create separate events at the same time.

With shows already selected and the default database in use, refresh Fall 2026 and export without menus:

```powershell
.\ics_anime.ps1 -Season FALL -Year 2026 -Refresh -NoMenu -OutputPath .\anime-calendar.ics
```

Use your existing output path and supply a custom database path if needed. Corrected events keep their UIDs; changed times increase their sequence. Later conflicting AniList-only episodes are omitted until LiveChart confirms them. Refresh or reimport the resulting file in your calendar app as appropriate.

### Browse a large Last list

Choose a genre to narrow the list, then use `/` to filter by title, Page Up/Down to move a page, and Home/End to jump. C clears the title filter. Lists are reused during navigation; opening details still checks whether a finale has just aired. A checked show stays under **Shows not added** until a successful export updates its membership.

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

Noninteractive refreshes update the requested season and export saved selections, using cached English dub data. Open the interactive season picker periodically to refresh dub schedules and announcements; its daily preparation does not run in no-menu mode.

The script writes a local ICS file; it does not upload or host it. Importing a file into a calendar app normally creates a snapshot. To obtain ongoing subscription updates, publish the generated file at a stable reachable URL and subscribe using a calendar application that supports ICS feeds. Hosting, scheduling, and client refresh behavior are outside this script.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| Empty calendar on first use | Enable providers, explicitly select shows, then export. `-NoMenu` and `-AllDiscoveredProviders` do not select titles. |
| A checked show remains in Shows not added | The list uses last-exported membership. Export pending changes to update the grouping. |
| Nothing in Airing this week | Confirm selections, enabled providers, and cached dated episodes within today plus six days. Undated/month-only premieres are excluded. R refreshes the view, not the source data. |
| Provider is missing | Run Update providers and shows. Attribution depends on streaming links and page parsing; an override CSV can add a missing link. |
| Duplicate title remains | Only unambiguous matching LiveChart/AniList records sharing a provider are reconciled. Different season numbers or ambiguous candidates remain separate. |
| Last and Current both say Summer | Expected after the first Summer simulcast ends: finished simulcasts move to Last individually while ongoing ones remain Current. |
| A Last row has a dash and cannot be selected | Its releases have ended. Right Arrow shows the ended date at the top of the synopsis. |
| A dub is selectable but has no dated events | An announcement can precede a confirmed schedule. Refresh through the season picker later. |
| A September premiere appears in Fall | Season membership follows the source lineup, even if its first episode airs before October. |
| Later episodes disappear after a date correction | Conflicting AniList-only dates are withheld until LiveChart confirms releases. Refresh the season later. |
| The calendar app still shows an old date | Refresh the season and export to the existing ICS path, then refresh the subscription or reimport the file in your app. |
| Future shows lack episodes | Announcements often precede schedules. Select the title if desired and refresh later. |
| Unexpected startup network activity | Use `-SkipStartupUpdateCheck`; daily season-picker refreshes, uncached loads, disputed-date checks, and cache migrations can still fetch data. |
| Rate limits or temporary failures | AniList requests retry transient errors with backoff. Use `-Verbose` for details and retry a refresh later if the source remains unavailable. |
| Arrow keys do not work | Use a normal console with nonredirected input. Unsupported hosts fall back to noninteractive operation. |
| Old date-parsing crash | Current code tolerates `{}` and invalid end dates. Update the script; clearing the cache is not needed for that known issue. |
| Menu pauses | The first genre load builds its list; repeated visits and scrolling reuse cached rows. Daily preparation, uncached seasons, and explicit refreshes can still take network time. |
| Script execution is blocked | Review the file and follow your system's PowerShell execution-policy/signing requirements. |

## Tests

From the repository root, run the regression scripts. They load function definitions and use fixtures or temporary files. Navigation checks run the menu loop with file and console operations replaced; they do not run the normal interactive entry point against your calendar:

```powershell
Get-ChildItem .\tests\ics_anime*.Tests.ps1 | ForEach-Object { & $_.FullName }
```

They cover cache/selection behavior, rendering, provider confirmations, ICS merging, duplicates, weekly schedules and DST, and malformed dates. Navigation and performance checks cover refreshes without spurious export prompts, individual show toggles, cached genre loading, and returning to the originating menu after export.

Season and schedule regressions also cover individual moves to Last, rollover across years, English dub completion, alphabetical titles and synopsis labels, list reuse and invalidation, LiveChart episode ranges and timestamp priority, outage retention, and preventing disputed dates from returning through ICS merges.

For an in-memory review-navigation timing sample:

```powershell
.\tests\benchmark_review.ps1
```

The benchmark excludes actual terminal rendering and uses synthetic shows and episodes; its numbers are not a guarantee of performance on another machine.
