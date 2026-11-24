# Builds repo.json from the GitHub releases of every repository in plugins.json.
# Newest non-prerelease = stable; a newer prerelease = testing version.
param([string] $PluginsFile = 'plugins.json', [string] $Output = 'repo.json')

$headers = @{ Accept = 'application/vnd.github+json' }
if ($env:GH_TOKEN) { $headers['Authorization'] = "Bearer $env:GH_TOKEN" }

function Get-Text($url) {
    $content = (Invoke-WebRequest $url -Headers @{ Accept = 'application/octet-stream' }).Content
    if ($content -is [byte[]]) { return [Text.Encoding]::UTF8.GetString($content).TrimStart([char]0xFEFF) }
    return $content.TrimStart([char]0xFEFF)
}

function Get-Asset($release, $name) {
    $asset = $release.assets | Where-Object { $_.name -eq $name } | Select-Object -First 1
    if (-not $asset) { return $null }
    return $asset.browser_download_url
}

$entries = @()
foreach ($plugin in (Get-Content $PluginsFile -Raw | ConvertFrom-Json)) {
    # Invoke-RestMethod hands back the whole array as one item; unroll it
    $releases = Invoke-RestMethod "https://api.github.com/repos/$($plugin.repo)/releases?per_page=50" -Headers $headers |
        ForEach-Object { $_ } |
        Where-Object { -not $_.draft -and (Get-Asset $_ 'latest.zip') -and (Get-Asset $_ "$($plugin.internalName).json") }

    $newest = $releases | Select-Object -First 1
    if (-not $newest) { Write-Warning "No releases for $($plugin.repo)"; continue }
    $stable = $releases | Where-Object { -not $_.prerelease } | Select-Object -First 1
    $base = if ($stable) { $stable } else { $newest }

    $entry = Get-Text (Get-Asset $base "$($plugin.internalName).json") | ConvertFrom-Json -AsHashtable
    $zip = Get-Asset $base 'latest.zip'
    $entry['DownloadLinkInstall'] = $zip
    $entry['DownloadLinkUpdate'] = $zip
    $entry['TestingAssemblyVersion'] = $entry['AssemblyVersion']
    $entry['TestingDalamudApiLevel'] = $entry['DalamudApiLevel']
    $entry['DownloadLinkTesting'] = $zip

    if ($newest.prerelease -and $newest.id -ne $base.id) {
        $testing = Get-Text (Get-Asset $newest "$($plugin.internalName).json") | ConvertFrom-Json -AsHashtable
        if ([version]$testing['AssemblyVersion'] -gt [version]$entry['AssemblyVersion']) {
            $entry['TestingAssemblyVersion'] = $testing['AssemblyVersion']
            $entry['TestingDalamudApiLevel'] = $testing['DalamudApiLevel']
            $entry['DownloadLinkTesting'] = Get-Asset $newest 'latest.zip'
        }
    }

    if (-not $stable) { $entry['IsTestingExclusive'] = $true }
    if ($base.body) { $entry['Changelog'] = $base.body.Trim() }
    $entry['LastUpdate'] = ([DateTimeOffset]$newest.published_at).ToUnixTimeSeconds()
    $entries += $entry
}

ConvertTo-Json @($entries | Sort-Object { $_['Name'] }) -Depth 5 | Set-Content -Encoding utf8 $Output
Write-Host "Wrote $($entries.Count) plugins to $Output"
