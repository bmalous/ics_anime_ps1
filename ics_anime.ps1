#Requires -Version 5.1
<#
.SYNOPSIS
Builds an ICS calendar of current- or next-season anime episodes on the streaming
services you choose, with an interactive show picker.

.DESCRIPTION
Episode airtimes, titles and synopses come from AniList. Streaming attribution
comes from AniList external links, LiveChart, and optional per-season lineup
pages. All times are written to the calendar in UTC; calendar applications
convert them to the subscriber's local timezone.

Published provider schedules take precedence over Japanese broadcast airtimes.
Unavailable provider times fall back to broadcast; availability differs by region.

An upcoming season is mostly titles that have been announced but not scheduled.
Those are listed too: a show whose premiere is known only to the month gets an
all-day placeholder on the 1st, marked "(date TBA)", which moves to the real
date - incrementing SEQUENCE so subscribers follow it - as soon as one is
published. A show with no announced date at all still appears in the picker so
you can add it, and gains a calendar entry when it gets a date.

Scraped data is cached in a JSON database beside the script so repeat runs are
offline and instant. Shows are stored once and episodes reference them, so the
database stays small and saving is fast.

Shows are NOT added to the calendar by default. A newly discovered title is
listed under "Shows not added" in the menu, and only the titles you add with
Space are exported. Your choices persist, so a later scrape neither re-adds a
show you removed nor quietly adds one you never picked. Running with -NoMenu on
a fresh database therefore produces an empty calendar until you have chosen
some shows.

This is a rewrite of New-CurrentSeasonAnimeCalendar.ps1. Behaviour differences
worth knowing about:

  * All-day release dates are stored as plain dates, so they no longer shift by
    a day for users east of UTC.
  * -IncludePastEpisodes is actually honoured.
  * Events carry a SEQUENCE that increments when an airtime changes, so
    subscribed calendar clients apply the new time instead of ignoring it.
  * Only the output file is merged by default. Other calendars are merged only
    when you pass -MergeFrom.
  * Menus navigate in place instead of relaunching the script.

.PARAMETER OutputPath
Destination .ics file, or a folder to write anime-calendar.ics into. Defaults to
the working folder from which the script was launched. The folder picker also
offers the current user's Desktop as its second option.

.PARAMETER Providers
Streaming services to include in non-interactive runs. Interactive choices are
saved in the database; a new database starts with every provider disabled.

.PARAMETER Season
WINTER, SPRING, SUMMER or FALL. Defaults to the current season, or to the season
chosen in the menu.

.PARAMETER Year
Four-digit year. Defaults to the current year.

.PARAMETER NextSeason
Target the season immediately after the current one. Cannot be combined with an
explicit -Season or -Year.

.PARAMETER IncludePastEpisodes
Keep episodes that have already aired. Without it, only today's and future
episodes are exported. Combine with -Refresh the first time: a cached season
scraped without this switch does not contain past airings.

.PARAMETER CombineProviders
Emit one event per episode listing every service, instead of one event per
episode per service. A show on three services produces one entry rather than
three.

.PARAMETER CategoryFilter
All shows every title. FantasyIsekaiReincarnation keeps only titles tagged
fantasy, isekai, reincarnation or another-world. ExcludeFantasyIsekaiReincarnation
removes that group. The filter only controls which titles the picker displays -
it never adds anything. The calendar contains exactly the shows you have added.

.PARAMETER ProviderOverridesPath
CSV with AniListId,Provider,Url columns for regional corrections.

.PARAMETER LineupSourcePath
CSV with Season,Year,Provider,Url columns pointing at official seasonal lineup
pages. A title found on such a page is attributed to that provider when AniList
and LiveChart have no link for it.

.PARAMETER MergeFrom
Additional .ics files or wildcards to fold into the output. The output file
itself is always merged so existing entries survive.

.PARAMETER Refresh
Re-scrape the target season even when cached.

.PARAMETER ListProviders
Print providers discovered from cached AniList and LiveChart streaming links.

.PARAMETER DatabasePath
Override the cache location. Defaults to anime-ics-db.json beside the script.

.PARAMETER NoMenu
Run non-interactively using the supplied parameters.

.PARAMETER SkipStartupUpdateCheck
Skip the startup re-scrape that looks for new or rescheduled next-season shows.

.EXAMPLE
.\ics_anime.ps1
Opens the interactive picker.

.EXAMPLE
.\ics_anime.ps1 -NextSeason -NoMenu
Rebuilds the calendar for next season with no prompts, using the shows you have
already added. On a fresh database this writes an empty calendar, because no
shows have been chosen yet.

.EXAMPLE
.\ics_anime.ps1 -Providers Crunchyroll,'Prime Video' -CombineProviders -IncludePastEpisodes -Refresh
Re-scrapes, keeps aired episodes, and writes one event per episode.
#>
[CmdletBinding()]
param(
    [string]$OutputPath,
    [string[]]$Providers,
    [ValidateSet('WINTER','SPRING','SUMMER','FALL')][string]$Season,
    [ValidateRange(2000,2100)][int]$Year,
    [switch]$NextSeason,
    [switch]$IncludePastEpisodes,
    [switch]$CombineProviders,
    [ValidateSet('All','FantasyIsekaiReincarnation','ExcludeFantasyIsekaiReincarnation')]
    [string]$CategoryFilter = 'All',
    [string]$ProviderOverridesPath,
    [string]$LineupSourcePath,
    [string[]]$MergeFrom,
    [switch]$Refresh,
    [switch]$ListProviders,
    [switch]$ListCache,
    [switch]$ClearCache,
    [switch]$Force,
    [switch]$AllDiscoveredProviders,
    [string]$MetricsPath,
    [string]$DatabasePath,
    [switch]$NoMenu,
    [switch]$SkipStartupUpdateCheck
)

$ErrorActionPreference = 'Stop'
$script:NewLine        = [Environment]::NewLine
$script:Invariant      = [Globalization.CultureInfo]::InvariantCulture
$script:UidSuffix      = '@anilist-calendar.local'   # kept so calendars written by the previous script still de-duplicate
$script:DownloadBytes  = @{}
function Add-DownloadBytes {
    param([string]$Source,[long]$Bytes)
    if (-not $Source) { $Source = 'unknown' }
    if (-not $script:DownloadBytes.ContainsKey($Source)) { $script:DownloadBytes[$Source] = 0 }
    $script:DownloadBytes[$Source] += $Bytes
    if ($script:Db) {
        if (-not $script:Db.ScrapeBytesBySource) { $script:Db.ScrapeBytesBySource = [ordered]@{} }
        if (-not $script:Db.ScrapeBytesBySource.Contains($Source)) { $script:Db.ScrapeBytesBySource[$Source] = 0 }
        $script:Db.ScrapeBytesBySource[$Source] = [long]$script:Db.ScrapeBytesBySource[$Source] + $Bytes
        $script:Db.ScrapeBytesTotal = [long]$script:Db.ScrapeBytesTotal + $Bytes
        Set-DatabaseDirty
    }
}

function Format-DataSize { param([long]$Bytes) '{0:N2} MB' -f ($Bytes / 1MB) }

# Provider aliases normalize common AniList/LiveChart names. The database grows
# its provider directory dynamically from streaming links returned by both sites.
$ProviderCatalog = @(
    [pscustomobject]@{ Name='Crunchyroll'; Pattern='(?i)crunchyroll' }
    [pscustomobject]@{ Name='HIDIVE';      Pattern='(?i)hidive' }
    [pscustomobject]@{ Name='Prime Video'; Pattern='(?i)(prime\s*video|primevideo|amazon\.)' }
    [pscustomobject]@{ Name='Netflix';     Pattern='(?i)netflix' }
    [pscustomobject]@{ Name='Disney+';     Pattern='(?i)(disney\s*\+|disneyplus|star\+)' }
)


# Season arithmetic
function Get-AnimeSeason {
    param([datetime]$Now=(Get-Date))
    $name = switch ($Now.Month) {
        { $_ -le 3 } { 'WINTER'; break }
        { $_ -le 6 } { 'SPRING'; break }
        { $_ -le 9 } { 'SUMMER'; break }
        default      { 'FALL' }
    }
    [pscustomobject]@{ Season=$name; Year=$Now.Year }
}

function Get-NextAnimeSeason {
    param([Parameter(Mandatory)]$Current)
    switch ($Current.Season) {
        'WINTER' { [pscustomobject]@{Season='SPRING';Year=[int]$Current.Year} }
        'SPRING' { [pscustomobject]@{Season='SUMMER';Year=[int]$Current.Year} }
        'SUMMER' { [pscustomobject]@{Season='FALL';  Year=[int]$Current.Year} }
        'FALL'   { [pscustomobject]@{Season='WINTER';Year=([int]$Current.Year + 1)} }
    }
}

# Text and time helpers
function Compress-SynopsisWhitespace {
    param([AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $value = $Text.Replace("`r`n","`n").Replace("`r","`n")
    $value = [regex]::Replace($value,'(?m)[\t ]+$','')
    $value = [regex]::Replace($value,'\n[\t ]*\n(?:[\t ]*\n)+',"`n`n")
    return $value.Trim()
}

function ConvertFrom-AnimeHtml {
    param([string]$Text)
    if (-not $Text) { return '' }
    $value = $Text -replace '(?i)<br\s*/?>', $script:NewLine -replace '(?s)<[^>]+>', ''
    return Compress-SynopsisWhitespace ([Net.WebUtility]::HtmlDecode($value))
}

function ConvertTo-IcsText {
    param([AllowEmptyString()][string]$Text)
    if ($null -eq $Text) { return '' }
    return $Text.Replace('\','\\').Replace(';','\;').Replace(',','\,').Replace([string][char]13,'').Replace([string][char]10,'\n')
}

function ConvertTo-IcsLine {
    # RFC 5545 folding at 75 octets. Uses a StringBuilder and a running byte
    # count; the previous implementation re-encoded the whole accumulated line
    # once per character, which is quadratic over ~1 KB descriptions.
    param([Parameter(Mandatory)][string]$Line)
    $utf8 = [Text.Encoding]::UTF8
    if ($utf8.GetByteCount($Line) -le 75) { return $Line }

    $builder = New-Object Text.StringBuilder
    $bytes = 0
    $first = $true
    $enumerator = [Globalization.StringInfo]::GetTextElementEnumerator($Line)
    while ($enumerator.MoveNext()) {
        # Text elements, not chars, so surrogate pairs and combining marks are
        # never split across a fold.
        $element = [string]$enumerator.Current
        $size = $utf8.GetByteCount($element)
        if (-not $first -and ($bytes + $size) -gt 75) {
            $null = $builder.Append([char]13).Append([char]10).Append(' ')
            $bytes = 1
        }
        $null = $builder.Append($element)
        $bytes += $size
        $first = $false
    }
    return $builder.ToString()
}

function ConvertTo-UtcStamp {
    param([Parameter(Mandatory)][datetime]$Value)
    if ($Value.Kind -eq [DateTimeKind]::Unspecified) {
        $Value = [datetime]::SpecifyKind($Value,[DateTimeKind]::Utc)
    }
    return $Value.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ',$script:Invariant)
}

function ConvertFrom-AnimeDate {
    param([string]$Value,[switch]$DateOnly,[switch]$Ics)
    if (-not $Value) { return $null }
    $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
    $parsed = [datetime]::MinValue
    $format=if($Ics){if($DateOnly){'yyyyMMdd'}else{'yyyyMMddTHHmmssZ'}}elseif($DateOnly){'yyyy-MM-dd'}else{'yyyy-MM-ddTHH:mm:ssZ'}
    if ([datetime]::TryParseExact($Value,$format,$script:Invariant,$styles,[ref]$parsed)) { return [datetime]::SpecifyKind($parsed,[DateTimeKind]::Utc) }
    if($DateOnly -or $Ics){return $null}
    if ([datetime]::TryParse($Value,$script:Invariant,$styles,[ref]$parsed)) { return $parsed }
    return $null
}

function Get-EventInstant {
    # One comparable UTC instant for both timed and all-day events.
    param($Entry)
    if ($null -ne $script:BrowseEventInstants) {
        $key=if ($Entry.AllDay) { "date|$($Entry.Date)" } else { "time|$($Entry.StartUtc)" }
        if (-not $script:BrowseEventInstants.ContainsKey($key)) {
            $script:BrowseEventInstants[$key]=if ($Entry.AllDay) { ConvertFrom-AnimeDate $Entry.Date -DateOnly } else { ConvertFrom-AnimeDate $Entry.StartUtc }
        }
        return $script:BrowseEventInstants[$key]
    }
    if ($Entry.AllDay) { return (ConvertFrom-AnimeDate $Entry.Date -DateOnly) }
    return (ConvertFrom-AnimeDate $Entry.StartUtc)
}

function Get-CanonicalEventUid {
    param([string]$Uid,[string]$EventId)
    if ($EventId) { return "$EventId$script:UidSuffix" }
    $value = ([string]$Uid).Trim()
    # Migrate UIDs written by older versions, which appended the active year and
    # season even when exporting an event loaded from another cached season.
    if ($value -match '^(?<id>-?\d+-(?:\d+|release)-[A-Za-z0-9]+)(?:-\d{4}-(?:winter|spring|summer|fall))?@anilist-calendar\.local$') {
        $eventKey=$Matches.id
        if ($eventKey -match '^(?<media>-?\d+)(?<rest>-.+)$') {
            $eventKey="$(Resolve-ShowId $Matches.media)$($Matches.rest)"
        }
        return "$eventKey$script:UidSuffix"
    }
    return $value
}

function Get-EventStartFromIcsBlock {
    param([string]$Block)
    $match = [regex]::Match($Block,'(?m)^DTSTART(?<date>;VALUE=DATE)?:(?<v>[^\r\n]+)')
    if (-not $match.Success) { return $null }
    return (ConvertFrom-AnimeDate $match.Groups['v'].Value.Trim() -Ics -DateOnly:$match.Groups['date'].Success)
}

# AniList client
$script:AniListRequests = 0

function Invoke-AniList {
    # AniList allows about 90 requests a minute and answers 429 with Retry-After.
    # The previous version had no retry, so a single rate-limit response aborted
    # an entire scrape with nothing saved.
    param(
        [Parameter(Mandatory)][string]$Query,
        [hashtable]$Variables,
        [int]$MaximumAttempts = 4
    )
    $body = @{ query=$Query; variables=$Variables } | ConvertTo-Json -Depth 12 -Compress
    $headers = @{
        Accept         = 'application/json'
        'Content-Type' = 'application/json'
        'User-Agent'   = 'anime-ics/1.0'
    }
    for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
        try {
            $script:AniListRequests++
            $response = Invoke-WebRequest -UseBasicParsing -Method Post -Uri 'https://graphql.anilist.co' -Headers $headers -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 60
            $json=[string]$response.Content;Add-DownloadBytes 'AniList' ([Text.Encoding]::UTF8.GetByteCount($json));$result=$json|ConvertFrom-Json
            if ($result.errors) { throw (($result.errors.message) -join '; ') }
            return $result.data
        } catch {
            $status = $null
            $retryAfter = $null
            try {
                if ($_.Exception.Response) {
                    $status = [int]$_.Exception.Response.StatusCode
                    $retryAfter = $_.Exception.Response.Headers['Retry-After']
                }
            } catch { }
            $transient = ($status -eq 429 -or ($status -ge 500 -and $status -le 599) -or $null -eq $status)
            if (-not $transient -or $attempt -eq $MaximumAttempts) { throw }
            $wait = 2 * $attempt
            if ($retryAfter) { $parsedWait = 0; if ([int]::TryParse([string]$retryAfter,[ref]$parsedWait)) { $wait = [math]::Max($parsedWait,1) } }
            Write-Verbose "AniList attempt $attempt failed (status $status); retrying in $wait s."
            Start-Sleep -Seconds $wait
        }
    }
}

function Get-SeasonMediaQuery {
    param([switch]$IncludeAired)
    # notYetAired:null makes the API return 500, so the argument is present or
    # absent rather than parameterised.
    $airing = if ($IncludeAired) { 'airingSchedule(perPage: 100)' } else { 'airingSchedule(notYetAired: true, perPage: 100)' }
    return @"
query (`$page: Int!, `$season: MediaSeason!, `$year: Int!) {
  Page(page: `$page, perPage: 50) {
    pageInfo { hasNextPage }
    media(type: ANIME, season: `$season, seasonYear: `$year,
      format_in: [TV, TV_SHORT, ONA],
      status_in: [RELEASING, FINISHED, NOT_YET_RELEASED],
      sort: [START_DATE, TITLE_ROMAJI]) {
      id
      siteUrl
      title { romaji english native }
      description(asHtml: false)
      duration
      startDate { year month day }
      endDate { year month day }
      episodes
      genres
      tags { name rank isMediaSpoiler }
      popularity
      status
      externalLinks { site url type }
      $airing { nodes { episode airingAt } }
      upcomingSchedule: airingSchedule(notYetAired: true, perPage: 100) { nodes { episode airingAt } }
      relations {
        edges {
          relationType
          node { id type format description(asHtml: false) title { romaji english } }
        }
      }
    }
  }
}
"@
}

function Get-AniListMediaBatch {
    # Aliased batch lookup: one request resolves many ids instead of one each.
    param([int[]]$Id)
    $ids = @($Id | Where-Object { $_ -gt 0 } | Select-Object -Unique)
    if ($ids.Count -eq 0) { return @{} }
    $results = @{}
    for ($offset = 0; $offset -lt $ids.Count; $offset += 10) {
        $chunk = @($ids[$offset..([math]::Min($offset+9,$ids.Count-1))])
        $parts = New-Object Text.StringBuilder
        $null = $parts.Append('query {')
        foreach ($id in $chunk) {
            $null = $parts.Append(@"

  m$($id): Media(id: $id, type: ANIME) {
    id
    description(asHtml: false)
    title { romaji english }
    relations { edges { relationType node { id type format description(asHtml: false) title { romaji english } } } }
  }
"@)
        }
        $null = $parts.Append([Environment]::NewLine + '}')
        try { $data = Invoke-AniList -Query $parts.ToString() }
        catch { Write-Verbose "Batch media lookup failed: $($_.Exception.Message)"; continue }
        foreach ($property in $data.PSObject.Properties) {
            if ($property.Value -and $property.Value.id) { $results[[int]$property.Value.id] = $property.Value }
        }
    }
    return $results
}

function Test-IncompleteSynopsis {
    param([string]$Synopsis)
    if ([string]::IsNullOrWhiteSpace($Synopsis) -or $Synopsis.Trim().Length -lt 90) { return $true }
    return ($Synopsis -match '(?i)^\s*(the )?(second|third|fourth|final|new|next) season\b|\b(sequel|continuation) (of|to)\b|\bsee (the )?(first|previous|prior) season\b|\bcontinues? (from|the story)\b')
}

function Get-PrequelNode {
    param($Node)
    if (-not $Node) { return $null }
    return @($Node.relations.edges | Where-Object {
        $_.relationType -eq 'PREQUEL' -and $_.node.type -eq 'ANIME' -and $_.node.format -in @('TV','TV_SHORT','ONA')
    } | Select-Object -First 1 | ForEach-Object { $_.node })
}

function Resolve-SeriesSynopses {
    <#
        Fills in a usable synopsis for every media item.

        A sequel's own AniList description is often "The second season of X", so
        the useful text lives on a prequel. The season query already returns one
        level of relations, which resolves most of them without a request at
        all; anything deeper is walked one hop at a time with all of that hop's
        ids fetched in a single aliased batch. Results are memoised, so a
        prequel shared by several sequels is fetched once.
    #>
    param([Parameter(Mandatory)]$Media, [int]$MaximumDepth = 6)

    $synopsis = @{}
    $pending  = @{}   # mediaId -> next prequel id to inspect
    $memo     = @{}   # full records returned by Get-AniListMediaBatch
    $best     = @{}   # deepest usable synopsis if the relation chain is incomplete

    foreach ($item in $Media) {
        $own = ConvertFrom-AnimeHtml $item.description
        if ($item.PSObject.Properties.Name -contains 'MetadataSource' -and $item.MetadataSource -eq 'LiveChart') {
            $synopsis[[int]$item.id] = if ($own) { $own } else { 'No full synopsis is currently available from LiveChart or AniList.' }
            continue
        }
        if (-not (Test-IncompleteSynopsis $own)) { $synopsis[[int]$item.id] = $own; continue }

        foreach ($node in @(Get-PrequelNode $item)) {
            if (-not $node) { continue }
            $text = ConvertFrom-AnimeHtml $node.description
            if (-not (Test-IncompleteSynopsis $text)) {
                $best[[int]$item.id] = [pscustomobject]@{Node=$node;Text=$text}
            }
            # Relation nodes are shallow. Fetch the prequel itself so its own
            # PREQUEL edge is available and traversal can reach season one.
            $pending[[int]$item.id] = [int]$node.id
            break
        }
        if (-not $pending.ContainsKey([int]$item.id)) {
            $synopsis[[int]$item.id] = if ($own) { $own } else { 'No full synopsis is currently available from AniList.' }
        }
    }

    for ($depth = 0; $depth -lt $MaximumDepth -and $pending.Count -gt 0; $depth++) {
        $wanted = @($pending.Values | Where-Object { -not $memo.ContainsKey([int]$_) } | Select-Object -Unique)
        if ($wanted.Count -gt 0) {
            $fetched = Get-AniListMediaBatch -Id $wanted
            foreach ($key in $fetched.Keys) { $memo[[int]$key] = $fetched[$key] }
        }
        $next = @{}
        foreach ($mediaId in @($pending.Keys)) {
            $nodeId = [int]$pending[$mediaId]
            $node = $memo[$nodeId]
            if (-not $node) {
                if ($best.ContainsKey($mediaId)) { $synopsis[$mediaId] = Format-SeasonOneSynopsis $best[$mediaId].Node $best[$mediaId].Text }
                continue
            }
            $text = ConvertFrom-AnimeHtml $node.description
            if (-not (Test-IncompleteSynopsis $text)) {
                $best[$mediaId] = [pscustomobject]@{Node=$node;Text=$text}
            }
            $prequel = @(Get-PrequelNode $node) | Select-Object -First 1
            if ($prequel) { $next[$mediaId] = [int]$prequel.id }
            elseif ($best.ContainsKey($mediaId)) { $synopsis[$mediaId] = Format-SeasonOneSynopsis $best[$mediaId].Node $best[$mediaId].Text }
        }
        $pending = $next
    }

    foreach ($mediaId in @($pending.Keys)) {
        if ($best.ContainsKey($mediaId)) { $synopsis[$mediaId] = Format-SeasonOneSynopsis $best[$mediaId].Node $best[$mediaId].Text }
    }

    foreach ($item in $Media) {
        if (-not $synopsis.ContainsKey([int]$item.id)) {
            $own = ConvertFrom-AnimeHtml $item.description
            $synopsis[[int]$item.id] = if ($own) { $own } else { 'No full synopsis is currently available from AniList.' }
        }
    }
    return $synopsis
}

# Provider attribution
function Get-ProviderFromLink {
    param($Link)
    $value = "$($Link.site) $($Link.url)"
    foreach ($provider in $ProviderCatalog) {
        if ($value -match $provider.Pattern) { return $provider.Name }
    }
    if($Link.site){return ([string]$Link.site).Trim()}
    try{$host=([uri]$Link.url).Host -replace '^www\.','';if($host-match '(^|\.)(anilist\.co|livechart\.me|twitter\.com|x\.com|youtube\.com|youtu\.be)$'){return $null};return $host}catch{return $null}
}

function Format-SeasonOneSynopsis {
    param($Node,[string]$Text)
    return $Text
}

function Remove-SynopsisSourcePrefix {
    param([AllowEmptyString()][string]$Text)
    return ([regex]::Replace($Text,'^(?:(?:Season 1|Series) synopsis from .{1,200}:\s+)','',[Text.RegularExpressions.RegexOptions]::IgnoreCase))
}

function Format-AnimeTitle {
    param([string]$Title,$Providers)
    $names=if($Providers -is [Collections.IDictionary]){@($Providers.Keys)}else{@($Providers)}
    $names=@($names|Where-Object{$_}|Sort-Object -Unique)
    if($names.Count){return "$Title ($($names -join ', '))"}
    return $Title
}

function Write-WrappedText {
    param([string]$Text)
    $width=78;try{$width=[math]::Max(20,$Host.UI.RawUI.WindowSize.Width-2)}catch{}
    foreach($paragraph in @(([string]$Text)-split '\r?\n')){
        if([string]::IsNullOrWhiteSpace($paragraph)){Write-Host '';continue}
        $line=''
        foreach($word in @($paragraph.Trim()-split '\s+')){
            if(-not$line){$line=$word}elseif(($line.Length+1+$word.Length)-le$width){$line+=' '+$word}else{Write-Host $line;$line=$word}
        }
        if($line){Write-Host $line}
    }
}

function Get-ProviderMainUrl {
    param([string]$Url)
    if(-not$Url){return $null}
    try{$uri=[uri]$Url;if($uri.Scheme -notin @('http','https')){return $null};return $uri.GetLeftPart([UriPartial]::Authority)+'/' }catch{return $null}
}

function Register-Provider {
    param([string]$Name,[string]$Url)
    if(-not $Name){return}
    $mainUrl=Get-ProviderMainUrl $Url
    if(-not $script:Db.ProviderDirectory.Contains($Name)){$script:Db.ProviderDirectory[$Name]=[ordered]@{Name=$Name;Url=$mainUrl};Set-DatabaseDirty}
    elseif($mainUrl -and $script:Db.ProviderDirectory[$Name].Url -ne $mainUrl){$script:Db.ProviderDirectory[$Name].Url=$mainUrl;Set-DatabaseDirty}
}

function Test-FantasyIsekaiReincarnation {
    param($Media)
    if (@($Media.genres) -contains 'Fantasy') { return $true }
    foreach ($tag in @($Media.tags)) {
        if (-not $tag.isMediaSpoiler -and $tag.name -match '(?i)\b(isekai|reincarnat|another world|transmigration)\b') { return $true }
    }
    return $false
}

function Get-WebPageText {
    param([string]$Uri)
    if (-not $Uri) { return '' }
    try {
        $response = Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec 30 -Headers @{'User-Agent'='anime-ics/1.0'}
        # Windows PowerShell 5.1 sometimes decodes UTF-8 HTML as Windows-1252,
        # producing text such as "I<e2><80><99>m". Decode the bytes explicitly.
        if ($response.RawContentStream) {
            $response.RawContentStream.Position = 0
            $reader = New-Object IO.StreamReader($response.RawContentStream,[Text.Encoding]::UTF8,$true)
            try {$text=$reader.ReadToEnd();Add-DownloadBytes (([uri]$Uri).Host) ([Text.Encoding]::UTF8.GetByteCount($text));return $text} finally { $reader.Dispose() }
        }
        $text=[string]$response.Content;Add-DownloadBytes (([uri]$Uri).Host) ([Text.Encoding]::UTF8.GetByteCount($text));return $text
    } catch {
        Write-Warning "Lineup page unavailable: $Uri ($($_.Exception.Message))"
        return ''
    }
}

function Test-MediaOnPage {
    # Requires a longer title than the old four-character floor and checks word
    # boundaries, so short titles no longer match arbitrary page text.
    param($Media, [string]$Page)
    if (-not $Page) { return $false }
    foreach ($title in @($Media.title.english,$Media.title.romaji,$Media.title.native)) {
        if (-not $title -or $title.Length -lt 8) { continue }
        foreach ($candidate in @($title,[Net.WebUtility]::HtmlEncode($title))) {
            $pattern = '(?i)(?<![A-Za-z0-9])' + [regex]::Escape($candidate) + '(?![A-Za-z0-9])'
            if ([regex]::IsMatch($Page,$pattern)) { return $true }
        }
    }
    return $false
}

function Get-LiveChartEntries {
    param([Parameter(Mandatory)][string]$Html, [Parameter(Mandatory)][string]$PageUrl)
    $options = [Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::Singleline
    foreach ($match in [regex]::Matches($Html,'<article class="anime"(?<attrs>[^>]*)>(?<body>[\s\S]*?)</article>',$options)) {
        $attrs = $match.Groups['attrs'].Value
        $body  = $match.Groups['body'].Value
        $liveId       = [regex]::Match($attrs,'data-anime-id="(?<v>\d+)"',$options).Groups['v'].Value
        $romaji       = [Net.WebUtility]::HtmlDecode([regex]::Match($attrs,'data-romaji="(?<v>[^"]*)"',$options).Groups['v'].Value)
        $english      = [Net.WebUtility]::HtmlDecode([regex]::Match($attrs,'data-english="(?<v>[^"]*)"',$options).Groups['v'].Value)
        $premiereText = [regex]::Match($attrs,'data-premiere="(?<v>\d+)"',$options).Groups['v'].Value
        $precision    = [regex]::Match($attrs,'data-premiere-precision="(?<v>\d+)"',$options).Groups['v'].Value
        $anilistText  = [regex]::Match($body,'https://anilist\.co/anime/(?<v>\d+)',$options).Groups['v'].Value
        $releases=@{}
        if ($premiereText -and [int]$precision -ge 4) { $releases[1]=[long]$premiereText }
        foreach ($overlay in [regex]::Matches($body,'<a\b[^>]*class="[^"]*episode-countdown[^"]*"[^>]*>(.*?)</a>',$options)) {
            $block=[Net.WebUtility]::HtmlDecode($overlay.Groups[1].Value)
            $label=[regex]::Match($block,'release-schedule-info[^>]*>(?<v>[^<]*)',$options).Groups['v'].Value
            $ep=[regex]::Match($label,'\bEP\s*(\d+)(?:\s*[-\u2013\u2014]\s*(\d+))?',$options)
            $stamp=[regex]::Match($block,'data-timestamp="(?<v>\d+)"',$options).Groups['v'].Value
            if (-not $ep.Success -or -not $stamp -or [long]$stamp -le 0 -or $label -match '\bdub\b') { continue }
            $first=[int]$ep.Groups[1].Value
            $last=if ($ep.Groups[2].Success) { [int]$ep.Groups[2].Value } else { $first }
            if ($first -gt 0 -and $last -ge $first -and $last-$first -le 1000) {
                for ($number=$first; $number -le $last; $number++) { $releases[$number]=[long]$stamp }
            }
        }
        $synopsis     = ConvertFrom-AnimeHtml ([regex]::Match($body,'<div class="anime-synopsis"[^>]*>(?<v>[\s\S]*?)</div>',$options).Groups['v'].Value)
        if ($synopsis -match '(?i)^No synopsis has been added') { $synopsis = '' }
        $tags = @([regex]::Matches($body,'<ol class="anime-tags">(?<block>[\s\S]*?)</ol>',$options) | ForEach-Object {
            [regex]::Matches($_.Groups['block'].Value,'<a[^>]*>(?<v>[^<]+)</a>',$options) | ForEach-Object {
                [Net.WebUtility]::HtmlDecode($_.Groups['v'].Value)
            }
        })
        $providerLinks = @{}
        foreach ($href in [regex]::Matches($body,'href="(?<v>https?://[^"]+)"',$options)) {
            $url = [Net.WebUtility]::HtmlDecode($href.Groups['v'].Value)
            $provider = Get-ProviderFromLink ([pscustomobject]@{site='';url=$url})
            if ($provider -and -not $providerLinks.ContainsKey($provider)) { $providerLinks[$provider] = $url }
        }
        [pscustomobject]@{
            LiveChartId   = $liveId
            AniListId     = $(if ($anilistText) { [int]$anilistText } else { $null })
            Romaji        = $romaji
            English       = $english
            Synopsis      = $synopsis
            Tags          = $tags
            AiringAt      = $(if ($premiereText) { [long]$premiereText } else { 0 })
            Precision     = $(if ($precision) { [int]$precision } else { 0 })
            Episode       = 1
            Releases      = @(foreach ($number in ($releases.Keys | Sort-Object)) { @{episode=$number;airingAt=$releases[$number];TimingSource='LiveChart';SourceUrl="$PageUrl#anime-$liveId"} })
            ProviderLinks = $providerLinks
            Url           = "$PageUrl#anime-$liveId"
        }
    }
}

function Resolve-LiveChartAirings {
    param([array]$Nodes,$Schedule,[int]$ConflictFrom=0)
    $preferred=@{}
    foreach ($node in @($Schedule.Releases)) {
        if ([int]$node.episode -gt 0 -and [long]$node.airingAt -gt 0) { $preferred[[int]$node.episode]=$node }
    }
    foreach ($node in $Nodes) {
        $episode=[int]$node.episode; $stamp=[long]$node.airingAt
        foreach ($number in $preferred.Keys) {
            if (($episode -eq $number -and $stamp -ne [long]$preferred[$number].airingAt) -or
                ($episode -gt $number -and $stamp -lt [long]$preferred[$number].airingAt)) {
                if (-not $ConflictFrom -or $number -lt $ConflictFrom) { $ConflictFrom=$number }
            }
        }
        if ([int]$Schedule.Precision -ge 3 -and [long]$Schedule.PremiereAt -gt 0) {
            $day=[math]::Floor($stamp/86400); $premiereDay=[math]::Floor([long]$Schedule.PremiereAt/86400)
            if (($episode -eq 1 -and $day -ne $premiereDay) -or ($episode -gt 1 -and $day -lt $premiereDay)) { $ConflictFrom=1 }
        }
    }
    $result=@{}
    foreach ($node in $Nodes) { if (-not $ConflictFrom -or [int]$node.episode -lt $ConflictFrom) { $result[[int]$node.episode]=$node } }
    foreach ($number in $preferred.Keys) { $result[$number]=$preferred[$number] }
    [pscustomobject]@{Airings=@($result.Values);ConflictFrom=$ConflictFrom}
}

function Get-LineupSources {
    param([string]$SeasonName,[int]$SeasonYear,[string]$Path)
    $sources = @{ LiveChart = "https://www.livechart.me/$($SeasonName.ToLowerInvariant())-$SeasonYear/tv" }
    if ('Crunchyroll' -in $Providers) {
        $index = Get-WebPageText 'https://www.crunchyroll.com/news/seasonal-lineup'
        $pattern = '(?:https://www\.crunchyroll\.com)?(/news/seasonal-lineup/\d{4}/\d+/\d+/' + $SeasonName.ToLowerInvariant() + '-anime-' + $SeasonYear + '-crunchyroll)'
        $match = [regex]::Match([Net.WebUtility]::HtmlDecode($index),$pattern)
        if ($match.Success) { $sources['Crunchyroll']='https://www.crunchyroll.com'+$match.Groups[1].Value }
    }
    if (-not $Path) { return $sources }
    if (-not (Test-Path -LiteralPath $Path)) { Write-Warning "Lineup source list not found: $Path"; return $sources }
    foreach ($row in @(Import-Csv -LiteralPath $Path)) {
        if ([string]$row.Season -ne $SeasonName) { continue }
        if ([int]$row.Year -ne $SeasonYear) { continue }
        if ($row.Provider -and $row.Url) { $sources[[string]$row.Provider] = [string]$row.Url }
    }
    return $sources
}

function Get-CrunchyrollSchedules {
    param([string]$Html,[string]$SourceUrl,[string]$SeasonName,[int]$Year)
    $month=@{WINTER=1;SPRING=4;SUMMER=7;FALL=10}[$SeasonName]
    $begin=[datetime]::new($Year,$month,1)
    $end=$begin.AddMonths(3).AddDays(-1)
    foreach ($section in [regex]::Matches($Html,'(?is)<h[23]\b[^>]*>(.*?)</h[23]>(.*?)(?=<h[23]\b|$)')) {
        $title=ConvertFrom-AnimeHtml $section.Groups[1].Value
        $plain=ConvertFrom-AnimeHtml ($section.Groups[2].Value -replace '(?i)</(?:p|div|li)>',' ')
        $match=[regex]::Match($plain,'(?i)Sub Airtime:\s*(Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)\s+at\s+(\d{1,2}):(\d{2})\s*([ap])\.?m\.?\s+PT\b')
        if (-not $match.Success) { continue }
        $hour=[int]$match.Groups[2].Value; $minute=[int]$match.Groups[3].Value
        if ($hour -lt 1 -or $hour -gt 12 -or $minute -gt 59) { continue }
        $hour=$hour % 12
        if ($match.Groups[4].Value -eq 'p') { $hour+=12 }
        @{provider='Crunchyroll';title=$title;weekday=$match.Groups[1].Value;
          time=('{0:00}:{1:00}' -f $hour,$minute);timezone='America/Los_Angeles';windowstimezone='Pacific Standard Time';
          validfrom=$begin.ToString('yyyy-MM-dd');validto=$end.ToString('yyyy-MM-dd');sourceurl=$SourceUrl}
    }
}

function Get-EnglishDubTitles {
    param([string]$Html)
    foreach ($section in [regex]::Matches($Html,'<h[23]\b[^>]*>(.*?)</h[23]>(.*?)(?=<h[23]\b|$)','IgnoreCase,Singleline')) {
        $text=ConvertFrom-AnimeHtml $section.Groups[2].Value
        if ($text -match 'Dub(?:bing)? Languages?:\s*[^.;\n]*\bEnglish\b') { ConvertFrom-AnimeHtml $section.Groups[1].Value }
    }
}

function Get-ProviderReleaseTime {
    param($Entry,$Show,[string[]]$ForProviders)
    if ($null -eq $script:BrowseReleaseTimes) { return (Get-UncachedProviderReleaseTime $Entry $Show $ForProviders) }
    $key="$($Entry.MediaId)|$($Entry.Episode)|$($Entry.StartUtc)|$($Entry.Date)|$($Entry.AllDay)|$($Entry.AirType)|$($Entry.TimingSource)|$($Entry.SourceUrl)|$($ForProviders -join ',')"
    if (-not $script:BrowseReleaseTimes.ContainsKey($key)) {
        $script:BrowseReleaseTimes[$key]=Get-UncachedProviderReleaseTime $Entry $Show $ForProviders
    }
    return $script:BrowseReleaseTimes[$key]
}

function Get-UncachedProviderReleaseTime {
    param($Entry,$Show,[string[]]$ForProviders)
    $broadcast=Get-EventInstant $Entry
    if ($Entry.AirType -eq 'dub') { return [pscustomobject]@{Start=$broadcast;Source="English dub: $($Entry.SourceUrl)"} }
    if ($Entry.TimingSource -eq 'LiveChart') { return [pscustomobject]@{Start=$broadcast;Source="LiveChart: $($Entry.SourceUrl)"} }
    $fallback=[pscustomobject]@{Start=$broadcast;Source=''}
    if (-not $broadcast -or $Entry.AllDay) { return $fallback }
    if ($null -eq $script:ReleaseRules) {
        $script:ReleaseRules=@()
        if ($script:ProviderSchedulePath -and (Test-Path -LiteralPath $script:ProviderSchedulePath)) {
            $script:ReleaseRules=@(Import-Csv -LiteralPath $script:ProviderSchedulePath)
        }
    }
    $candidates=@{}
    foreach ($rule in (@($Show.ProviderSchedules)+@($script:ReleaseRules))) {
        if (-not $rule -or $rule.provider -notin $ForProviders -or $candidates.ContainsKey([string]$rule.provider)) { continue }
        if ($rule.anilistid) { if ([string]$rule.anilistid -ne [string]$Show.MediaId) { continue } }
        elseif ([string]$rule.title -ne [string]$Show.Title) { continue }
        try {
            # Windows PowerShell cannot resolve most IANA zone IDs. Cache the
            # Windows fallback so each episode does not throw that exception.
            if ($null -eq $script:ProviderTimeZones) { $script:ProviderTimeZones=@{} }
            $zoneKey="$($rule.timezone)|$($rule.windowstimezone)"
            if (-not $script:ProviderTimeZones.ContainsKey($zoneKey)) {
                $resolved=$null
                try { $resolved=[TimeZoneInfo]::FindSystemTimeZoneById([string]$rule.timezone) }
                catch {
                    try { $resolved=[TimeZoneInfo]::FindSystemTimeZoneById([string]$rule.windowstimezone) } catch { }
                }
                $script:ProviderTimeZones[$zoneKey]=$resolved
            }
            $zone=$script:ProviderTimeZones[$zoneKey]
            if (-not $zone) { continue }
            $local=[TimeZoneInfo]::ConvertTimeFromUtc($broadcast,$zone)
            $weekday=[int][DayOfWeek]::Parse([DayOfWeek],[string]$rule.weekday,$true)
            $day=$local.Date.AddDays(($weekday-[int]$local.DayOfWeek+7)%7)
            $date=$day.ToString('yyyy-MM-dd')
            if ($date -lt [string]$rule.validfrom -or $date -gt [string]$rule.validto) { continue }
            $wall=[datetime]::ParseExact(($date+' '+$rule.time),'yyyy-MM-dd HH:mm',[Globalization.CultureInfo]::InvariantCulture)
            if ($zone.IsInvalidTime($wall) -or $zone.IsAmbiguousTime($wall)) { continue }
            $release=[TimeZoneInfo]::ConvertTimeToUtc($wall,$zone)
            $delay=($release-$broadcast).TotalHours
            if ($delay -lt 0 -or $delay -gt 36) { continue }
            $candidates[[string]$rule.provider]=[pscustomobject]@{Start=$release;Source=($rule.provider+' schedule: '+$rule.sourceurl)}
        } catch { continue }
    }
    if ($candidates.Count) { return ($candidates.Values | Sort-Object Start | Select-Object -First 1) }
    return $fallback
}

# Database
# Shows are stored once and episodes reference them by MediaId. The previous
# schema repeated the full synopsis and a description built from it on every
# episode row, which was 1.07 MB of duplicated text in a 2.1 MB file and made
# each keypress in the picker re-serialise the lot.

$script:DbDirty = $false

function ConvertTo-DeepHashtable {
    param($InputObject)
    if ($null -eq $InputObject) { return $null }

    # Unwrap before testing the type. A value that has travelled through a
    # pipeline arrives PSObject-wrapped, and a wrapped string answers True to
    # -is [pscustomobject]; testing the wrapper turns every string in a JSON
    # array into a dictionary of its .Length property. Enumeration below uses
    # foreach statements for the same reason - ForEach-Object re-wraps.
    $value = $InputObject
    if ($value -is [psobject]) { $value = $value.PSObject.BaseObject }

    if ($value -is [System.Collections.IDictionary]) {
        $copy = [ordered]@{}
        foreach ($key in @($value.Keys)) { $copy[[string]$key] = ConvertTo-DeepHashtable $value[$key] }
        return $copy
    }
    if ($value -is [System.Management.Automation.PSCustomObject]) {
        $copy = [ordered]@{}
        foreach ($property in $InputObject.PSObject.Properties) { $copy[$property.Name] = ConvertTo-DeepHashtable $property.Value }
        return $copy
    }
    if ($value -is [System.Collections.IEnumerable] -and $value -isnot [string]) {
        $items = New-Object System.Collections.ArrayList
        foreach ($item in $value) { $null = $items.Add((ConvertTo-DeepHashtable $item)) }
        return $items.ToArray()
    }
    return $value
}

function New-AnimeDatabase {
    param([string]$DefaultDirectory)
    return [ordered]@{
        Version         = 4
        OutputDirectory = $DefaultDirectory
        Selections      = @()
        SelectionHistory= @()
        RetainedCalendarShows = @()
        AppliedSelections=@()
        KnownShows      = @()
        PendingExport   = $false
        PendingUpdates  = @()
        ScrapeBytesTotal= 0
        ScrapeBytesBySource=[ordered]@{}
        EnabledProviders= @()
        ProviderDirectory=[ordered]@{}
        Shows           = [ordered]@{}
        ShowAliases     = [ordered]@{}
        Seasons         = [ordered]@{}
    }
}

function Import-AnimeDatabase {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$DefaultDirectory)
    $database = New-AnimeDatabase -DefaultDirectory $DefaultDirectory
    if (-not (Test-Path -LiteralPath $Path)) { return $database }
    try {
        $loaded = ConvertTo-DeepHashtable (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch {
        Write-Warning "Database could not be read and will be rebuilt: $($_.Exception.Message)"
        return $database
    }
    if ([int]$loaded.Version -ne 4) {
        Write-Warning "Database at $Path is version $($loaded.Version); this script writes version 4. Starting a fresh cache."
        return $database
    }
    foreach ($key in @('OutputDirectory','PendingExport','ScrapeBytesTotal')) { if ($loaded.Contains($key)) { $database[$key] = $loaded[$key] } }
    foreach ($key in @('Selections','SelectionHistory','RetainedCalendarShows','AppliedSelections','KnownShows','PendingUpdates','EnabledProviders')) { if ($loaded.Contains($key)) { $database[$key] = @($loaded[$key]) } }
    $database.SelectionHistory = @(@($database.SelectionHistory) + @($database.Selections) + @($database.AppliedSelections) | Sort-Object -Unique)
    foreach ($key in @('Shows','ShowAliases','Seasons','ProviderDirectory','ScrapeBytesBySource')) { if ($loaded.Contains($key) -and $loaded[$key]) { $database[$key] = $loaded[$key] } }
    if (-not $loaded.Contains('AppliedSelections')) { $database.AppliedSelections = @($database.Selections) }
    if (-not $database.OutputDirectory) { $database.OutputDirectory = $DefaultDirectory }
    return $database
}

function Save-AnimeDatabase {
    # Writes only when something actually changed. Menu toggles mark the
    # database dirty and the flush happens on navigation, so holding a key down
    # in the picker no longer serialises the file once per repeat.
    param([switch]$Force)
    if (-not $script:DbDirty -and -not $Force) { return }
    $script:Db | ConvertTo-Json -Depth 12 -Compress | Set-Content -LiteralPath $script:DbPath -Encoding UTF8
    $script:DbDirty = $false
}

function Set-DatabaseDirty {
    [void]($script:DbDirty = $true)
    $script:DbRevision = [long]$script:DbRevision + 1
}

function Resolve-ShowId {
    param([string]$Id)
    if ($script:Db -and $script:Db.ShowAliases -and $script:Db.ShowAliases.Contains($Id)) { return [string]$script:Db.ShowAliases[$Id] }
    return $Id
}

function Resolve-DuplicateShows {
    # A negative ID is a LiveChart fallback. Match it only to one unambiguous
    # AniList title sharing a provider; never collapse distinct AniList IDs.
    if (-not $script:Db.ShowAliases) { $script:Db.ShowAliases=[ordered]@{} }
    $changed=$false; $byTitle=@{}
    foreach ($show in $script:Db.Shows.Values) {
        if ([long]$show.MediaId -le 0 -or -not $show.Title) { continue }
        $key=([regex]::Replace(([string]$show.Title).Normalize([Text.NormalizationForm]::FormKC),'\s+',' ')).Trim().ToLowerInvariant()
        if (-not $byTitle.ContainsKey($key)) { $byTitle[$key]=New-Object Collections.ArrayList }
        $null=$byTitle[$key].Add($show)
    }
    foreach ($show in $script:Db.Shows.Values) {
        if ([long]$show.MediaId -ge 0 -or -not $show.Title) { continue }
        $key=([regex]::Replace(([string]$show.Title).Normalize([Text.NormalizationForm]::FormKC),'\s+',' ')).Trim().ToLowerInvariant()
        $matches=@(foreach ($candidate in $byTitle[$key]) {
            if (@($show.Providers.Keys | Where-Object { $candidate.Providers.Contains($_) }).Count) { $candidate }
        })
        if ($matches.Count -eq 1 -and $script:Db.ShowAliases[[string]$show.MediaId] -ne [string]$matches[0].MediaId) {
            $script:Db.ShowAliases[[string]$show.MediaId]=[string]$matches[0].MediaId; $changed=$true
        }
    }
    if (-not $script:Db.ShowAliases.Count) { return }
    foreach ($id in $script:Db.ShowAliases.Keys) {
        $source=$script:Db.Shows[$id]; $target=$script:Db.Shows[[string]$script:Db.ShowAliases[$id]]
        if (-not $source -or -not $target) { continue }
        foreach ($provider in $source.Providers.Keys) {
            if (-not $target.Providers.Contains($provider)) { $target.Providers[$provider]=$source.Providers[$provider]; $changed=$true }
        }
    }
    foreach ($field in @('Selections','AppliedSelections','SelectionHistory','KnownShows','RetainedCalendarShows')) {
        $ids=@($script:Db[$field] | ForEach-Object { Resolve-ShowId ([string]$_) } | Sort-Object -Unique)
        if (($ids -join '|') -ne (@($script:Db[$field] | Sort-Object -Unique) -join '|')) {
            $script:Db[$field]=$ids; $changed=$true
            if ($field -in @('Selections','AppliedSelections','RetainedCalendarShows')) { $script:Db.PendingExport=$true }
        }
    }
    $native=@{}; $nativeTimed=@{}
    foreach ($season in $script:Db.Seasons.Values) {
        foreach ($entry in $season.Events) {
            if ((Resolve-ShowId ([string]$entry.MediaId)) -eq [string]$entry.MediaId) {
                $native["$($entry.MediaId)|$($entry.Episode)"]=$true
                if (-not $entry.AllDay) { $nativeTimed[[string]$entry.MediaId]=$true }
            }
        }
    }
    foreach ($season in $script:Db.Seasons.Values) {
        $ids=@($season.ShowIds | ForEach-Object { Resolve-ShowId ([string]$_) } | Sort-Object -Unique)
        if (($ids -join '|') -ne (@($season.ShowIds | Sort-Object -Unique) -join '|')) { $season.ShowIds=$ids; $changed=$true }
        $events=New-Object Collections.ArrayList
        foreach ($entry in $season.Events) {
            $id=Resolve-ShowId ([string]$entry.MediaId)
            if ($id -ne [string]$entry.MediaId) {
                $changed=$true
                if ($native.ContainsKey("$id|$($entry.Episode)") -or ($entry.AllDay -and $nativeTimed.ContainsKey($id))) { continue }
                $copy=[ordered]@{}; foreach ($key in $entry.Keys) { $copy[$key]=$entry[$key] }; $copy.MediaId=$id; $entry=$copy
            }
            $null=$events.Add($entry)
        }
        $season.Events=@($events)
    }
    $seen=@{}; $pending=New-Object Collections.ArrayList
    foreach ($item in $script:Db.PendingUpdates) {
        $id=Resolve-ShowId ([string]$item.MediaId)
        if ($id -ne [string]$item.MediaId) { $item.MediaId=$id; $changed=$true }
        if ($seen.ContainsKey($id)) { $changed=$true; continue }
        $seen[$id]=$true; $null=$pending.Add($item)
    }
    $script:Db.PendingUpdates=@($pending)
    if ($changed) { Update-SelectionHistory; Set-DatabaseDirty }
}
function Update-AnimeDatabase {
    param([scriptblock]$Change,[switch]$Pending,[switch]$Save)
    if($Change){$null=& $Change};if($Pending){[void]($script:Db.PendingExport=$true)};Set-DatabaseDirty;if($Save){Save-AnimeDatabase}
}

# Scraping a season into the database
function Update-SeasonCache {
    param(
        [Parameter(Mandatory)][string]$SeasonName,
        [Parameter(Mandatory)][int]$SeasonYear,
        [switch]$IncludeAired
    )
    $seasonKey = "$SeasonName-$SeasonYear"
    Write-Host "Fetching $SeasonName $SeasonYear from AniList..." -ForegroundColor DarkGray

    # Lifecycle detection needs premieres and finales even if export omits past episodes.
    $query = Get-SeasonMediaQuery -IncludeAired
    $mediaItems = New-Object System.Collections.ArrayList
    $pageNumber = 1
    do {
        $data = Invoke-AniList -Query $query -Variables @{page=$pageNumber;season=$SeasonName;year=$SeasonYear}
        foreach ($item in @($data.Page.media)) { $null = $mediaItems.Add($item) }
        $hasMore = [bool]$data.Page.pageInfo.hasNextPage
        $pageNumber++
    } while ($hasMore)
    Write-Host "  AniList returned $($mediaItems.Count) title(s)." -ForegroundColor DarkGray

    $sources = Get-LineupSources -SeasonName $SeasonName -SeasonYear $SeasonYear -Path $LineupSourcePath
    $sourceText = @{}
    foreach ($name in @($sources.Keys)) { if ($sources[$name]) { $sourceText[$name] = Get-WebPageText $sources[$name] } }
    $providerSchedules=@(Get-CrunchyrollSchedules -Html $sourceText['Crunchyroll'] -SourceUrl $sources['Crunchyroll'] -SeasonName $SeasonName -Year $SeasonYear)
    $dubTitles=@(Get-EnglishDubTitles $sourceText['Crunchyroll'])

    # Merge LiveChart by AniList id. This matters most before a season starts,
    # when AniList often has titles but neither provider links nor a schedule.
    $liveEntries = @()
    if ($sourceText.ContainsKey('LiveChart') -and $sourceText['LiveChart']) {
        $liveEntries = @(Get-LiveChartEntries -Html $sourceText['LiveChart'] -PageUrl $sources['LiveChart'])
        if ($liveEntries.Count -eq 0) {
            Write-Warning 'LiveChart returned a page but no entries could be parsed. Their markup may have changed; provider attribution will rely on AniList links alone.'
        } else {
            Write-Host "  LiveChart contributed $($liveEntries.Count) entry/entries." -ForegroundColor DarkGray
        }
    }

    $mediaById = @{}
    foreach ($media in $mediaItems) { $mediaById[[int]$media.id] = $media }
    foreach ($live in $liveEntries) {
        $media = $null
        if ($live.AniListId -and $mediaById.ContainsKey([int]$live.AniListId)) { $media = $mediaById[[int]$live.AniListId] }
        if ($media) {
            $media | Add-Member -NotePropertyName LiveChartProviderLinks -NotePropertyValue $live.ProviderLinks -Force
            $media | Add-Member -NotePropertyName LiveChartUrl -NotePropertyValue $live.Url -Force
            $media | Add-Member -NotePropertyName LiveChartSchedule -NotePropertyValue @{PremiereAt=$live.AiringAt;Precision=$live.Precision;Releases=@($live.Releases);SourceUrl=$live.Url} -Force
            if ((Test-IncompleteSynopsis (ConvertFrom-AnimeHtml $media.description)) -and $live.Synopsis) {
                $media.description = $live.Synopsis
            }
            continue
        }
        if ($live.ProviderLinks.Count -eq 0) { continue }
        $start = if ($live.AiringAt -gt 0) { [DateTimeOffset]::FromUnixTimeSeconds($live.AiringAt).UtcDateTime } else { $null }
        $mediaItems.Add([pscustomobject]@{
            id            = (-1 * [int]$live.LiveChartId)
            siteUrl       = $live.Url
            MetadataSource= 'LiveChart'
            title         = [pscustomobject]@{romaji=$live.Romaji;english=$live.English;native=''}
            description   = $live.Synopsis
            duration      = 30
            status        = $(if($start -and $start -le [datetime]::UtcNow){'RELEASING'}else{'NOT_YET_RELEASED'})
            genres        = @($live.Tags)
            tags          = @($live.Tags | ForEach-Object {[pscustomobject]@{name=$_;rank=0;isMediaSpoiler=$false}})
            externalLinks = @()
            relations     = [pscustomobject]@{edges=@()}
            LiveChartProviderLinks = $live.ProviderLinks
            LiveChartUrl  = $live.Url
            LiveChartSchedule = @{PremiereAt=$live.AiringAt;Precision=$live.Precision;Releases=@($live.Releases);SourceUrl=$live.Url}
            startDate     = [pscustomobject]@{year=$(if($start){$start.Year});month=$(if($start){$start.Month});day=$(if($start){$start.Day})}
            airingSchedule= [pscustomobject]@{nodes=@($live.Releases)}
        }) | Out-Null
    }

    $overrides = @{}
    if ($ProviderOverridesPath) {
        foreach ($row in @(Import-Csv -LiteralPath $ProviderOverridesPath)) {
            if ($row.AniListId -and $row.Provider) { $overrides[[int]$row.AniListId] = $row }
        }
    }

    Write-Host '  Resolving synopses...' -ForegroundColor DarkGray
    $synopsisById = Resolve-SeriesSynopses -Media $mediaItems

    $previousEvents = @{}
    if ($script:Db.Seasons.Contains($seasonKey)) {
        foreach ($old in @($script:Db.Seasons[$seasonKey].Events)) {
            $previousEvents["$($old.MediaId)|$($old.Episode)"] = $old
        }
    }

    $events = New-Object System.Collections.ArrayList
    $shows  = @{}
    foreach ($media in $mediaItems) {
        $serviceLinks = [ordered]@{}
        foreach ($link in @($media.externalLinks)) {
            if($link.type -ne 'STREAMING'){continue}
            $service = Get-ProviderFromLink $link
            Register-Provider $service ([string]$link.url)
            if ($service -and -not $serviceLinks.Contains($service)) { $serviceLinks[$service] = [string]$link.url }
        }
        if ($media.PSObject.Properties.Name -contains 'LiveChartProviderLinks') {
            foreach ($service in @($media.LiveChartProviderLinks.Keys)) {
                Register-Provider $service ([string]$media.LiveChartProviderLinks[$service])
                if (-not $serviceLinks.Contains($service)) { $serviceLinks[$service] = $media.LiveChartProviderLinks[$service] }
            }
        }
        if ($overrides.ContainsKey([int]$media.id)) {
            $row = $overrides[[int]$media.id]
            $serviceLinks[[string]$row.Provider] = [string]$row.Url
        }
        foreach ($service in @($sources.Keys)) {
            if ($service -eq 'LiveChart') { continue }
            if (-not $serviceLinks.Contains($service) -and
                $sourceText.ContainsKey($service) -and (Test-MediaOnPage $media $sourceText[$service])) {
                $serviceLinks[$service] = $sources[$service]
            }
        }
        if ($serviceLinks.Count -eq 0) { continue }

        $mediaId = [string]$media.id
        $previousShow=$script:Db.Shows[$mediaId]
        $schedule=if ($media.LiveChartSchedule) { $media.LiveChartSchedule } else { $previousShow.LiveChartSchedule }
        if ($media.LiveChartSchedule -and $previousShow.LiveChartSchedule -and $previousShow.LiveChartSchedule.PremiereAt -eq $schedule.PremiereAt) {
            $knownReleases=@{}
            foreach ($node in (@($previousShow.LiveChartSchedule.Releases)+@($schedule.Releases))) { if ($node) { $knownReleases[[string]$node.episode]=$node } }
            $schedule.Releases=@($knownReleases.Values)
        }
        $title = if ($media.title.english) { $media.title.english } else { $media.title.romaji }
        $shows[$mediaId] = [ordered]@{
            MediaId        = $mediaId
            Title          = $title
            Synopsis       = [string]$synopsisById[[int]$media.id]
            IsFantasyGroup = [bool](Test-FantasyIsekaiReincarnation $media)
            SiteUrl        = [string]$media.siteUrl
            Popularity     = [int]$media.popularity
            Status         = [string]$media.status
            TotalEpisodes  = [int]$media.episodes
            EnglishDub     = $(if ($script:Db.Shows.Contains($mediaId)) { $script:Db.Shows[$mediaId].EnglishDub } else { @{} })
            LiveChartSchedule = $schedule
            EndDate        = $(if ($media.endDate.year -and $media.endDate.month -and $media.endDate.day) { '{0:0000}-{1:00}-{2:00}' -f [int]$media.endDate.year,[int]$media.endDate.month,[int]$media.endDate.day } else { $null })
            Providers      = $serviceLinks
            ProviderSchedules = @($providerSchedules | Where-Object { $_.title -eq $title })
        }

        $duration = if ([int]$media.duration -gt 0) { [int]$media.duration } else { 30 }
        if ($title -in $dubTitles) {
            if (-not $shows[$mediaId].EnglishDub) { $shows[$mediaId].EnglishDub=@{} }
            $shows[$mediaId].EnglishDub.Announced=$true
        }
        $byEpisode=@{}
        foreach ($node in (@($media.airingSchedule.nodes)+@($media.upcomingSchedule.nodes))) {
            if ($node) { $byEpisode[[string]$node.episode]=$node }
        }
        $airings = @($byEpisode.Values)
        $resolved=Resolve-LiveChartAirings $airings $schedule -ConflictFrom ([int]$previousShow.ScheduleConflictFrom)
        $airings=@($resolved.Airings)
        $shows[$mediaId].ScheduleConflictFrom=$resolved.ConflictFrom
        if ([long]$schedule.PremiereAt -gt 0 -and [int]$schedule.Precision -ge 3) {
            $premiere=[DateTimeOffset]::FromUnixTimeSeconds([long]$schedule.PremiereAt).UtcDateTime
            $media.startDate=[pscustomobject]@{year=$premiere.Year;month=$premiere.Month;day=$premiere.Day}
        }
        foreach ($airing in $airings) {
            $start = [DateTimeOffset]::FromUnixTimeSeconds([long]$airing.airingAt).UtcDateTime
            $key = "$mediaId|$($airing.episode)"
            $sequence = 0
            if ($previousEvents.ContainsKey($key)) {
                $sequence = [int]$previousEvents[$key].Sequence
                # A moved airtime must advertise a new SEQUENCE or subscribed
                # clients keep showing the old slot.
                if ([string]$previousEvents[$key].StartUtc -ne (ConvertTo-UtcStamp $start)) { $sequence++ }
            }
            $null = $events.Add([ordered]@{
                MediaId         = $mediaId
                Episode         = [string]$airing.episode
                AllDay          = $false
                StartUtc        = (ConvertTo-UtcStamp $start)
                Date            = $null
                DurationMinutes = $duration
                Sequence        = $sequence
                TimingSource    = $(if ($airing.TimingSource) { $airing.TimingSource } else { 'AniList' })
                SourceUrl       = $(if ($airing.SourceUrl) { $airing.SourceUrl } else { $media.siteUrl })
            })
        }
        if ($airings.Count -eq 0 -and $media.startDate.year -and $media.startDate.month) {
            # Announced shows usually have a month long before they have a day,
            # which is the normal state of an upcoming season. Treating that as
            # "no date" dropped the title from the picker entirely, so a
            # month-only premiere becomes a placeholder on the first of the
            # month, labelled as approximate. When the real date is published
            # the stored date changes, SEQUENCE increments, and subscribed
            # calendars move the entry.
            $precise = [bool]$media.startDate.day
            $day = if ($precise) { [int]$media.startDate.day } else { 1 }
            # Stored as a plain date. Serialising a DateTime here is what made
            # all-day events land a day early east of UTC.
            $dateText = '{0:0000}-{1:00}-{2:00}' -f [int]$media.startDate.year,[int]$media.startDate.month,$day
            $key = "$mediaId|release"
            $sequence = 0
            if ($previousEvents.ContainsKey($key)) {
                $sequence = [int]$previousEvents[$key].Sequence
                if ([string]$previousEvents[$key].Date -ne $dateText) { $sequence++ }
            }
            $null = $events.Add([ordered]@{
                MediaId         = $mediaId
                Episode         = 'release'
                AllDay          = $true
                StartUtc        = $null
                Date            = $dateText
                DurationMinutes = 0
                Sequence        = $sequence
                DatePrecision   = $(if ($precise) { 'Day' } else { 'Month' })
            })
        }
    }

    foreach ($mediaId in $shows.Keys) { $script:Db.Shows[$mediaId] = $shows[$mediaId] }
    foreach ($cached in $script:Db.Seasons.Values) {
        $cached.Events=@($cached.Events | Where-Object { Test-ReleaseAllowed $_ $script:Db.Shows[[string]$_.MediaId] })
    }
    if($AllDiscoveredProviders){$script:Db.EnabledProviders=@($script:Db.ProviderDirectory.Keys|Sort-Object);$Providers=@($script:Db.EnabledProviders)}

    # The season records its shows explicitly. Deriving the list from events
    # instead hid every title that has a provider but no published date yet -
    # most of an upcoming season.
    $showIds = @($shows.Keys | Sort-Object)
    $approximate = @($events | Where-Object { $_.DatePrecision -eq 'Month' }).Count
    $datedIds = @{}
    foreach ($entry in $events) { $datedIds[[string]$entry.MediaId] = $true }
    $undated = @($showIds | Where-Object { -not $datedIds.ContainsKey([string]$_) }).Count
    # A season keeps being re-checked while any premiere is still approximate or
    # missing, which is what drives the startup update check.
    $complete = ($events.Count -gt 0) -and ($approximate -eq 0) -and ($undated -eq 0) -and
                (@($events | Where-Object { -not $_.MediaId -or (-not $_.StartUtc -and -not $_.Date) }).Count -eq 0)

    $script:Db.Seasons[$seasonKey] = [ordered]@{
        Season      = $SeasonName
        Year        = $SeasonYear
        UpdatedUtc  = [datetime]::UtcNow.ToString('o')
        Complete    = $complete
        IncludesAired = $true
        ProviderCacheComplete = $true
        SchedulePriorityVersion = 1
        ShowIds     = $showIds
        Events      = @($events)
    }
    Resolve-DuplicateShows
    Set-DatabaseDirty
    Save-AnimeDatabase
    $note = ''
    if ($approximate -gt 0) { $note += "  $approximate premiere(s) are month-only placeholders." }
    if ($undated -gt 0) { $note += "  $undated show(s) have no announced date yet." }
    Write-Host "  Cached $($events.Count) episode(s) across $($shows.Count) show(s).$note" -ForegroundColor DarkGray
    return $script:Db.Seasons[$seasonKey]
}

function Test-ReleaseAllowed {
    param($Entry,$Show)
    if ($Entry.AirType -eq 'dub') { return $true }
    $number=0
    $null=[int]::TryParse([string]$Entry.Episode,[ref]$number)
    foreach ($node in @($Show.LiveChartSchedule.Releases)) {
        if ($node -and [int]$node.episode -eq $number) {
            return ($Entry.TimingSource -eq 'LiveChart' -and (Get-EventInstant $Entry) -eq [DateTimeOffset]::FromUnixTimeSeconds([long]$node.airingAt).UtcDateTime)
        }
    }
    if ($number -gt 0 -and [int]$Show.ScheduleConflictFrom -gt 0 -and $number -ge [int]$Show.ScheduleConflictFrom) { return $false }
    if ($Entry.Episode -eq 'release' -and $Show.LiveChartSchedule.Releases) { return $false }
    return $true
}

function Get-SeasonData {
    param([Parameter(Mandatory)][string]$SeasonName,[Parameter(Mandatory)][int]$SeasonYear,[switch]$ForceRefresh)
    $seasonKey = "$SeasonName-$SeasonYear"
    $cached = $script:Db.Seasons.Contains($seasonKey)
    $needsAired = $IncludePastEpisodes -and $cached -and -not $script:Db.Seasons[$seasonKey].IncludesAired
    $needsSchedule=$false
    if ($cached -and -not ([string]$script:Db.Seasons[$seasonKey].UpdatedUtc).StartsWith([datetime]::UtcNow.ToString('yyyy-MM-dd'))) {
        foreach ($id in (Get-SeasonShowIds $script:Db.Seasons[$seasonKey])) { if ($script:Db.Shows[$id].ScheduleConflictFrom) { $needsSchedule=$true; break } }
    }
    if ($cached -and $script:Db.Seasons[$seasonKey].ProviderCacheComplete -and $script:Db.Seasons[$seasonKey].SchedulePriorityVersion -eq 1 -and -not $ForceRefresh -and -not $needsAired -and -not $needsSchedule) {
        Write-Host "Using cached metadata for $SeasonName $SeasonYear from $($script:Db.Seasons[$seasonKey].UpdatedUtc)." -ForegroundColor DarkGray
        return $script:Db.Seasons[$seasonKey]
    }
    if ($needsAired) { Write-Host 'Cached season has future episodes only; re-scraping to include aired ones.' -ForegroundColor DarkGray }
    return (Update-SeasonCache -SeasonName $SeasonName -SeasonYear $SeasonYear -IncludeAired:$IncludePastEpisodes)
}

function Get-SeasonShowIds {
    # The shows belonging to a season, including any with no dated episode yet.
    # Falls back to the event list for caches written before ShowIds existed.
    param($SeasonData)
    if (-not $SeasonData) { return @() }
    $ids = @{}
    foreach ($id in @($SeasonData.ShowIds)) { if ($id) { $ids[[string]$id] = $true } }
    if ($ids.Count -eq 0) {
        foreach ($entry in @($SeasonData.Events)) { $ids[[string]$entry.MediaId] = $true }
    }
    # Source lineup membership is authoritative, including early premieres.
    return @($ids.Keys)
}

function Get-SeasonShowView {
    # Share release calculations across membership, completion and row loading.
    # The scope ends before any user input or database/provider changes.
    param($Period,$SeasonData,[string]$Filter='All')
    $now=[datetime]::UtcNow
    if (-not $script:ShowViewCache -or -not [object]::ReferenceEquals($script:ShowViewCache.Db,$script:Db) -or $script:ShowViewCache.Revision -ne [long]$script:DbRevision) {
        $script:ShowViewCache=@{Db=$script:Db;Revision=[long]$script:DbRevision;Entries=@{}}
    }
    $key="$($Period.Season)|$($Period.Year)|$($Period.View)|$Filter|$($script:Db.EnabledProviders -join ',')"
    $cached=$script:ShowViewCache.Entries[$key]
    if ($cached -and $now -lt $cached.Expires) { return @($cached.Rows) }
    $previous=$script:BrowseReleaseTimes
    $previousInstants=$script:BrowseEventInstants
    $script:BrowseReleaseTimes=@{}
    $script:BrowseEventInstants=@{}
    try {
        if ($Period.View -eq 'Last') { $SeasonData=Get-SeasonViewData $Period }
        $rows=@(Get-SeasonShows $SeasonData -Filter $Filter -View $Period.View -Now $now)
        $expires=$now.Date.AddDays(1)
        foreach ($instant in @($script:BrowseEventInstants.Values)) {
            if ($instant -and $instant -gt $now -and $instant -lt $expires) { $expires=$instant }
        }
        foreach ($release in $script:BrowseReleaseTimes.Values) {
            if ($release.Start -gt $now -and $release.Start -lt $expires) { $expires=$release.Start }
        }
        $script:ShowViewCache.Entries[$key]=@{Rows=$rows;Expires=$expires}
        return $rows
    } finally { $script:BrowseReleaseTimes=$previous; $script:BrowseEventInstants=$previousInstants }
}

function Get-SeasonShows {
    # Show-level projection used by the picker.
    param([Parameter(Mandatory)]$SeasonData,[string]$Filter='All',[string]$View='',[datetime]$Now=[datetime]::UtcNow)
    $nowUtc = $Now
    $byShow = @{}
    foreach ($id in (Get-SeasonShowIds $SeasonData)) {
        if ($script:Db.Shows.Contains([string]$id)) { $byShow[[string]$id] = New-Object System.Collections.ArrayList }
    }
    $seenEvents = @{}
    foreach ($entry in @($script:Db.Seasons.Values | ForEach-Object { $_.Events })) {
        $id = [string]$entry.MediaId
        if (-not $byShow.ContainsKey($id)) { continue }
        $eventKey = "$id|$($entry.Episode)|$($entry.StartUtc)|$($entry.Date)"
        if ($seenEvents.ContainsKey($eventKey)) { continue }
        $seenEvents[$eventKey] = $true
        $null = $byShow[$id].Add($entry)
    }
    $eventsByShow = @{}
    foreach ($id in $byShow.Keys) { $eventsByShow[$id] = @($byShow[$id] | Where-Object { -not $_.AllDay }) }
    $result = foreach ($id in $byShow.Keys) {
        $show = $script:Db.Shows[$id]
        if (($Filter -eq 'FantasyIsekaiReincarnation' -and -not $show.IsFantasyGroup) -or
            ($Filter -eq 'ExcludeFantasyIsekaiReincarnation' -and $show.IsFantasyGroup)) { continue }
        $finished=Test-ShowFinished $id -Now $nowUtc -EventsByShow $eventsByShow
        if (-not (Test-ShowAvailable $show) -or ($finished -and $View -ne 'Last')) { continue }
        $selectable=(-not $finished) -or (Test-DubPending $show $nowUtc)
        $ended=if ($View -eq 'Last' -and -not $selectable) { Get-ShowEndedAt $id $nowUtc $eventsByShow } else { $null }
        $enabled=@($show.Providers.Keys | Where-Object { $_ -in $script:Db.EnabledProviders })
        $entries=@($byShow[$id]) + @($show.EnglishDub.Events | Where-Object { $_ })
        $recent=@(foreach ($entry in $entries) {
            $broadcast=Get-EventInstant $entry
            if ($broadcast -and $broadcast -ge $nowUtc.AddHours(-36)) { $entry }
        })
        $instants = @($recent | ForEach-Object { [pscustomobject]@{ Event=$_; When=(Get-ProviderReleaseTime $_ $show $enabled).Start } } | Where-Object { $_.When })
        $next = $null
        foreach ($candidate in $instants) { if ($candidate.When -ge $nowUtc -and (-not $next -or $candidate.When -lt $next.When)) { $next = $candidate } }
        $refreshAt=$nowUtc.Date.AddDays(1)
        if ($View -eq 'Last') {
            foreach ($entry in $recent) {
                $instant=(Get-ProviderReleaseTime $entry $show @($show.Providers.Keys)).Start
                if ($instant -and $instant -gt $nowUtc -and $instant -lt $refreshAt) { $refreshAt=$instant }
            }
        }
        [pscustomobject]@{
            MediaId        = $id
            Title          = [string]$show.Title
            Synopsis       = [string]$show.Synopsis
            IsFantasyGroup = [bool]$show.IsFantasyGroup
            Providers      = @($show.Providers.Keys | Where-Object { $_ -in $script:Db.EnabledProviders })
            NextEvent      = $(if ($next) { $next.Event } else { $null })
            NextWhen       = $(if ($next) { $next.When } else { $null })
            EpisodeCount   = $byShow[$id].Count
            Selectable     = $selectable
            LastView       = ($View -eq 'Last')
            LifecycleRefreshAt = $refreshAt
            EndedLabel     = $(if (-not $selectable) { '(Ended {0}) ' -f $(if ($ended) { $ended.ToLocalTime().ToString('MM/dd/yy') } else { 'date unknown' }) } else { '' })
        }
    }
    $result = @($result | Where-Object {
        $Filter -eq 'All' -or
        ($Filter -eq 'FantasyIsekaiReincarnation' -and $_.IsFantasyGroup) -or
        ($Filter -eq 'ExcludeFantasyIsekaiReincarnation' -and -not $_.IsFantasyGroup)
    })
    return @($result | Sort-Object Title)
}


# Menus
function Test-ConsoleInput {
    # Decides whether the menus can run at all. A redirected or non-console host
    # cannot serve [Console]::ReadKey, so the script falls back to the
    # non-interactive path instead of throwing.
    if ($Host.Name -ne 'ConsoleHost') { return $false }
    try { $null = [Console]::KeyAvailable; return $true } catch { return $false }
}

function Get-MenuPageSize {
    $height = 20
    try { if ($Host.UI.RawUI.WindowSize.Height -gt 8) { $height = $Host.UI.RawUI.WindowSize.Height } } catch { }
    return [math]::Max(5,$height - 8)
}

function Read-MenuKey {
    param([hashtable]$FrameState)
    if ($FrameState -and $FrameState.Geometry) {
        while (-not [Console]::KeyAvailable) {
            $geometry=Get-MenuGeometry
            if (-not $geometry -or $geometry.Signature -ne $FrameState.Geometry.Signature) {
                return [pscustomobject]@{Key='Resize'}
            }
            Start-Sleep -Milliseconds 10
        }
    }
    return [Console]::ReadKey($true)
}

function Get-MenuGeometry {
    try {
        if ([Console]::IsOutputRedirected -or [Console]::IsInputRedirected) { return $null }
        $width=[Console]::WindowWidth; $height=[Console]::WindowHeight
        if ($width -lt 2 -or $height -lt 2) { return $null }
        return [pscustomobject]@{Width=$width;Height=$height;Left=[Console]::WindowLeft;Top=[Console]::WindowTop;
            Signature="$width|$height|$([Console]::WindowLeft)|$([Console]::WindowTop)|$([Console]::BufferWidth)|$([Console]::BufferHeight)"}
    } catch { return $null }
}

function New-MenuLine {
    param([string]$Text='',[string]$Color='Gray')
    [pscustomobject]@{Text=$Text;Color=$Color}
}

function Get-MenuText {
    param([string]$Text,[int]$Width)
    $text=$Text -replace '[\r\n\t]',' '
    # Measure terminal cells rather than characters (e.g. Japanese titles).
    while ($text.Length) {
        try { $cells=$Host.UI.RawUI.LengthInBufferCells($text) } catch { $cells=$text.Length }
        if ($cells -le $Width) { break }
        $elements=[Globalization.StringInfo]::ParseCombiningCharacters($text)
        $text=$text.Substring(0,$elements[$elements.Length-1])
    }
    return $text
}

function Set-MenuCursor {
    param([int]$Left,[int]$Top)
    [Console]::SetCursorPosition($Left,$Top)
}

function Write-MenuRow {
    param($Geometry,[int]$Row,$Line)
    Set-MenuCursor $Geometry.Left ($Geometry.Top+$Row)
    Write-Host (' ' * ($Geometry.Width-1)) -NoNewline
    Set-MenuCursor $Geometry.Left ($Geometry.Top+$Row)
    Write-Host (Get-MenuText $Line.Text ($Geometry.Width-1)) -ForegroundColor $Line.Color -NoNewline
}

function Write-MenuFrame {
    param([hashtable]$State,[array]$Lines,[string]$Layout)
    $geometry=Get-MenuGeometry
    if (-not $geometry) {
        Clear-Host
        foreach ($line in $Lines) { Write-Host $line.Text -ForegroundColor $line.Color }
        $State.Clear()
        return
    }
    $visible=@($Lines | Select-Object -First ($geometry.Height-1))
    $full = -not $State.Geometry -or $State.Geometry.Signature -ne $geometry.Signature -or
        $State.Layout -ne $Layout -or $State.Lines.Count -ne $visible.Count
    try {
        if ($full) { Clear-Host; $geometry=Get-MenuGeometry; if (-not $geometry) { throw 'Console unavailable' } }
        for ($row=0; $row -lt $visible.Count; $row++) {
            if ($full -or $visible[$row].Text -cne $State.Lines[$row].Text -or $visible[$row].Color -ne $State.Lines[$row].Color) {
                Write-MenuRow $geometry $row $visible[$row]
            }
        }
        Set-MenuCursor $geometry.Left ($geometry.Top+[math]::Min($visible.Count,$geometry.Height-1))
        $State.Geometry=$geometry; $State.Lines=$visible; $State.Layout=$Layout
    } catch {
        # A resize can invalidate coordinates between measuring and writing.
        $State.Clear()
        Clear-Host
        foreach ($line in $Lines) { Write-Host $line.Text -ForegroundColor $line.Color }
    }
}

function Get-MenuViewport {
    param([int]$Count,[int]$Selected,[int]$Reserved=5)
    $geometry=Get-MenuGeometry
    $height=if ($geometry) { $geometry.Height } else { (Get-MenuPageSize)+8 }
    $size=[math]::Max(1,$height-$Reserved-1)
    $top=[int][math]::Floor($Selected/$size)*$size
    [pscustomobject]@{Top=$top;End=[math]::Min($Count,$top+$size);Size=$size}
}
$script:GenreItems=@([pscustomobject]@{Label='All anime';Value='All'},[pscustomobject]@{Label='Fantasy, isekai, and reincarnation';Value='FantasyIsekaiReincarnation'},[pscustomobject]@{Label='Other';Value='ExcludeFantasyIsekaiReincarnation'})
function Test-ShowAvailable {
    param($Show)
    return ($null -ne $Show -and @($Show.Providers.Keys | Where-Object { $_ -in $script:Db.EnabledProviders }).Count -gt 0)
}

function Get-ShowEventIndex {
    $index=@{}
    foreach ($season in $script:Db.Seasons.Values) {
        foreach ($entry in $season.Events) {
            if ($entry.AllDay) { continue }
            $id=[string]$entry.MediaId
            if (-not $index.ContainsKey($id)) { $index[$id]=New-Object Collections.ArrayList }
            $null=$index[$id].Add($entry)
        }
    }
    return $index
}

function Test-ShowFinished {
    param([string]$MediaId,[datetime]$Now=[datetime]::UtcNow,[hashtable]$EventsByShow)
    $show = $script:Db.Shows[$MediaId]
    if (-not $show) { return $false }
    $events = if ($null -ne $EventsByShow) {
        if ($EventsByShow.ContainsKey($MediaId)) { @($EventsByShow[$MediaId]) } else { @() }
    } else { @($script:Db.Seasons.Values | ForEach-Object { $_.Events } | Where-Object { [string]$_.MediaId -eq $MediaId -and -not $_.AllDay }) }
    $final=$null
    foreach ($entry in $events) {
        $instant=Get-EventInstant $entry
        if (-not $instant) { continue }
        if ($instant -gt $Now) { return $false }
        # Provider rules only shift a broadcast forward by at most 36 hours.
        if ($instant -gt $Now.AddHours(-36) -and (Get-ProviderReleaseTime $entry $show @($show.Providers.Keys)).Start -gt $Now) { return $false }
        if ([int]$show.TotalEpisodes -gt 0 -and [string]$entry.Episode -eq [string]$show.TotalEpisodes) {
            if (-not $final -or [string]$entry.StartUtc -gt [string]$final.StartUtc) { $final=$entry }
        }
    }
    if ($final) { return ((Get-ProviderReleaseTime $final $show @($show.Providers.Keys)).Start -le $Now) }
    if ($show.ScheduleConflictFrom) { return $false }
    # Older scrapes serialized PowerShell's no-output value as {}. Treat it,
    # partial dates and malformed strings as unknown instead of aborting menus.
    $endDate=[datetime]::MinValue
    if ($show.EndDate -is [datetime]) { return ($show.EndDate.Date -lt $Now.Date) }
    if ($show.EndDate -is [string] -and [datetime]::TryParseExact($show.EndDate,'yyyy-MM-dd',$script:Invariant,[Globalization.DateTimeStyles]::None,[ref]$endDate)) {
        return ($endDate.Date -lt $Now.Date)
    }
    return ($show.Status -eq 'FINISHED')
}

function Update-SelectionHistory {
    $script:Db.SelectionHistory = @(@($script:Db.SelectionHistory) + @($script:Db.Selections) + @($script:Db.AppliedSelections) | Sort-Object -Unique)
    $script:Db.PendingUpdates = @($script:Db.PendingUpdates | Where-Object { [string]$_.MediaId -notin $script:Db.SelectionHistory })
    Set-DatabaseDirty
}

function Get-VisiblePendingUpdates {
    Update-SelectionHistory
    $eventsByShow=Get-ShowEventIndex
    return @($script:Db.PendingUpdates | Where-Object { (Test-ShowAvailable $script:Db.Shows[[string]$_.MediaId]) -and -not (Test-ShowFinished ([string]$_.MediaId) -EventsByShow $eventsByShow) })
}

function Get-PreviousAnimeSeason {
    param($Period)
    $names=@('WINTER','SPRING','SUMMER','FALL')
    $index=[array]::IndexOf($names,[string]$Period.Season)
    [pscustomobject]@{Season=$names[($index+3)%4];Year=([int]$Period.Year-[int]($index -eq 0))}
}

function Get-SeasonNumber {
    param($Period)
    return ([int]$Period.Year*4+[array]::IndexOf(@('WINTER','SPRING','SUMMER','FALL'),[string]$Period.Season))
}

function Test-SeasonStarted {
    param($Period,[datetime]$Now)
    $data=$script:Db.Seasons["$($Period.Season)-$($Period.Year)"]
    foreach ($entry in @($data.Events)) {
        if ($entry.AllDay -or [string]$entry.Episode -ne '1') { continue }
        $show=$script:Db.Shows[[string]$entry.MediaId]
        $instant=(Get-ProviderReleaseTime $entry $show @($show.Providers.Keys)).Start
        if ($instant -and $instant -le $Now) { return $true }
    }
    return $false
}

function Get-SeasonContext {
    param($Current,[datetime]$Now=[datetime]::UtcNow)
    $prior=Get-PreviousAnimeSeason $Current
    $data=$script:Db.Seasons["$($Current.Season)-$($Current.Year)"]
    $hasPremiere=@($data.Events | Where-Object { [string]$_.Episode -eq '1' -and -not $_.AllDay -and (Get-EventInstant $_) }).Count -gt 0
    if ($hasPremiere -and $script:Db.Seasons["$($prior.Season)-$($prior.Year)"] -and -not (Test-SeasonStarted $Current $Now)) { $Current=$prior }
    while (Test-SeasonStarted (Get-NextAnimeSeason $Current) $Now) { $Current=Get-NextAnimeSeason $Current }
    $index=Get-ShowEventIndex
    $ended=$false
    foreach ($id in (Get-SeasonShowIds $script:Db.Seasons["$($Current.Season)-$($Current.Year)"])) {
        if (Test-ShowFinished $id -Now $Now -EventsByShow $index) { $ended=$true; break }
    }
    $last=if ($ended) { $Current } else { Get-PreviousAnimeSeason $Current }
    if (-not $ended -and -not $script:Db.Seasons["$($last.Season)-$($last.Year)"]) { $last=$null }
    [pscustomobject]@{Current=$Current;Last=$last;Index=$index}
}

function Test-DubPending {
    param($Show,[datetime]$Now=[datetime]::UtcNow)
    $dub=$Show.EnglishDub
    if (-not $dub.Announced) { return $false }
    $total=if ([int]$dub.TotalEpisodes -gt 0) { [int]$dub.TotalEpisodes } else { [int]$Show.TotalEpisodes }
    $finalAired=$false
    foreach ($entry in @($dub.Events)) {
        $instant=Get-EventInstant $entry
        if ($instant -and $instant -gt $Now) { return $true }
        if ($total -gt 0 -and [string]$entry.Episode -eq [string]$total -and $instant -and $instant -le $Now) { $finalAired=$true }
    }
    return (-not $finalAired)
}

function Get-ShowEndedAt {
    param([string]$MediaId,[datetime]$Now,[hashtable]$Index)
    $show=$script:Db.Shows[$MediaId]
    $latest=[datetime]::MinValue
    $candidates=@(foreach ($entry in (@($Index[$MediaId])+@($show.EnglishDub.Events))) {
        if (-not $entry) { continue }
        $instant=Get-EventInstant $entry
        if ($instant -and $instant -le $Now) {
            if ($instant -gt $latest) { $latest=$instant }
            @{Entry=$entry;When=$instant}
        }
    })
    $dates=@(foreach ($candidate in $candidates) {
        if (($latest-$candidate.When).TotalHours -gt 36) { continue }
        $instant=(Get-ProviderReleaseTime $candidate.Entry $show @($show.Providers.Keys)).Start
        if ($instant -and $instant -le $Now) { $instant }
    })
    $endDate=[datetime]::MinValue
    if ($show.EndDate -is [string] -and [datetime]::TryParseExact($show.EndDate,'yyyy-MM-dd',$script:Invariant,[Globalization.DateTimeStyles]::None,[ref]$endDate) -and $endDate -le $Now) { $dates += $endDate.ToUniversalTime() }
    return ($dates | Sort-Object | Select-Object -Last 1)
}

function Get-SeasonViewData {
    param($Period,[datetime]$Now=[datetime]::UtcNow)
    $data=$script:Db.Seasons["$($Period.Season)-$($Period.Year)"]
    if ($Period.View -ne 'Last') { return $data }
    $context=Get-SeasonContext (Get-AnimeSeason $Now) $Now
    $ids=@{}
    foreach ($cached in $script:Db.Seasons.Values) {
        if ((Get-SeasonNumber $cached) -gt (Get-SeasonNumber $Period)) { continue }
        foreach ($id in (Get-SeasonShowIds $cached)) {
            if ((Get-SeasonNumber $cached) -eq (Get-SeasonNumber $Period) -and
                (Get-SeasonNumber $cached) -ne (Get-SeasonNumber $context.Current)) { $ids[$id]=$true; continue }
            $finished=Test-ShowFinished $id -Now $Now -EventsByShow $context.Index
            if ((Get-SeasonNumber $cached) -eq (Get-SeasonNumber $Period)) {
                if ((Get-SeasonNumber $cached) -ne (Get-SeasonNumber $context.Current) -or $finished) { $ids[$id]=$true }
            } elseif (-not $finished -or (Test-DubPending $script:Db.Shows[$id] $Now)) { $ids[$id]=$true }
        }
    }
    return @{Season=$Period.Season;Year=$Period.Year;ShowIds=@($ids.Keys);Events=@()}
}

function Get-SeasonMenuItems {
    param($Current,[datetime]$Now=[datetime]::UtcNow)
    $context=Get-SeasonContext $Current $Now
    $Current=$context.Current
    $next=Get-NextAnimeSeason $Current
    $future=Get-NextAnimeSeason $next
    if ($context.Last) {
        $last=$context.Last
        [pscustomobject]@{Label="Last - $($last.Season) $($last.Year)";Value=[pscustomobject]@{Season=$last.Season;Year=$last.Year;View='Last'}}
    }
    [pscustomobject]@{Label="Current - $($Current.Season) $($Current.Year)";Value=[pscustomobject]@{Season=$Current.Season;Year=$Current.Year;View='Current'}}
    [pscustomobject]@{Label="Next - $($next.Season) $($next.Year)";Value=$next}
    [pscustomobject]@{Label="Future - $($future.Season) $($future.Year)";Value=$future}
}

function Update-EnglishDubs {
    try {
        $raw=Get-WebPageText 'https://tsuzuki.top/api/v1/overrides'
        if (-not $raw) { return }
        $payload=ConvertTo-DeepHashtable ($raw | ConvertFrom-Json)
        if (-not $payload.ok -or -not ($payload.shows -is [Collections.IDictionary])) { return }
    } catch { return }
    $today=[datetime]::UtcNow.ToString('yyyy-MM-dd')
    foreach ($id in @($script:Db.Shows.Keys)) {
        $show=$script:Db.Shows[$id]
        $old=$show.EnglishDub
        if (-not $payload.shows[$id].dub -and -not $old.Announced) { continue }
        if ([int]$id -le 0 -or ([string]$old.UpdatedUtc).StartsWith($today)) { continue }
        $url="https://tsuzuki.top/api/v1/anime/$id"
        try {
            $raw=Get-WebPageText $url
            if (-not $raw) { continue }
            $result=ConvertTo-DeepHashtable ($raw | ConvertFrom-Json)
            if (-not $result.ok -or -not $result.Contains('episodes')) { continue }
            $events=@(foreach ($episode in @($result.episodes)) {
                if ($episode.airType -ne 'dub' -or $episode.isBreak -or -not $episode.airingAt -or $episode.estimated -or -not $episode.exact) { continue }
                [ordered]@{MediaId=[string]$id;Episode=[string]$episode.episode;AirType='dub';Provider=$episode.platform;AllDay=$false
                    StartUtc=(ConvertTo-UtcStamp ([DateTimeOffset]::FromUnixTimeSeconds([long]$episode.airingAt).UtcDateTime))
                    DurationMinutes=$(if ([int]$result.anime.duration -gt 0) { [int]$result.anime.duration } else { 30 });Sequence=0;SourceUrl=$url}
            })
            $show.EnglishDub=@{Announced=$true;Events=$events;TotalEpisodes=$(if ([int]$result.anime.episodes -gt 0) { [int]$result.anime.episodes } else { [int]$old.TotalEpisodes });SourceUrl=$url;UpdatedUtc=[datetime]::UtcNow.ToString('o')}
            Set-DatabaseDirty
        } catch { continue }
    }
    Save-AnimeDatabase
}

function Initialize-SeasonMenu {
    param($Current)
    $today=[datetime]::UtcNow.ToString('yyyy-MM-dd')
    if ($script:SeasonMenuChecked -eq $today) { return }
    $script:SeasonMenuChecked=$today
    $periods=@((Get-PreviousAnimeSeason $Current),$Current,(Get-NextAnimeSeason $Current))
    $index=Get-ShowEventIndex
    foreach ($record in @($script:Db.Seasons.Values)) {
        if ((Get-SeasonNumber $record) -ge (Get-SeasonNumber $periods[0])) { continue }
        foreach ($id in (Get-SeasonShowIds $record)) {
            if (-not (Test-ShowFinished $id -EventsByShow $index) -or (Test-DubPending $script:Db.Shows[$id])) { $periods += $record; break }
        }
    }
    foreach ($period in $periods) {
        $cached=$script:Db.Seasons["$($period.Season)-$($period.Year)"]
        if ($cached.IncludesAired -and $cached.SchedulePriorityVersion -eq 1 -and ([string]$cached.UpdatedUtc).StartsWith($today)) { continue }
        try { $null=Update-SeasonCache $period.Season $period.Year -IncludeAired }
        catch { Write-Warning "Could not refresh $($period.Season) $($period.Year): $_. Using cached data." }
    }
    Update-EnglishDubs
}

function Resolve-QuitRequest {
    if (-not $script:Db.PendingExport) { return 'QUIT' }
    Clear-Host
    Write-Host 'Changes have not been exported' -ForegroundColor Yellow
    Write-Host "$($script:NewLine) E  Export now$($script:NewLine) Q  Quit anyway$($script:NewLine) Left  Back" -ForegroundColor Gray
    do { $key = (Read-MenuKey).Key } until ($key -in @('E','Q','LeftArrow'))
    if ($key -eq 'E') { return 'EXPORT' }
    if ($key -eq 'Q') { return 'QUIT' }
    return 'BACK'
}

function Show-KeyMenu {
    param([string]$Title,[array]$Items,[int]$Selected=0,[switch]$Back,[string[]]$Footer)
    if (-not $Items -or $Items.Count -eq 0) { return $null }
    $frame=@{}
    while ($true) {
        $view=Get-MenuViewport $Items.Count $Selected (5+$Footer.Count)
        $lines=@((New-MenuLine $Title Cyan),(New-MenuLine ('=' * $Title.Length) DarkCyan))
        for ($i = $view.Top; $i -lt $view.End; $i++) {
            $marker = if ($i -eq $Selected) { '>' } else { ' ' }
            $color  = if ($i -eq $Selected) { 'Yellow' } else { 'Gray' }
            $lines+=New-MenuLine (" $marker $($Items[$i].Label)") $color
        }
        $lines+=New-MenuLine
        foreach ($line in $Footer) { $lines+=New-MenuLine $line DarkGray }
        $lines+=New-MenuLine 'Up/Down Move   Right/Enter/Space Select   Left Back   Q Quit' DarkGray
        Write-MenuFrame $frame $lines "$($view.Top)|$($view.Size)"
        $key = (Read-MenuKey -FrameState $frame).Key
        if ($key -eq 'Q') { $frame.Clear() }
        switch ($key) {
            'Q'         { $answer = Resolve-QuitRequest; if ($answer -ne 'BACK') { return $answer } }
            'UpArrow'   { $Selected = ($Selected - 1 + $Items.Count) % $Items.Count }
            'DownArrow' { $Selected = ($Selected + 1) % $Items.Count }
            'Home'      { $Selected = 0 }
            'End'       { $Selected = $Items.Count - 1 }
            default {
                if ($key -in @('RightArrow','Enter','Spacebar')) { return $Items[$Selected].Value }
                if ($Back -and $key -eq 'LeftArrow') { return $null }
            }
        }
    }
}


function Show-GenreMenu {
    param([string]$Title)
    return Show-KeyMenu -Title $Title -Back -Items $script:GenreItems
}

function Show-ShowDetails {
    param($Show,[bool]$Excluded)
    while ($true) {
        Clear-Host
        $displayTitle=Format-AnimeTitle $Show.Title $Show.Providers
        Write-Host $displayTitle -ForegroundColor Cyan
        Write-Host ('=' * $displayTitle.Length) -ForegroundColor DarkCyan
        $state = if ($Excluded) { 'Not in calendar' } else { 'In calendar' }
        Write-Host "Status       : $state"
        Write-Host "Streaming on : $(@($Show.Providers) -join ', ')"
        $when = if ($Show.NextWhen) { $Show.NextWhen.ToLocalTime().ToString('dddd, MMMM d, yyyy h:mm tt') } else { 'Not announced yet' }
        if ($Show.NextEvent -and $Show.NextEvent.AllDay) {
            $stamp = ConvertFrom-AnimeDate $Show.NextEvent.Date -DateOnly
            $when = if ($Show.NextEvent.DatePrecision -eq 'Month') {
                $stamp.ToString('MMMM yyyy') + ' - exact date not announced'
            } else {
                $stamp.ToString('dddd, MMMM d, yyyy') + ' (date only)'
            }
        }
        Write-Host "Next release : $when" -ForegroundColor Yellow
        Write-Host ''
        Write-Host 'Synopsis' -ForegroundColor DarkCyan
        Write-Host '--------' -ForegroundColor DarkCyan
        if ($Show.EndedLabel) { Write-Host $Show.EndedLabel.Trim() -ForegroundColor DarkGray }
        Write-WrappedText $(if ($Show.Synopsis) { $Show.Synopsis } else { 'No synopsis is currently available.' })
        Write-Host ''
        Write-Host 'Left Back   Q Quit' -ForegroundColor DarkGray
        $key = (Read-MenuKey).Key
        if ($key -eq 'Q') { $answer = Resolve-QuitRequest; if ($answer -ne 'BACK') { return $answer } }
        elseif ($key -eq 'LeftArrow') { return $null }
    }
}

function Remove-DisabledProviderData {
    Update-SelectionHistory
    $previousCount = @($script:Db.Selections).Count
    $script:Db.Selections = @($script:Db.Selections | Where-Object { Test-ShowAvailable $script:Db.Shows[[string]$_] })
    Update-AnimeDatabase -Pending:($script:Db.Selections.Count -ne $previousCount)
}

function Refresh-ProviderSeasons {
    param($Current)
    Set-Variable -Scope Script -Name Providers -Value @($script:Db.EnabledProviders)
    Remove-DisabledProviderData
    $cachedShows=0
    $periods = @($Current,(Get-NextAnimeSeason $Current)) + @($script:Db.Seasons.Values | ForEach-Object { [pscustomobject]@{Season=$_.Season;Year=$_.Year} })
    foreach($period in @($periods | Sort-Object Season,Year -Unique)){$data=Update-SeasonCache $period.Season $period.Year -IncludeAired:$IncludePastEpisodes;$cachedShows+=@(Get-SeasonShowIds $data).Count}
    if(@($script:Db.EnabledProviders).Count -and $cachedShows -eq 0){throw "Provider update returned no shows for the enabled providers: $($script:Db.EnabledProviders -join ', '). The previous calendar remains available for merging; try Update again later."}
    Save-AnimeDatabase
}

function Show-ProviderDetails {
    param($Provider,$Current)
    $season=$script:Db.Seasons["$($Current.Season)-$($Current.Year)"]
    $top=@(Get-SeasonShows $season|Where-Object{$_.Providers -contains $Provider.Name -and $_.NextWhen -and $script:Db.Shows[$_.MediaId].Status -eq 'RELEASING'}|Sort-Object @{Expression={[int]$script:Db.Shows[$_.MediaId].Popularity};Descending=$true}|Select-Object -First 5)
    $selected=0
    $frame=@{}
    while($true){
        $view=Get-MenuViewport $top.Count $selected 7
        $lines=@((New-MenuLine $Provider.Name Cyan),(New-MenuLine),
            (New-MenuLine "Website: $(if($Provider.Url){$Provider.Url}else{'Not available'})" Blue),
            (New-MenuLine),(New-MenuLine 'Popular currently airing shows' DarkCyan))
        if(-not $top.Count){$lines+=New-MenuLine '  Not available'}else{for($i=$view.Top;$i-lt$view.End;$i++){$name=Format-AnimeTitle $top[$i].Title $top[$i].Providers;$lines+=New-MenuLine " $(if($i-eq$selected){'>'}else{' '}) $name" $(if($i-eq$selected){'Yellow'}else{'Gray'})}}
        $lines+=New-MenuLine
        $lines+=New-MenuLine 'Up/Down Move   Right Show details   O Open website   Left Back   Q Quit' DarkGray
        Write-MenuFrame $frame $lines "$($view.Top)|$($view.Size)"
        $key=(Read-MenuKey -FrameState $frame).Key
        if ($key -in @('RightArrow','Q','O')) { $frame.Clear() }
        if($key-eq'UpArrow'-and$top.Count){$selected=($selected-1+$top.Count)%$top.Count}elseif($key-eq'DownArrow'-and$top.Count){$selected=($selected+1)%$top.Count}
        elseif($key-eq'RightArrow'-and$top.Count){$answer=Show-ShowDetails $top[$selected] $false;if($answer){return $answer}}
        elseif($key-eq'O'-and$Provider.Url){Start-Process $Provider.Url}
        elseif($key-eq'LeftArrow'){return}elseif($key-eq'Q'){return Resolve-QuitRequest}
    }
}

function Show-ProvidersMenu {
    param($Current)
    $selected=0
    $frame=@{}
    while($true){
        $providers=@($script:Db.ProviderDirectory.Values|Sort-Object Name)
        $list=@([pscustomobject]@{Name='Update providers and shows';IsUpdate=$true})+@($providers|ForEach-Object{[pscustomobject]@{Name=$_.Name;Url=$_.Url;IsUpdate=$false}})
        $enabled=@{};foreach($name in @($script:Db.EnabledProviders)){$enabled[$name]=$true}
        $view=Get-MenuViewport $list.Count $selected 5
        $lines=@(New-MenuLine 'Providers' Cyan)
        for($i=$view.Top;$i-lt$view.End;$i++){$mark=if($list[$i].IsUpdate){'[>]'}elseif($enabled.ContainsKey($list[$i].Name)){'[x]'}else{'[ ]'};$lines+=New-MenuLine " $(if($i-eq$selected){'>'}else{' '}) $mark $($list[$i].Name)" $(if($i-eq$selected){'Yellow'}else{'Gray'})}
        if(-not$providers.Count){$lines+=New-MenuLine 'Select Update once to discover providers reported by AniList and LiveChart.' DarkGray}
        $lines+=New-MenuLine
        $lines+=New-MenuLine 'Up/Down Move   Space Toggle/Update   Right Provider details   Left Back   Q Quit' DarkGray
        Write-MenuFrame $frame $lines "$($view.Top)|$($view.Size)|$($list.Name -join '|')"
        $key=(Read-MenuKey -FrameState $frame).Key
        if ($key -in @('RightArrow','Q','Spacebar')) { $frame.Clear() }
        if($key-eq'UpArrow'-and$list.Count){$selected=($selected-1+$list.Count)%$list.Count}elseif($key-eq'DownArrow'-and$list.Count){$selected=($selected+1)%$list.Count}
        elseif($key-eq'Spacebar'-and$list.Count){
            if($list[$selected].IsUpdate){Refresh-ProviderSeasons $Current;continue}
            $name=$list[$selected].Name
            $removeFromIcs=$false
            if ($enabled.ContainsKey($name)) {
                $affected = @($script:Db.Selections | ForEach-Object { $script:Db.Shows[[string]$_] } | Where-Object { $_ -and $_.Providers.Contains($name) } | Sort-Object Title)
                if ($affected.Count -and -not (Confirm-ProviderRemoval $name $affected)) { continue }
                if ($affected.Count) {
                    $removeFromIcs = Confirm-ProviderCalendarRemoval $name
                }
                $script:Db.EnabledProviders=@($script:Db.EnabledProviders|Where-Object{$_-ne$name})
                $exclusiveIds=@($affected | Where-Object { -not (Test-ShowAvailable $_) } | ForEach-Object { [string]$_.MediaId })
                if ($removeFromIcs) {
                    $script:Db.RetainedCalendarShows=@($script:Db.RetainedCalendarShows | Where-Object { $_ -notin $exclusiveIds })
                } else {
                    $script:Db.RetainedCalendarShows=@(@($script:Db.RetainedCalendarShows)+$exclusiveIds | Sort-Object -Unique)
                }
                Remove-DisabledProviderData
            } else {
                # Older caches omitted disabled providers. Upgrade once before toggling.
                if (@($script:Db.Seasons.Values | Where-Object { -not $_.ProviderCacheComplete }).Count) {
                    try { Refresh-ProviderSeasons $Current } catch { Write-Warning $_; $null=Read-MenuKey; continue }
                }
                $script:Db.EnabledProviders=@($script:Db.EnabledProviders+$name|Sort-Object -Unique)
                $restored=@($script:Db.RetainedCalendarShows | Where-Object { Test-ShowAvailable $script:Db.Shows[[string]$_] })
                $script:Db.Selections=@(@($script:Db.Selections)+$restored | Sort-Object -Unique)
                $script:Db.RetainedCalendarShows=@($script:Db.RetainedCalendarShows | Where-Object { $_ -notin $restored })
            }
            Set-Variable -Scope Script -Name Providers -Value @($script:Db.EnabledProviders);Update-AnimeDatabase -Pending -Save
            if ($removeFromIcs) { return 'EXPORT' }
        }
        elseif($key-eq'RightArrow'-and$list.Count-and-not$list[$selected].IsUpdate){$answer=Show-ProviderDetails $list[$selected] $Current;if($answer-in@('QUIT','EXPORT')){return $answer}}
        elseif($key-eq'LeftArrow'){return}elseif($key-eq'Q'){return Resolve-QuitRequest}
    }
}

function Confirm-ProviderCalendarRemoval {
    param([string]$Name)
    $answer=Show-KeyMenu -Title "Also remove $Name shows from the ICS?" -Back -Items @(
        [pscustomobject]@{Label='No - keep existing ICS entries';Value='NO'},
        [pscustomobject]@{Label='Yes - remove and update ICS now';Value='YES'}
    ) -Footer @('Shows on another enabled provider stay selected.', 'Yes exports all pending calendar changes. No preserves existing entries for shows losing their last provider.')
    return ($answer -eq 'YES')
}

function Confirm-ProviderRemoval {
    param([string]$Name,[array]$Shows)
    $page=0
    $size=[math]::Max(1,(Get-MenuPageSize)-7)
    while ($true) {
        $lines=@('Selected shows (shows on another enabled provider stay selected):')
        $lines+=@($Shows | Select-Object -Skip ($page*$size) -First $size | ForEach-Object { "  $($_.Title)" })
        $items=@([pscustomobject]@{Label='No - keep provider';Value='NO'},[pscustomobject]@{Label='Yes - remove provider';Value='YES'})
        if (($page+1)*$size -lt $Shows.Count) { $items += [pscustomobject]@{Label='Next page of selected shows';Value='NEXT'} }
        if ($page -gt 0) { $items += [pscustomobject]@{Label='Previous page of selected shows';Value='PREVIOUS'} }
        $answer=Show-KeyMenu -Title "Remove $Name? ($($Shows.Count) selected shows)" -Items $items -Footer $lines -Back
        if ($answer -eq 'NEXT') { $page++; continue }
        if ($answer -eq 'PREVIOUS') { $page--; continue }
        return ($answer -eq 'YES')
    }
}

function Update-LastRows {
    param([array]$Shows,[datetime]$Now=[datetime]::UtcNow)
    $due=@(foreach ($row in $Shows) {
        if ($row.LastView -and (-not $row.LifecycleRefreshAt -or $Now -ge $row.LifecycleRefreshAt)) { $row }
    })
    if (-not $due.Count) { return }
    $fresh=@{}
    foreach ($row in (Get-SeasonShows @{ShowIds=@($due.MediaId);Events=@()} -View Last -Now $Now)) { $fresh[$row.MediaId]=$row }
    foreach ($row in $due) {
        if (-not $fresh.ContainsKey($row.MediaId)) { continue }
        foreach ($property in $fresh[$row.MediaId].PSObject.Properties) {
            $row | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value -Force
        }
    }
}

function Show-ToggleList {
    param([array]$Shows,[hashtable]$Excluded,[hashtable]$AppliedExcluded,[Nullable[bool]]$ShowExcluded,[string]$Title)
    $selected = 0
    $search = ''
    $frame=@{}
    $titles=@{}
    foreach ($show in $Shows) { $titles[$show.MediaId]=Format-AnimeTitle $show.Title $show.Providers }
    while ($true) {
        Update-LastRows $Shows
        $list = @($Shows | Where-Object { $null -eq $ShowExcluded -or $AppliedExcluded.ContainsKey($_.MediaId) -eq $ShowExcluded })
        if ($search) { $list = @($list | Where-Object { $_.Title -and $_.Title.IndexOf($search,[StringComparison]::OrdinalIgnoreCase) -ge 0 }) }
        $lines=@((New-MenuLine $Title Cyan),(New-MenuLine ('=' * $Title.Length) DarkCyan))
        if ($search) { $lines+=New-MenuLine "Filter: $search" Magenta }

        if ($list.Count -eq 0) {
            $lines+=New-MenuLine
            $lines+=New-MenuLine $(if ($search) { 'Nothing matches that filter.' } else { 'No shows in this list.' })
            $lines+=New-MenuLine
            $lines+=New-MenuLine '/ Filter   C Clear filter   Left Back   Q Quit' DarkGray
            Write-MenuFrame $frame $lines "empty|$search"
            $key = (Read-MenuKey -FrameState $frame).Key
            if ($key -in @('Q','Oem2','Divide')) { $frame.Clear() }
            if ($key -eq 'Q') { $answer = Resolve-QuitRequest; if ($answer -ne 'BACK') { return $answer }; continue }
            if ($key -eq 'C') { $search = ''; continue }
            if ($key -eq 'Oem2' -or $key -eq 'Divide') { Write-Host ''; $search = Read-Host 'Filter'; $selected = 0; continue }
            if ($key -eq 'LeftArrow') { return $null }
            continue
        }

        if ($selected -ge $list.Count) { $selected = $list.Count - 1 }
        if ($selected -lt 0) { $selected = 0 }
        $view=Get-MenuViewport $list.Count $selected (4+[int][bool]$search)
        $pageSize=$view.Size
        for ($i = $view.Top; $i -lt $view.End; $i++) {
            $cursor = if ($i -eq $selected) { '>' } else { ' ' }
            $mark   = if ($Excluded.ContainsKey($list[$i].MediaId)) { '[ ] ' } else { '[x] ' }
            if ($list[$i].Selectable -eq $false) { $mark='[-] ' }
            $color  = if ($i -eq $selected) { 'Yellow' } else { 'Gray' }
            $lines+=New-MenuLine (" $cursor $mark$($titles[$list[$i].MediaId])") $color
        }
        $lines+=New-MenuLine
        $lines+=New-MenuLine "$($view.Top+1)-$($view.End)/$($list.Count)   Up/Down Move   PgUp/PgDn   Space Toggle   Right Details   / Filter   C Clear   Left Back" DarkGray
        Write-MenuFrame $frame $lines "$($view.Top)|$pageSize|$search|$($list.MediaId -join '|')"

        $key = (Read-MenuKey -FrameState $frame).Key
        if ($key -in @('Q','RightArrow','Oem2','Divide')) { $frame.Clear() }
        switch ($key) {
            'UpArrow'   { $selected = ($selected - 1 + $list.Count) % $list.Count }
            'DownArrow' { $selected = ($selected + 1) % $list.Count }
            'PageUp'    { $selected = [math]::Max(0,$selected - $pageSize) }
            'PageDown'  { $selected = [math]::Min($list.Count - 1,$selected + $pageSize) }
            'Home'      { $selected = 0 }
            'End'       { $selected = $list.Count - 1 }
            'Spacebar'  {
                $show = $list[$selected]
                Update-LastRows @($show)
                if ($show.Selectable -eq $false) { break }
                if ($Excluded.ContainsKey($show.MediaId)) { $null=$Excluded.Remove($show.MediaId) } else { $Excluded[$show.MediaId] = $show.Title }
                Save-AnimeExclusion -Excluded $Excluded -MarkPending -MediaId $show.MediaId
            }
            'C'         { $search = ''; $selected = 0 }
            'Q'         { $answer = Resolve-QuitRequest; if ($answer -ne 'BACK') { Save-AnimeDatabase; return $answer } }
            default {
                if ($key -eq 'RightArrow') {
                    Update-LastRows @($list[$selected])
                    $answer = Show-ShowDetails -Show $list[$selected] -Excluded ($Excluded.ContainsKey($list[$selected].MediaId))
                    if ($answer -in @('QUIT','EXPORT')) { Save-AnimeDatabase; return $answer }
                }
                elseif ($key -eq 'Oem2' -or $key -eq 'Divide') {
                    Write-Host ''
                    $search = Read-Host 'Filter'
                    $selected = 0
                }
                elseif ($key -eq 'LeftArrow') { Save-AnimeDatabase; return $null }
            }
        }
    }
}

function Save-AnimeExclusion {
    # The exclusion set includes newly discovered titles until explicitly added.
    param([hashtable]$Excluded,[switch]$MarkPending,[string]$MediaId)
    if ($PSBoundParameters.ContainsKey('MediaId')) {
        # A single toggle does not need to rediscover every season's shows.
        $selectedIds = @{}
        foreach ($id in $script:Db.Selections) { $selectedIds[[string]$id] = $true }
        if ($Excluded.ContainsKey($MediaId)) { $selectedIds.Remove($MediaId) }
        else { $selectedIds[$MediaId] = $true }
        $script:Db.Selections = @($selectedIds.Keys | Sort-Object)
    } else {
        $allIds = @{}
        foreach ($season in $script:Db.Seasons.Values) {
            foreach ($id in (Get-SeasonShowIds $season)) { $allIds[[string]$id] = $true }
        }
        $script:Db.Selections = @($allIds.Keys | Where-Object { -not $Excluded.ContainsKey([string]$_) } | Sort-Object)
    }
    Update-SelectionHistory
    Update-AnimeDatabase -Pending:$MarkPending
}

function Test-ShowSelectionModifications {
    $pending = @($script:Db.Selections | ForEach-Object {[string]$_} | Sort-Object -Unique)
    $applied = @($script:Db.AppliedSelections | ForEach-Object {[string]$_} | Sort-Object -Unique)
    return (($pending -join "`n") -ne ($applied -join "`n"))
}

function Show-ManagementMenu {
    param([array]$Shows,[hashtable]$Excluded,[string]$SeasonLabel)
    while ($true) {
        $Shows=@($Shows|Where-Object{$null-ne$_ -and -not[string]::IsNullOrWhiteSpace([string]$_.MediaId)})
        $appliedIds=@{};foreach($id in @($script:Db.AppliedSelections)){$appliedIds[[string]$id]=$true}
        $appliedExcluded=@{};foreach($show in $Shows){if(-not$appliedIds.ContainsKey([string]$show.MediaId)){$appliedExcluded[[string]$show.MediaId]=$show.Title}}
        $inCalendar = @($Shows | Where-Object { -not $appliedExcluded.ContainsKey($_.MediaId) }).Count
        $outside    = @($Shows | Where-Object { $appliedExcluded.ContainsKey($_.MediaId) }).Count
        $items = @(
            [pscustomobject]@{Label="Shows in the calendar ($inCalendar)";Value='CURRENT'}
            [pscustomobject]@{Label="Shows not added ($outside)";Value='EXCLUDED'}
        )
        $items += [pscustomobject]@{Label=$(if(Test-ShowSelectionModifications){'Update ICS with modifications'}else{'Export calendar'});Value='EXPORT'}
        $choice = Show-KeyMenu -Title "Manage $SeasonLabel shows" -Back -Items $items
        if ($choice -in @('QUIT','EXPORT')) { return $choice }
        if ($null -eq $choice) { return 'GENRE' }
        if ($choice -eq 'CURRENT') {
            $answer = Show-ToggleList -Shows $Shows -Excluded $Excluded -AppliedExcluded $appliedExcluded -ShowExcluded $false -Title 'Shows in the calendar - Space toggles pending changes'
            if ($answer -in @('QUIT','EXPORT')) { return $answer }
        }
        elseif ($choice -eq 'EXCLUDED') {
            $answer = Show-ToggleList -Shows $Shows -Excluded $Excluded -AppliedExcluded $appliedExcluded -ShowExcluded $true -Title 'Shows not added - Space toggles pending changes'
            if ($answer -in @('QUIT','EXPORT')) { return $answer }
        }
    }
}

function Select-CalendarFolder {
    param([string]$Start)
    $folder = $Start
    $desktop = Get-DesktopDirectory
    $selected = 0
    while ($true) {
        $dirs = @(Get-ChildItem -LiteralPath $folder -Directory -ErrorAction SilentlyContinue | Sort-Object Name)
        $items = @(
            [pscustomobject]@{Label='[ Save in this folder ]';Value='SAVE'}
            [pscustomobject]@{Label='Desktop';Value='DESKTOP'}
            [pscustomobject]@{Label='[..] Parent folder';Value='UP'}
        )
        $items += @($dirs | ForEach-Object { [pscustomobject]@{Label="[$($_.Name)]";Value=$_.FullName} })
        $choice = Show-KeyMenu -Title "Output folder: $folder" -Items $items -Selected ([math]::Min($selected,$items.Count-1)) -Back
        if ($choice -in @('QUIT','EXPORT')) { return $choice }
        if ($null -eq $choice) { return $null }
        if ($choice -eq 'SAVE') { return $folder }
        if ($choice -eq 'DESKTOP') { $folder = $desktop; $selected = 0; continue }
        if ($choice -eq 'UP') {
            $parent = Split-Path $folder -Parent
            if ($parent) { $folder = $parent }
            $selected = 0
            continue
        }
        $folder = $choice
        $selected = 0
    }
}

# Export
function New-CalendarEvent {
    # Expands a stored episode into the events the calendar will carry. The
    # description is built here from the show record rather than stored on every
    # episode row.
    param($Entry,$Show)
    # Deliberately not named $providers: PowerShell variable names are
    # case-insensitive, so that would shadow the $Providers parameter.
    $showProviders = @($Show.Providers.Keys | Where-Object { $_ -in $Providers })
    if ($Entry.AirType -eq 'dub' -and $Entry.Provider) { $showProviders=@($showProviders | Where-Object { $_ -eq $Entry.Provider }) }
    if ($showProviders.Count -eq 0) { return }
    $episodeLabel = if ($Entry.Episode -eq 'release') { '' } else { " - Episode $($Entry.Episode)" }
    $approximate = ($Entry.DatePrecision -eq 'Month')
    if ($approximate) { $episodeLabel = ' (date TBA)' }
    # An ArrayList of arrays, because the pipeline flattens nested single-element
    # arrays and each group would collapse back to a bare provider string.
    $groups = New-Object System.Collections.ArrayList
    if ($CombineProviders) { $null = $groups.Add(@($showProviders)) }
    else { foreach ($provider in $showProviders) { $null = $groups.Add(@($provider)) } }

    foreach ($group in $groups) {
        $release=Get-ProviderReleaseTime $Entry $Show $group
        $slug = if ($CombineProviders) { 'all' } else { [string]$group[0] -replace '[^A-Za-z0-9]','' }
        if ($Entry.AirType -eq 'dub') { $slug += 'Dub' }
        $primaryUrl = $Show.Providers[$group[0]]
        if (-not $primaryUrl) { $primaryUrl = $Show.SiteUrl }
        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add([string]$Show.Synopsis)
        $lines.Add('')
        $lines.Add("Streaming: $($group -join ', ')")
        if (-not $Entry.AllDay) {
            $timing=if ($release.Source) { $release.Source } else { 'broadcast fallback; provider time unavailable.' }
            $lines.Add("Release time: $timing")
            if ($group.Count -gt 1 -and $release.Source) { $lines.Add('Combined entry uses the earliest known provider release in this group.') }
        }
        $lines.Add("AniList: $($Show.SiteUrl)")
        if ($approximate) {
            $month = (ConvertFrom-AnimeDate $Entry.Date -DateOnly).ToString('MMMM yyyy')
            $lines.Add("Premiere date has not been announced. $month is the month listed by AniList; this entry sits on the 1st as a placeholder and moves once the exact date is published.")
        }
        elseif ($Entry.Episode -eq 'release') { $lines.Add('No episode-level airtime is published; this is the listed release date.') }
        foreach ($provider in $group) {
            $url = $Show.Providers[$provider]
            if ($url -and $url -ne $Show.SiteUrl) { $lines.Add("Watch/lineup ($provider): $url") }
        }
        [pscustomobject]@{
            Uid         = Get-CanonicalEventUid -EventId "$($Entry.MediaId)-$($Entry.Episode)-$slug"
            MediaId     = [string]$Entry.MediaId
            Summary     = "$(Format-AnimeTitle $Show.Title $group)$episodeLabel$(if ($Entry.AirType -eq 'dub') { ' (English Dub)' })"
            Description = ($lines -join $script:NewLine)
            Url         = $primaryUrl
            AllDay      = [bool]$Entry.AllDay
            Start       = $release.Start
            Minutes     = [int]$Entry.DurationMinutes
            Sequence    = [int]$Entry.Sequence + $(if ($release.Source) { 1 } else { 0 })
        }
    }
}

function Add-IcsEvent {
    param($Calendar,$Entry,[string]$Stamp)
    $date=$Entry.Start.ToString('yyyyMMdd');$timed=$Entry.Start.ToString('yyyyMMddTHHmmssZ')
    $minutes=if($Entry.Minutes -gt 0){$Entry.Minutes}else{30}
    $fields=[ordered]@{UID=$Entry.Uid;DTSTAMP=$Stamp;SEQUENCE=$Entry.Sequence;'LAST-MODIFIED'=$Stamp}
    if($Entry.AllDay){$fields['DTSTART;VALUE=DATE']=$date;$fields['DTEND;VALUE=DATE']=$Entry.Start.AddDays(1).ToString('yyyyMMdd')}
    else{$fields.DTSTART=$timed;$fields.DTEND=$Entry.Start.AddMinutes($minutes).ToString('yyyyMMddTHHmmssZ')}
    $fields.SUMMARY=ConvertTo-IcsText $Entry.Summary;$fields.DESCRIPTION=ConvertTo-IcsText $Entry.Description
    if($Entry.Url){$fields.URL=ConvertTo-IcsText $Entry.Url};$fields.STATUS='CONFIRMED';$fields.TRANSP='TRANSPARENT'
    $Calendar.Add('BEGIN:VEVENT');foreach($field in $fields.GetEnumerator()){$Calendar.Add((ConvertTo-IcsLine "$($field.Key):$($field.Value)"))};$Calendar.Add('END:VEVENT')
}

function Export-AnimeCalendar {
    param([Parameter(Mandatory)][string]$Path,[hashtable]$Excluded)

    $retentionStart = if ($IncludePastEpisodes) { [datetime]::MinValue } else { [datetime]::UtcNow.Date.AddDays(-1) }
    $selected = @{}
    foreach ($id in @($script:Db.Selections)) { $selected[[string]$id] = $true }

    $calendarEvents = New-Object System.Collections.ArrayList
    $dubSeason=@{Events=@($script:Db.Shows.Values | ForEach-Object { $_.EnglishDub.Events } | Where-Object { $_ })}
    foreach ($season in (@($script:Db.Seasons.Values)+@($dubSeason))) {
        foreach ($entry in @($season.Events)) {
            $id = [string]$entry.MediaId
            if (-not $selected.ContainsKey($id)) { continue }
            if ($Excluded -and $Excluded.ContainsKey($id)) { continue }
            if (-not $script:Db.Shows.Contains($id)) { continue }
            if (-not (Test-ReleaseAllowed $entry $script:Db.Shows[$id])) { continue }
            foreach ($expanded in @(New-CalendarEvent -Entry $entry -Show $script:Db.Shows[$id])) {
                if ($expanded.Start -and $expanded.Start -ge $retentionStart) { $null = $calendarEvents.Add($expanded) }
            }
        }
    }

    # Fail closed if an excluded media id survived the filter above.
    if ($Excluded) {
        $leaked = @($calendarEvents | Where-Object { $Excluded.ContainsKey([string]$_.MediaId) })
        if ($leaked.Count -gt 0) { throw "Exclusion integrity check failed: $($leaked.Count) excluded events remain." }
    }

    $crlf = [string][char]13 + [string][char]10
    $calendar = New-Object System.Collections.Generic.List[string]
    $calendar.Add('BEGIN:VCALENDAR')
    $calendar.Add('VERSION:2.0')
    $calendar.Add('PRODID:-//anime-ics//EN')
    $calendar.Add('CALSCALE:GREGORIAN')
    $calendar.Add('METHOD:PUBLISH')
    $calendar.Add((ConvertTo-IcsLine 'X-WR-CALNAME:Anime Calendar'))
    # Subscription clients use these to decide how often to re-poll the file.
    $calendar.Add('REFRESH-INTERVAL;VALUE=DURATION:PT12H')
    $calendar.Add('X-PUBLISHED-TTL:PT12H')

    $stamp = [datetime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
    $previous=@{}
    if (Test-Path -LiteralPath $Path) {
        $raw=Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        foreach ($match in [regex]::Matches([string]$raw,'(?ms)^BEGIN:VEVENT\r?\n.*?^END:VEVENT\r?$')) {
            $uid=[regex]::Match($match.Value,'(?m)^UID:(.+)\r?$')
            $seq=[regex]::Match($match.Value,'(?m)^SEQUENCE:(\d+)')
            if ($uid.Success) {
                $previous[(Get-CanonicalEventUid -Uid $uid.Groups[1].Value)]=@{
                    Start=(Get-EventStartFromIcsBlock $match.Value);Sequence=$(if ($seq.Success) { [int]$seq.Groups[1].Value } else { 0 })}
            }
        }
    }
    foreach ($entry in $calendarEvents) {
        if ($previous.ContainsKey($entry.Uid)) {
            $old=$previous[$entry.Uid]
            $entry.Sequence=[math]::Max($entry.Sequence,($old.Sequence+[int]($old.Start -ne $entry.Start)))
        }
    }
    $uids = New-Object 'System.Collections.Generic.HashSet[string]'
    $eventKeys = New-Object 'System.Collections.Generic.HashSet[string]'

    foreach ($entry in @($calendarEvents | Sort-Object Start,Summary)) {
        if (-not $uids.Add($entry.Uid)) { continue }
        $startKey = if ($entry.AllDay) { $entry.Start.ToString('yyyyMMdd') } else { $entry.Start.ToString('yyyyMMddTHHmmssZ') }
        $null = $eventKeys.Add("$startKey|$(ConvertTo-IcsText $entry.Summary)")
        Add-IcsEvent $calendar $entry $stamp
    }

    # Merge previously written calendars. Only the output file is merged unless
    # -MergeFrom names more; the old script silently absorbed every anime-*.ics
    # it could find on the Desktop.
    $mergePaths = New-Object System.Collections.ArrayList
    if (Test-Path -LiteralPath $Path) { $null = $mergePaths.Add((Resolve-Path -LiteralPath $Path).Path) }
    foreach ($pattern in @($MergeFrom)) {
        if (-not $pattern) { continue }
        foreach ($resolved in @(Resolve-Path -Path $pattern -ErrorAction SilentlyContinue)) {
            if ($resolved.Path -notin $mergePaths) { $null = $mergePaths.Add($resolved.Path) }
        }
    }
    $mergedCount = 0
    foreach ($existingPath in $mergePaths) {
        $raw = Get-Content -LiteralPath $existingPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        foreach ($match in [regex]::Matches([string]$raw,'(?ms)^BEGIN:VEVENT\r?\n.*?^END:VEVENT\r?$')) {
            $block = $match.Value
            $uidMatch = [regex]::Match($block,'(?m)^UID:(.+)\r?$')
            if (-not $uidMatch.Success) { continue }
            $uid = Get-CanonicalEventUid -Uid $uidMatch.Groups[1].Value
            $mediaMatch = [regex]::Match($uid,'^(?<id>-?\d+)-')
            if ($mediaMatch.Success) {
                $mediaId = [string]$mediaMatch.Groups['id'].Value
                $show=$script:Db.Shows[$mediaId]
                $episodeMatch=[regex]::Match($uid,'^-?\d+-(\d+|release)-(.+)@')
                if ($episodeMatch.Success -and -not $episodeMatch.Groups[2].Value.EndsWith('Dub')) {
                    $episodeNumber=0
                    $null=[int]::TryParse($episodeMatch.Groups[1].Value,[ref]$episodeNumber)
                    if (([int]$show.ScheduleConflictFrom -gt 0 -and $episodeNumber -ge [int]$show.ScheduleConflictFrom) -or
                        ($episodeMatch.Groups[1].Value -eq 'release' -and $show.LiveChartSchedule.Releases)) { continue }
                }
                $retainExisting = $mediaId -in @($script:Db.RetainedCalendarShows)
                if (-not $retainExisting -and $Excluded -and $Excluded.ContainsKey($mediaId)) { continue }
                if (-not $retainExisting -and $script:Db.Shows.Contains($mediaId)) {
                    if (-not $selected.ContainsKey($mediaId) -or -not (Test-ShowAvailable $script:Db.Shows[$mediaId])) { continue }
                    # Preserve older airings, but never merge a disabled provider
                    # back into the output. Combined entries are rebuilt from cache
                    # when any of their providers has been disabled.
                    $providerSlug = ($uid -replace '@.*$','') -replace '^.*-',''
                    $enabledSlugs = @($script:Db.EnabledProviders | ForEach-Object { $_ -replace '[^A-Za-z0-9]','' })
                    if ($providerSlug -eq 'all') {
                        if (@($script:Db.Shows[$mediaId].Providers.Keys | Where-Object { $_ -notin $script:Db.EnabledProviders }).Count) { continue }
                    } elseif ($providerSlug -notin $enabledSlugs) { continue }
                }
            }
            $existingStart = Get-EventStartFromIcsBlock $block
            if ($existingStart -and $existingStart -lt $retentionStart) { continue }
            $startMatch = [regex]::Match($block,'(?m)^DTSTART[^:]*:(?<v>.+)\r?$')
            $summaryMatch = [regex]::Match($block,'(?m)^SUMMARY:(?<v>.+)\r?$')
            $eventKey = "$($startMatch.Groups['v'].Value.Trim())|$($summaryMatch.Groups['v'].Value.Trim())"
            if ($uids.Contains($uid) -or $eventKeys.Contains($eventKey)) { continue }
            $null = $uids.Add($uid)
            $null = $eventKeys.Add($eventKey)
            $block = [regex]::Replace($block,'(?m)^UID:.+\r?$',"UID:$uid")
            $block = [regex]::Replace($block,'(?m)^SUMMARY:(?<title>.+?)(?<episode> - Episode \d+| \(date TBA\))? \[(?<providers>[^\]]+)\]\r?$',{param($m)"SUMMARY:$($m.Groups['title'].Value) ($($m.Groups['providers'].Value))$($m.Groups['episode'].Value)"})
            foreach ($line in @($block -split '\r?\n')) { if ($line) { $calendar.Add($line.TrimEnd([char]13)) } }
            $mergedCount++
        }
    }
    $calendar.Add('END:VCALENDAR')

    $parent = Split-Path $Path -Parent
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Path $parent -Force }
    [IO.File]::WriteAllText($Path,(($calendar -join $crlf) + $crlf),(New-Object Text.UTF8Encoding($false)))

    return [pscustomobject]@{
        Path       = $Path
        Total      = $uids.Count
        Generated  = $calendarEvents.Count
        Merged     = $mergedCount
    }
}

function Resolve-OutputPath {
    param([string]$Requested,[string]$FallbackDirectory)
    if (-not $Requested) { return (Join-Path $FallbackDirectory 'anime-calendar.ics') }
    $full = [IO.Path]::GetFullPath($Requested)
    if ([IO.Path]::GetExtension($full) -eq '.ics') { return $full }
    return (Join-Path $full 'anime-calendar.ics')
}

function Get-DesktopDirectory {
    if ($env:OS -eq 'Windows_NT') {
        $directory = [Environment]::GetFolderPath('Desktop')
        if ($directory) { return $directory }
    }
    $userDirectory = [Environment]::GetFolderPath('UserProfile')
    if (-not $userDirectory) { $userDirectory = $env:HOME }
    if ($env:OS -ne 'Windows_NT' -and [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Linux)) {
        $configDirectory = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $userDirectory '.config' }
        $configPath = Join-Path $configDirectory 'user-dirs.dirs'
        foreach ($line in @(Get-Content -LiteralPath $configPath -Encoding UTF8 -ErrorAction SilentlyContinue)) {
            if ($line -match '^\s*XDG_DESKTOP_DIR="(.*)"\s*$') {
                $directory = $Matches[1].Replace('${HOME}', $userDirectory).Replace('$HOME', $userDirectory)
                $directory = $directory -replace '\\([\\"`$])', '$1'
                if ([IO.Path]::IsPathRooted($directory)) { return $directory }
            }
        }
    }
    return (Join-Path $userDirectory 'Desktop')
}

# Startup
$scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$script:ProviderSchedulePath=Join-Path $scriptRoot 'provider-release-times.csv'
$launchDirectory = (Get-Location).ProviderPath
$script:DbPath = if ($DatabasePath) { [IO.Path]::GetFullPath($DatabasePath) } else { Join-Path $scriptRoot 'anime-ics-db.json' }
$script:Db = Import-AnimeDatabase -Path $script:DbPath -DefaultDirectory $launchDirectory
Resolve-DuplicateShows
if($PSBoundParameters.ContainsKey('Providers')){$script:Db.EnabledProviders=@($Providers);Set-DatabaseDirty}else{$Providers=@($script:Db.EnabledProviders)}
foreach($provider in @($script:Db.ProviderDirectory.Values)){$main=Get-ProviderMainUrl $provider.Url;if($provider.Url-ne$main){$provider.Url=$main;Set-DatabaseDirty}}
foreach($show in $script:Db.Shows.Values){$clean=Compress-SynopsisWhitespace (Remove-SynopsisSourcePrefix ([string]$show.Synopsis));if($clean-ne[string]$show.Synopsis){$show.Synopsis=$clean;Set-DatabaseDirty};foreach($name in @($show.Providers.Keys)){Register-Provider $name ([string]$show.Providers[$name])}}
Save-AnimeDatabase
if($ListProviders){Write-Host "`n  Discovered streaming providers" -ForegroundColor Cyan;foreach($provider in @($script:Db.ProviderDirectory.Values|Sort-Object Name)){Write-Host "   $($provider.Name)"};Write-Host '';Save-AnimeDatabase;return}

if ($ListCache) {
    Write-Host ''
    Write-Host "  Database: $script:DbPath" -ForegroundColor Cyan
    if (Test-Path -LiteralPath $script:DbPath) {
        Write-Host ("  Size    : {0:N0} bytes" -f (Get-Item -LiteralPath $script:DbPath).Length)
    } else {
        Write-Host '  Size    : not created yet'
    }
    Write-Host ("  Shows   : {0}   Selected: {1}" -f $script:Db.Shows.Count, @($script:Db.Selections).Count)
    Write-Host ("  Output  : {0}" -f $script:Db.OutputDirectory)
    Write-Host ''
    if ($script:Db.Seasons.Count -eq 0) { Write-Host '  No cached seasons.' }
    foreach ($key in @($script:Db.Seasons.Keys)) {
        # Not $season: this runs at script scope, where that name belongs to the
        # -Season parameter and its ValidateSet would reject the assignment.
        $cached = $script:Db.Seasons[$key]
        Write-Host ("  {0,-12} episodes {1,5}   aired-included {2,-5}   complete {3,-5}   updated {4}" -f `
            $key, @($cached.Events).Count, $cached.IncludesAired, $cached.Complete, $cached.UpdatedUtc)
    }
    Write-Host ''
    return
}

if ($ClearCache) {
    $script:Db.Seasons = [ordered]@{}
    $script:Db.Shows = [ordered]@{}
    $script:Db.ShowAliases = [ordered]@{}
    $script:Db.PendingUpdates = @()
    if ($Force) {
        # KnownShows goes with Selections: keeping it while dropping selections
        # would leave every re-scraped show permanently deselected.
        $script:Db.Selections = @()
        $script:Db.RetainedCalendarShows = @()
        $script:Db.AppliedSelections = @()
        $script:Db.KnownShows = @()
        Write-Host 'Cached seasons and saved selections cleared.' -ForegroundColor Yellow
    }
    else { Write-Host 'Cached seasons cleared. Selections kept (use -Force to clear those too).' -ForegroundColor Yellow }
    Set-DatabaseDirty
    Save-AnimeDatabase
    return
}

if ($NextSeason -and ($PSBoundParameters.ContainsKey('Season') -or $PSBoundParameters.ContainsKey('Year'))) {
    throw 'NextSeason cannot be combined with an explicit Season or Year.'
}

$currentSeason = Get-AnimeSeason
$targetSeason = $currentSeason
if ($NextSeason) { $targetSeason = Get-NextAnimeSeason $currentSeason }
if ($Season) { $targetSeason = [pscustomobject]@{Season=$Season;Year=$(if ($Year) { $Year } else { $targetSeason.Year })} }
elseif ($Year) { $targetSeason = [pscustomobject]@{Season=$targetSeason.Season;Year=$Year} }

$interactive = (-not $NoMenu) -and (Test-ConsoleInput)

# Look for new or rescheduled next-season shows. This used to relaunch the
# script in a child process; it now runs inline against the same database.
if ($interactive -and -not $SkipStartupUpdateCheck) {
    # Not $nextSeason: at script scope that is the [switch]$NextSeason
    # parameter, and its type constraint rejects a season object.
    $upcomingSeason = Get-NextAnimeSeason $currentSeason
    $nextKey = "$($upcomingSeason.Season)-$($upcomingSeason.Year)"
    if ($script:Db.Seasons.Contains($nextKey)) {
        $cachedNext = $script:Db.Seasons[$nextKey]
        $incomplete = (-not [bool]$cachedNext.Complete) -or @($cachedNext.Events | Where-Object { $_.AllDay }).Count -gt 0
        if ($incomplete) {
            $before = @{}
            foreach ($entry in @($cachedNext.Events)) {
                $instant = Get-EventInstant $entry
                $id = [string]$entry.MediaId
                if (-not $before.ContainsKey($id) -or ($instant -and $instant -lt $before[$id])) { $before[$id] = $instant }
            }
            Write-Host "Checking $($upcomingSeason.Season) $($upcomingSeason.Year) for updates..." -ForegroundColor DarkGray
            try {
                $refreshed = Update-SeasonCache -SeasonName $upcomingSeason.Season -SeasonYear $upcomingSeason.Year -IncludeAired:$IncludePastEpisodes
                $after = @{}
                foreach ($entry in @($refreshed.Events)) {
                    $instant = Get-EventInstant $entry
                    $id = [string]$entry.MediaId
                    if (-not $after.ContainsKey($id) -or ($instant -and $instant -lt $after[$id])) { $after[$id] = $instant }
                }
                $updates = @($script:Db.PendingUpdates)
                foreach ($id in $after.Keys) {
                    $reason = if (-not $before.ContainsKey($id)) { 'New show' }
                              elseif ($before[$id] -ne $after[$id]) { 'First release updated' }
                              else { $null }
                    if (-not $reason) { continue }
                    if (@($updates | Where-Object { [string]$_.MediaId -eq [string]$id })) { continue }
                    $updates += [pscustomobject]@{
                        MediaId  = [string]$id
                        Title    = [string]$script:Db.Shows[$id].Title
                        Reason   = $reason
                        NewStart = $(if ($after[$id]) { $after[$id].ToString('o') })
                    }
                }
                $script:Db.PendingUpdates = @($updates)
                Set-DatabaseDirty
                Save-AnimeDatabase
            } catch {
                Write-Warning "Update check failed: $($_.Exception.Message)"
            }
        }
    }
}

function Get-WeekAirings {
    param([datetime]$NowUtc=[datetime]::UtcNow,[TimeZoneInfo]$TimeZone=[TimeZoneInfo]::Local)
    $now=[datetime]::SpecifyKind($NowUtc,[DateTimeKind]::Utc)
    $today=[TimeZoneInfo]::ConvertTimeFromUtc($now,$TimeZone).Date
    $end=$today.AddDays(7)
    $selected=@{}; foreach ($id in $script:Db.Selections) { $selected[(Resolve-ShowId ([string]$id))]=$true }
    $airings=@{}
    foreach ($season in $script:Db.Seasons.Values) {
        foreach ($entry in $season.Events) {
            $id=Resolve-ShowId ([string]$entry.MediaId)
            if (-not $selected.ContainsKey($id)) { continue }
            $show=$script:Db.Shows[$id]
            if (-not (Test-ShowAvailable $show)) { continue }
            $instant=$null
            if ($entry.AllDay) {
                # Month-only placeholders cannot be assigned to a particular day.
                if ($entry.DatePrecision -eq 'Month') { continue }
                $date=ConvertFrom-AnimeDate ([string]$entry.Date) -DateOnly
                if (-not $date) { continue }
                $local=[datetime]::SpecifyKind($date,[DateTimeKind]::Unspecified)
                $time='TBA'; $sortTime=[datetime]::MaxValue
            } else {
                $enabled=@($show.Providers.Keys | Where-Object { $_ -in $script:Db.EnabledProviders })
                $instant=(Get-ProviderReleaseTime $entry $show $enabled).Start
                if (-not $instant) { continue }
                $local=[TimeZoneInfo]::ConvertTimeFromUtc($instant,$TimeZone)
                $time=$local.ToString('h:mm tt'); $sortTime=$instant
            }
            if ($local.Date -lt $today -or $local.Date -ge $end) { continue }
            $key="$id|$($entry.Episode)"
            $item=[pscustomobject]@{MediaId=$id;Title=[string]$show.Title;Episode=[string]$entry.Episode;
                Providers=@($show.Providers.Keys | Where-Object { $_ -in $script:Db.EnabledProviders });
                Day=$local.Date;LocalTime=$local;TimeLabel=$time;SortTime=$sortTime;Sequence=[int]$entry.Sequence}
            if (-not $airings.ContainsKey($key) -or $item.Sequence -gt $airings[$key].Sequence) { $airings[$key]=$item }
        }
    }
    return @($airings.Values | Sort-Object Day,SortTime,Title,Episode)
}

function Get-WeekAiringRows {
    param([array]$Airings)
    $day=$null
    foreach ($airing in $Airings) {
        $label=$airing.Day.ToString('dddd, MMMM d')
        if ($day -ne $airing.Day) {
            [pscustomobject]@{Text=$label;Color='Cyan';DayLabel=$label;IsHeader=$true}
            $day=$airing.Day
        }
        $episode=if ($airing.Episode -and $airing.Episode -ne 'release') { " - Episode $($airing.Episode)" } else { '' }
        $title=Format-AnimeTitle $airing.Title $airing.Providers
        [pscustomobject]@{Text="  $($airing.TimeLabel)  $title$episode";Color='Gray';DayLabel=$label;IsHeader=$false}
    }
}

function Show-WeekAirings {
    $frame=@{}; $offset=0; $refresh=$true; $rows=@()
    while ($true) {
        if ($refresh) {
            $rows=@(Get-WeekAiringRows @(Get-WeekAirings))
            $refresh=$false; $offset=0; $frame.Clear()
        }
        $view=Get-MenuViewport $rows.Count 0 5
        $size=$view.Size; $last=[math]::Max(0,$rows.Count-$size)
        $offset=[math]::Min($offset,$last)
        $lines=@((New-MenuLine 'Airing this week (local time)' Cyan),(New-MenuLine 'Today and the next six days; unknown airing times are TBA.' DarkGray))
        if (-not $rows.Count) { $lines+=New-MenuLine 'No selected shows have dated episodes scheduled in the next 7 days.' }
        else {
            if (-not $rows[$offset].IsHeader) { $lines+=New-MenuLine "$($rows[$offset].DayLabel) (continued)" Cyan }
            for ($i=$offset; $i -lt [math]::Min($offset+$size,$rows.Count); $i++) { $lines+=New-MenuLine $rows[$i].Text $rows[$i].Color }
        }
        $lines+=New-MenuLine
        $lines+=New-MenuLine 'Up/Down Scroll   PgUp/PgDn   Home/End   R Refresh   Left Back   Q Quit' DarkGray
        Write-MenuFrame $frame $lines "$offset|$size"
        $key=(Read-MenuKey -FrameState $frame).Key
        switch ($key) {
            'UpArrow' { $offset=[math]::Max(0,$offset-1) }
            'DownArrow' { $offset=[math]::Min($last,$offset+1) }
            'PageUp' { $offset=[math]::Max(0,$offset-$size) }
            'PageDown' { $offset=[math]::Min($last,$offset+$size) }
            'Home' { $offset=0 }
            'End' { $offset=$last }
            'R' { $refresh=$true }
            'LeftArrow' { return $null }
            'Escape' { return $null }
            'Q' { $frame.Clear(); $answer=Resolve-QuitRequest; if ($answer -ne 'BACK') { return $answer } }
        }
    }
}

function Show-PendingUpdates {
    $selectedIds = @{}
    foreach ($id in @($script:Db.Selections)) { $selectedIds[[string]$id] = $true }
    $selected = 0
    $frame=@{}
    $reviewDate=$null
    $items=@()
    $labels=@{}
    $layoutIds=''
    while ($true) {
        # Nothing changes while navigating this read-only snapshot. Recheck
        # completion on entry or UTC date rollover, not on every arrow key.
        if ($reviewDate -ne [datetime]::UtcNow.Date) {
            $items = @(Get-VisiblePendingUpdates | Sort-Object Title)
            $labels=@{}
            foreach ($item in $items) {
                $id=[string]$item.MediaId
                $record=$script:Db.Shows[$id]
                $name=Format-AnimeTitle $item.Title @($record.Providers.Keys | Where-Object { $_ -in $script:Db.EnabledProviders })
                $labels[$id]="$name - $($item.Reason)"
            }
            $layoutIds=$items.MediaId -join '|'
            $reviewDate=[datetime]::UtcNow.Date
        }
        if ($items.Count -eq 0) { return $null }
        if ($selected -ge $items.Count) { $selected = $items.Count - 1 }
        $view=Get-MenuViewport $items.Count $selected 4
        $lines=@((New-MenuLine 'Updated next-season shows' Cyan),(New-MenuLine '=========================' DarkCyan))
        for ($i = $view.Top; $i -lt $view.End; $i++) {
            $id = [string]$items[$i].MediaId
            $mark = if ($selectedIds.ContainsKey($id)) { '[x]' } else { '[ ]' }
            $cursor = if ($i -eq $selected) { '>' } else { ' ' }
            $color = if ($i -eq $selected) { 'Yellow' } else { 'Gray' }
            $lines+=New-MenuLine " $cursor $mark $($labels[$id])" $color
        }
        $lines+=New-MenuLine
        $lines+=New-MenuLine 'Up/Down Move   Space Add/Remove   Right Details   D Dismiss all   Left Back' DarkGray
        Write-MenuFrame $frame $lines "$($view.Top)|$($view.Size)|$layoutIds"
        $key = (Read-MenuKey -FrameState $frame).Key
        if ($key -in @('Q','RightArrow')) { $frame.Clear() }
        switch ($key) {
            'UpArrow'   { $selected = ($selected - 1 + $items.Count) % $items.Count }
            'DownArrow' { $selected = ($selected + 1) % $items.Count }
            'Spacebar'  {
                $id = [string]$items[$selected].MediaId
                if ($selectedIds.ContainsKey($id)) {
                    $selectedIds.Remove($id)
                    $script:Db.Selections = @($script:Db.Selections | Where-Object { [string]$_ -ne $id })
                } else {
                    $selectedIds[$id] = $true
                    $script:Db.Selections = @(@($script:Db.Selections) + $id | Sort-Object -Unique)
                }
                $script:Db.PendingExport = $true
                Update-SelectionHistory
                $items=@($items | Where-Object { [string]$_.MediaId -notin $script:Db.SelectionHistory })
                $layoutIds=$items.MediaId -join '|'
                Set-DatabaseDirty
            }
            'D'         { $script:Db.PendingUpdates = @(); Set-DatabaseDirty; Save-AnimeDatabase; return $null }
            'Q'         { $answer = Resolve-QuitRequest; if ($answer -ne 'BACK') { Save-AnimeDatabase; return $answer } }
            default {
                if ($key -eq 'RightArrow') {
                    $show = $items[$selected]
                    $record = $null
                    if ($script:Db.Shows.Contains([string]$show.MediaId)) { $record = $script:Db.Shows[[string]$show.MediaId] }
                    $projection = [pscustomobject]@{
                        MediaId   = [string]$show.MediaId
                        Title     = [string]$show.Title
                        Synopsis  = [string]$(if ($record) { $record.Synopsis })
                        Providers = @($(if ($record) { $record.Providers.Keys | Where-Object { $_ -in $script:Db.EnabledProviders } }))
                        NextEvent = $null
                        NextWhen  = (ConvertFrom-AnimeDate $show.NewStart)
                    }
                    $answer = Show-ShowDetails -Show $projection -Excluded (-not $selectedIds.ContainsKey([string]$show.MediaId))
                    if ($answer -in @('QUIT','EXPORT')) { Save-AnimeDatabase; return $answer }
                }
                elseif ($key -eq 'LeftArrow') { Save-AnimeDatabase; return $null }
            }
        }
    }
}

# Main flow
# A state machine rather than the old pattern of relaunching the script by path
# to move between menus. Navigation no longer nests script instances, reloads
# the database, or depends on $PSCommandPath.

$seasonData = $null
$shows = @()
$excluded = @{}
$exportPath = $null
$refreshUsed = $false

function Sync-ExclusionState {
    $selectedIds = @{}
    foreach ($id in @($script:Db.Selections)) { $selectedIds[[string]$id] = $true }
    $map = @{}
    # Exclusions depend on selections, not on episode dates or season membership.
    foreach ($id in $script:Db.Shows.Keys) {
        $key = [string]$id
        if (-not $selectedIds.ContainsKey($key)) {
            $map[$key] = [string]$script:Db.Shows[$key].Title
        }
    }
    return $map
}

$state = if ($interactive) { 'MAIN' } else { 'LOAD' }
$exitRequested = $false
$exportReturnState = 'MAIN'

while (-not $exitRequested) {
    if ($state -in @('MAIN','MANAGE','PROVIDERS','WEEK','UPDATES','SEASONPICK','GENRE')) { $exportReturnState = $state }
    switch ($state) {

        'MAIN' {
            $visibleUpdates = @(Get-VisiblePendingUpdates)
            $items = @([pscustomobject]@{Label='Create or update a calendar';Value='LOAD'})
            $items += [pscustomobject]@{Label="Providers ($(@($script:Db.EnabledProviders).Count) enabled)";Value='PROVIDERS'}
            if ($visibleUpdates.Count) {
                $items += [pscustomobject]@{Label="Review updated shows ($($visibleUpdates.Count))";Value='UPDATES'}
            }
            if ($script:Db.PendingExport) { $items += [pscustomobject]@{Label=$(if(Test-ShowSelectionModifications){'Update ICS with modifications'}else{'Export pending changes'});Value='EXPORT'} }
            $items += [pscustomobject]@{Label='Airing this week';Value='WEEK'}
            $items += [pscustomobject]@{Label='Quit';Value='QUIT'}
            $footer = @("Data Scraped (Total/Session): $(Format-DataSize ([long]$script:Db.ScrapeBytesTotal)) / $(Format-DataSize ([long](($script:DownloadBytes.Values | Measure-Object -Sum).Sum)))")
            $choice = Show-KeyMenu -Title 'Anime Calendar' -Items $items -Footer $footer
            if ($null -eq $choice -or $choice -eq 'QUIT') { $state = 'QUIT' }
            elseif ($choice -eq 'LOAD') {
                # The season is only asked for when the command line did not
                # already pin one down.
                $pinned = $NextSeason -or $PSBoundParameters.ContainsKey('Season') -or $PSBoundParameters.ContainsKey('Year')
                $state = if ($pinned) { 'LOAD' } else { 'SEASONPICK' }
            }
            elseif ($choice -eq 'EXPORT') { $state = 'FOLDER' }
            else { $state = $choice }
        }

        'PROVIDERS' {
            $answer=Show-ProvidersMenu $currentSeason
            if($answer-eq'QUIT'){$state='QUIT'}elseif($answer-eq'EXPORT'){$state='EXPORT'}else{$state='MAIN'}
        }


        'WEEK' {
            $answer=Show-WeekAirings
            if ($answer -in @('QUIT','EXPORT')) { $state=$answer } else { $state='MAIN' }
        }

        'UPDATES' {
            $answer = Show-PendingUpdates
            if ($answer -eq 'QUIT') { $state = 'QUIT' }
            elseif ($answer -eq 'EXPORT') { $state = 'EXPORT' }
            else { $state = 'MAIN' }
        }

        'SEASONPICK' {
            Initialize-SeasonMenu $currentSeason
            $picked = Show-KeyMenu -Title 'Select anime season' -Back -Items (Get-SeasonMenuItems $currentSeason)
            if ($picked -eq 'QUIT') { $state = 'QUIT' }
            elseif ($picked -eq 'EXPORT') { $state = 'EXPORT' }
            elseif ($null -eq $picked) { $state = 'MAIN' }
            else { $targetSeason = $picked; $state = 'GENRE' }
        }

        'GENRE' {
            $picked = Show-GenreMenu -Title "Select genre - $($targetSeason.Season) $($targetSeason.Year)"
            if ($picked -eq 'QUIT') { $state = 'QUIT' }
            elseif ($picked -eq 'EXPORT') { $state = 'EXPORT' }
            elseif ($null -eq $picked) { $state = 'SEASONPICK' }
            else { $CategoryFilter = $picked; $state = 'LOAD' }
        }

        'LOAD' {
            try {
                # -Refresh applies to the first load only. Without this, every
                # trip back through the genre menu would re-scrape AniList.
                $forceRefresh = $Refresh -and -not $refreshUsed
                $seasonData = Get-SeasonData -SeasonName $targetSeason.Season -SeasonYear $targetSeason.Year -ForceRefresh:$forceRefresh
                $refreshUsed = $true
            } catch {
                Write-Warning "Could not load $($targetSeason.Season) $($targetSeason.Year): $($_.Exception.Message)"
                if (-not $interactive) { throw }
                Write-Host 'Press any key to return to the menu.' -ForegroundColor DarkGray
                $null = Read-MenuKey
                $state = 'MAIN'
                break
            }
            # Shows are not added to the calendar by default. A newly discovered
            # title is recorded in KnownShows but left out of Selections, so it
            # appears under "Shows not added" until you choose it. KnownShows is
            # still what separates "never seen" from "deliberately removed".
            $known = @{}
            foreach ($id in @($script:Db.KnownShows)) { $known[[string]$id] = $true }
            $changed = $false
            foreach ($id in (Get-SeasonShowIds $seasonData)) {
                if ($known.ContainsKey([string]$id)) { continue }
                $known[[string]$id] = $true
                $changed = $true
            }
            if ($changed) {
                $script:Db.KnownShows = @($known.Keys | Sort-Object)
                Set-DatabaseDirty
                Save-AnimeDatabase
            }
            $excluded = Sync-ExclusionState
            $shows = Get-SeasonShowView $targetSeason $seasonData -Filter $CategoryFilter
            $state = if ($interactive) { 'MANAGE' } else { 'EXPORT' }
        }

        'MANAGE' {
            $seasonLabel="$(if ($targetSeason.View -eq 'Last') { 'Last - ' })$($targetSeason.Season) $($targetSeason.Year)"
            $answer = Show-ManagementMenu -Shows $shows -Excluded $excluded -SeasonLabel $seasonLabel
            Save-AnimeDatabase
            switch ($answer) {
                'QUIT'   { $state = 'QUIT' }
                'EXPORT' { $state = 'FOLDER' }
                'GENRE'  { $state = 'GENRE' }
                'SEASON' { $seasonData = $null; $state = 'SEASONPICK' }
                'BACK'   { $state = 'MAIN' }
                default  { $state = 'MAIN' }
            }
        }

        'FOLDER' {
            if ($OutputPath) { $exportPath = Resolve-OutputPath -Requested $OutputPath -FallbackDirectory $launchDirectory; $state = 'EXPORT'; break }
            $folder = Select-CalendarFolder -Start $launchDirectory
            if ($folder -in @('QUIT','EXPORT')) { $state = $folder }
            elseif ($null -eq $folder) { $state = $exportReturnState }
            else {
                $exportPath = Join-Path $folder 'anime-calendar.ics'
                $script:Db.OutputDirectory = $folder
                Set-DatabaseDirty
                $state = 'EXPORT'
            }
        }

        'EXPORT' {
            if (-not $exportPath) {
                $exportPath = Resolve-OutputPath -Requested $OutputPath -FallbackDirectory $launchDirectory
            }
            if ([IO.Path]::GetExtension($exportPath) -ne '.ics') { throw 'OutputPath must end in .ics.' }
            $excluded = Sync-ExclusionState
            $result = Export-AnimeCalendar -Path $exportPath -Excluded $excluded
            $script:Db.OutputDirectory = Split-Path $exportPath -Parent
            $script:Db.AppliedSelections = @($script:Db.Selections)
            $script:Db.PendingExport = $false
            Set-DatabaseDirty
            Save-AnimeDatabase

            Write-Host ''
            Write-Host "Created $($result.Path)" -ForegroundColor Green
            Write-Host ("  {0} event(s): {1} generated, {2} merged from existing calendars. Genre filter: {3}." -f `
                $result.Total,$result.Generated,$result.Merged,$CategoryFilter) -ForegroundColor Green
            if ($result.Total -eq 0) {
                # Distinguish "you have not picked anything yet" from "there is
                # nothing to pick". Since shows are not added by default, the
                # first is much the more likely of the two.
                if ((@($script:Db.Selections).Count -eq 0) -and ($script:Db.Shows.Count -gt 0)) {
                    Write-Warning "The calendar is empty because no shows have been added. Shows are not added by default - choose them under 'Shows not added' in the menu (Space adds), then export again."
                } else {
                    Write-Warning "No titles currently have both a supported streaming-provider attribution and a published release time. Upcoming-season data appears as services announce their lineups; try again later."
                }
            }
            Write-Warning 'Provider schedules are preferred; entries marked broadcast fallback may precede streaming availability. Schedules vary by region.'
            if ($script:AniListRequests -gt 0) { Write-Verbose "AniList requests this run: $script:AniListRequests" }

            if (-not $interactive) { $state = 'QUIT'; break }
            $after = Show-KeyMenu -Title 'Calendar created' -Items @(
                [pscustomobject]@{Label='Back to previous menu';Value='BACK'}
                [pscustomobject]@{Label='Quit';Value='QUIT'}
            )
            if ($after -eq 'BACK') {
                $state = $exportReturnState
            } else { $state = 'QUIT' }
        }

        'QUIT' {
            $exitRequested = $true
        }

        default { $exitRequested = $true }
    }
}

Save-AnimeDatabase
if ($interactive) {
    Clear-Host
    if ($exportPath -and (Test-Path -LiteralPath $exportPath)) {
        Write-Host "Calendar saved to $exportPath" -ForegroundColor Green
    } else {
        Write-Host 'No calendar changes were exported.' -ForegroundColor DarkGray
    }
}
if($MetricsPath){[ordered]@{AniListRequests=$script:AniListRequests;Sources=$script:DownloadBytes;TotalBytes=[long](($script:DownloadBytes.Values|Measure-Object -Sum).Sum)}|ConvertTo-Json -Depth 4|Set-Content -LiteralPath $MetricsPath -Encoding UTF8}
