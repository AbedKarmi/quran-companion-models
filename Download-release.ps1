[CmdletBinding()]
param(
    [ValidateSet('Incremental', 'Full')]
    [string]$Mode = 'Incremental',
    [string]$Backup = (Join-Path $PSScriptRoot 'Release'),
    [switch]$SkipActions,
    [switch]$SkipLogs
)

$invocation = "& '" + $PSCommandPath.Replace("'", "''") + "'"
Write-Host 'Usage' -ForegroundColor Cyan
Write-Host "  $invocation -Mode Incremental   # New and modified items (default)"
Write-Host "  $invocation -Mode Full          # Download all available items again"
Write-Host "  -Backup '<folder>'              Use a different destination (default: Release beside the script)"
Write-Host '  -SkipActions                    Skip GitHub Actions artifacts, runs, and logs'
Write-Host '  -SkipLogs                       Skip only workflow logs'
Write-Host ''

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$repo = 'AbedKarmi/quran-companion-models'
$full = $Mode -eq 'Full'
$failures = [System.Collections.Generic.List[string]]::new()

foreach ($command in @('gh', 'curl.exe')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "Missing command: $command"
    }
}
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Get-Pages([string]$Endpoint, [string]$Property) {
    for ($page = 1; ; $page++) {
        $raw = & gh api --hostname github.com "${Endpoint}?per_page=100&page=$page"
        if ($LASTEXITCODE -ne 0) { throw "GitHub API failed: $Endpoint (page $page)" }
        $data = ($raw -join [Environment]::NewLine) | ConvertFrom-Json
        $items = @($data | Where-Object { $null -ne $_ })
        if ($Property) { $items = @($data.$Property | Where-Object { $null -ne $_ }) }
        $items
        if ($items.Count -lt 100) { break }
    }
}

function Get-Commit([string]$Ref, [switch]$AllowMissing) {
    $escapedRef = [Uri]::EscapeDataString($Ref)
    # Capture gh's HTTP error so only a missing draft tag triggers the branch fallback.
    $ErrorActionPreference = 'Continue'
    $response = & gh api --hostname github.com -H 'Accept: application/vnd.github.sha' "repos/$repo/commits/$escapedRef" 2>&1
    $sha = ($response -join '').Trim()
    if ($AllowMissing -and $LASTEXITCODE -ne 0 -and $sha -match '\(HTTP 404\)') { return }
    if ($LASTEXITCODE -ne 0 -or $sha -notmatch '^[0-9a-f]{40}$') {
        throw "Could not resolve GitHub commit for '${Ref}': $sha"
    }
    return $sha
}

function Safe-Name([string]$Name) {
    $value = ($Name -replace '[<>:"/\\|?*\x00-\x1F]', '_').Trim().TrimEnd('.')
    if (-not $value) { $value = 'unnamed' }
    return $value.Substring(0, [Math]::Min($value.Length, 80))
}

function Publish-File([string]$Source, [string]$Destination) {
    if ([IO.File]::Exists($Destination)) {
        [IO.File]::Replace($Source, $Destination, [NullString]::Value)
    } else {
        [IO.File]::Move($Source, $Destination)
    }
}

function Save-Text([string]$Value, [string]$Path) {
    if (-not $full -and [IO.File]::Exists($Path) -and [IO.File]::ReadAllText($Path) -ceq $Value) {
        return
    }
    $temp = Join-Path $work ([Guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllText($temp, $Value)
    Publish-File $temp $Path
}

function Save-Json($Value, [string]$Path) {
    Save-Text (ConvertTo-Json -InputObject $Value -Depth 100) $Path
}

function Report-Failure([string]$Message) {
    $failures.Add($Message)
    Write-Warning $Message
}

function Download-File(
    [string]$Endpoint,
    [string]$Destination,
    [string]$Accept = 'application/vnd.github+json',
    [long]$ExpectedSize = -1,
    [string]$Digest,
    [switch]$AllowUnavailable
) {
    $temp = Join-Path $work ([Guid]::NewGuid().ToString('N') + '.download')
    try {
        Write-Host "Downloading $([IO.Path]::GetFileName($Destination))"
        # Keep the token out of the command line and let curl strip it on cross-host redirects.
        $config = 'header = "Authorization: Bearer ' + $token + '"'
        $curlArgs = @('--config', '-', '--location', '--fail', '--silent', '--show-error',
            '--retry', '3', '--connect-timeout', '30', '--proto', '=https', '--proto-redir', '=https',
            '--header', "Accept: $Accept", '--output', $temp, '--write-out', '%{http_code}', "https://api.github.com/$Endpoint")
        $status = $config | & curl.exe @curlArgs
        if ($LASTEXITCODE -ne 0) {
            if ($AllowUnavailable -and $LASTEXITCODE -eq 22 -and $status -in @('404', '410')) { return $false }
            throw "Download failed (HTTP $status): $Endpoint"
        }
        if ($ExpectedSize -ge 0 -and (Get-Item -LiteralPath $temp).Length -ne $ExpectedSize) {
            throw "Downloaded size does not match: $Destination"
        }
        if ($Digest -match '^sha256:([0-9a-f]{64})$') {
            $expectedHash = $Matches[1]
            if ((Get-FileHash -LiteralPath $temp -Algorithm SHA256).Hash -ne $expectedHash) {
                throw "SHA-256 does not match: $Destination"
            }
        }
        Publish-File $temp $Destination
        return $true
    } finally {
        [IO.File]::Delete($temp)
    }
}

function Read-ZipText($Archive, [string]$Name) {
    $entry = $Archive.GetEntry($Name)
    if ($null -eq $entry) { return }
    $reader = [IO.StreamReader]::new($entry.Open())
    try { $reader.ReadToEnd() } finally { $reader.Dispose() }
}

function Backup-Release($Release) {
    $id = [long]$Release.id
    $name = '{0}__{1}' -f (Safe-Name $Release.tag_name), $id
    $destination = Join-Path $releasesDir "$name.zip"
    $assets = @(Get-Pages "repos/$repo/releases/$id/assets")
    $sourceSha = Get-Commit "tags/$($Release.tag_name)" -AllowMissing:$Release.draft
    if (-not $sourceSha) { $sourceSha = Get-Commit $Release.target_commitish }
    $releaseFields = @('id', 'tag_name', 'target_commitish', 'name', 'body', 'draft',
        'prerelease', 'immutable', 'created_at', 'published_at', 'discussion_url')
    $assetFields = @('id', 'name', 'size', 'digest', 'updated_at')
    $savedAssets = @{}
    $filesToReuse = @{}
    $assetNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $previous = $null
    $stage = Join-Path $work ("release-" + [Guid]::NewGuid().ToString('N'))
    $zip = "$stage.zip"

    try {
        $sameRelease = $false
        $sameSource = $false
        if (-not $full -and [IO.File]::Exists($destination)) {
            try {
                $previous = [IO.Compression.ZipFile]::OpenRead($destination)
                $releaseJson = Read-ZipText $previous 'release.json'
                $assetsJson = Read-ZipText $previous 'assets.json'
                if ($releaseJson -and $assetsJson) {
                    $savedRelease = $releaseJson | ConvertFrom-Json
                    foreach ($saved in ($assetsJson | ConvertFrom-Json)) {
                        if ($null -ne $saved) { $savedAssets[[long]$saved.id] = $saved }
                    }
                    $savedReleaseInfo = $savedRelease | Select-Object -Property $releaseFields | ConvertTo-Json -Compress
                    $releaseInfo = $Release | Select-Object -Property $releaseFields | ConvertTo-Json -Compress
                    $sameRelease = $savedReleaseInfo -ceq $releaseInfo -and $null -ne $previous.GetEntry('release-notes.md')
                    $sameSource = (Read-ZipText $previous 'source-commit.txt') -eq $sourceSha -and $null -ne $previous.GetEntry('source.zip')
                }
            } catch {
                if ($previous) { $previous.Dispose() }
                $previous = $null
                $savedAssets.Clear()
                $sameRelease = $false
                $sameSource = $false
                Write-Warning "Reading $name.zip failed. Rebuilding it."
            }
        }

        $sameAssets = $savedAssets.Count -eq $assets.Count
        foreach ($asset in $assets) {
            $assetName = [string]$asset.name
            if (-not $assetName -or $assetName -match '[<>:"/\\|?*\x00-\x1F]|[. ]$|^(CON|PRN|AUX|NUL|(COM|LPT)[1-9\u00B9\u00B2\u00B3])([.]|$)' -or -not $assetNames.Add($assetName)) {
                throw "Invalid or duplicate Windows asset filename: $assetName"
            }
            $saved = $savedAssets[[long]$asset.id]
            if ($saved) {
                $entry = $previous.GetEntry("assets/$($saved.name)")
                if (-not $entry) { $entry = $previous.GetEntry("assets\$($saved.name)") }
                $savedAssetInfo = $saved | Select-Object -Property $assetFields | ConvertTo-Json -Compress
                $assetInfo = $asset | Select-Object -Property $assetFields | ConvertTo-Json -Compress
                $hasMatchingDigest = $asset.digest -match '^sha256:[0-9a-f]{64}$' -and $asset.digest -eq $saved.digest
                if ($entry -and $entry.Length -eq [long]$asset.size -and ($hasMatchingDigest -or $assetInfo -ceq $savedAssetInfo)) {
                    $filesToReuse[[long]$asset.id] = $entry
                    if ($assetInfo -ceq $savedAssetInfo -and $asset.label -ceq $saved.label -and $asset.content_type -ceq $saved.content_type) {
                        continue
                    }
                }
            }
            $sameAssets = $false
        }
        if ($sameRelease -and $sameSource -and $sameAssets) {
            Write-Host "Unchanged release $($Release.tag_name)" -ForegroundColor DarkGray
            return
        }

        if ($full) {
            Write-Host "Backing up release $($Release.tag_name)" -ForegroundColor Cyan
        } elseif (-not [IO.File]::Exists($destination)) {
            Write-Host "New release $($Release.tag_name)" -ForegroundColor Cyan
        } else {
            $changes = @(
                if (-not $sameRelease) { 'release details' }
                if (-not $sameAssets) { 'assets' }
                if (-not $sameSource) { 'source ZIP' }
            )
            Write-Host "Updating release $($Release.tag_name) ($($changes -join ', '))" -ForegroundColor Cyan
        }
        $assetsDir = Join-Path $stage 'assets'
        New-Item -ItemType Directory -Path $assetsDir -Force | Out-Null
        Save-Json $Release (Join-Path $stage 'release.json')
        Save-Json $assets (Join-Path $stage 'assets.json')
        Save-Text ([string]$Release.body) (Join-Path $stage 'release-notes.md')
        Save-Text $sourceSha (Join-Path $stage 'source-commit.txt')
        foreach ($asset in $assets) {
            $assetPath = Join-Path $assetsDir $asset.name
            $entry = $filesToReuse[[long]$asset.id]
            if ($entry) {
                [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $assetPath)
            } else {
                $null = Download-File "repos/$repo/releases/assets/$($asset.id)" $assetPath 'application/octet-stream' ([long]$asset.size) $asset.digest
            }
        }
        $sourcePath = Join-Path $stage 'source.zip'
        if ($sameSource) {
            [IO.Compression.ZipFileExtensions]::ExtractToFile($previous.GetEntry('source.zip'), $sourcePath)
        } else {
            $null = Download-File "repos/$repo/zipball/$sourceSha" $sourcePath
        }
        if ($previous) { $previous.Dispose(); $previous = $null }
        [IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip, [IO.Compression.CompressionLevel]::Optimal, $false)
        Publish-File $zip $destination
    } finally {
        if ($previous) { $previous.Dispose() }
        Remove-StagingDirectory $stage
        [IO.File]::Delete($zip)
    }
}

function Remove-StagingDirectory([string]$Path) {
    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($resolved -and $resolved.ProviderPath.StartsWith($backupRoot, [StringComparison]::OrdinalIgnoreCase) -and
        -not ((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        Remove-Item -LiteralPath $resolved.ProviderPath -Recurse -Force
    }
}

$token = $env:GH_TOKEN
if (-not $token) { $token = $env:GITHUB_TOKEN }
if (-not $token) {
    $token = ((& gh auth token --hostname github.com) -join '').Trim()
    if ($LASTEXITCODE -ne 0 -or -not $token) { throw 'Run gh auth login first.' }
}
if ($token -notmatch '^[A-Za-z0-9_-]+$') { throw 'GitHub authentication token has an unexpected format.' }

New-Item -ItemType Directory -Path $Backup -Force | Out-Null
$Backup = (Resolve-Path -LiteralPath $Backup).ProviderPath
$backupRoot = $Backup.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
$lockPath = Join-Path $Backup '.backup.lock'
try {
    $lock = [IO.FileStream]::new($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite,
        [IO.FileShare]::None, 4096, [IO.FileOptions]::DeleteOnClose)
} catch {
    throw "Could not lock '$Backup' for this backup: $($_.Exception.Message)"
}
$work = Join-Path $Backup ('.backup-work-' + [Guid]::NewGuid().ToString('N'))
$releasesDir = Join-Path $Backup 'Releases'
try {
    New-Item -ItemType Directory -Path $work, $releasesDir -Force | Out-Null
    Write-Host "$Mode backup to $Backup" -ForegroundColor Cyan
    $releases = @(Get-Pages "repos/$repo/releases")
    Save-Json $releases (Join-Path $releasesDir 'releases.json')
    foreach ($release in $releases) {
        try { Backup-Release $release }
        catch { Report-Failure "Release '$($release.tag_name)': $($_.Exception.Message)" }
    }

    try {
        $sourceSha = Get-Commit 'HEAD'
        $repoZip = Join-Path $Backup 'Repository-source.zip'
        $sourceMarker = Join-Path $Backup 'Repository-source.commit.txt'
        if ($full -or -not [IO.File]::Exists($repoZip) -or -not [IO.File]::Exists($sourceMarker) -or
            [IO.File]::ReadAllText($sourceMarker) -ne $sourceSha) {
            $null = Download-File "repos/$repo/zipball/$sourceSha" $repoZip
            Save-Text $sourceSha $sourceMarker
        }
    } catch { Report-Failure "Repository snapshot: $($_.Exception.Message)" }

    if (-not $SkipActions) {
        $actionsDir = Join-Path $Backup 'Actions'
        $artifactsDir = Join-Path $actionsDir 'Artifacts'
        $runsDir = Join-Path $actionsDir 'Runs'
        New-Item -ItemType Directory -Path $artifactsDir, $runsDir -Force | Out-Null
        try {
            $artifacts = @(Get-Pages "repos/$repo/actions/artifacts" 'artifacts')
            Save-Json $artifacts (Join-Path $actionsDir 'artifacts.json')
            foreach ($artifact in $artifacts) {
                if ($artifact.expired) { continue }
                $name = '{0}__{1}.zip' -f (Safe-Name $artifact.name), [long]$artifact.id
                $dest = Join-Path $artifactsDir $name
                if ($full -or -not [IO.File]::Exists($dest)) {
                    try { $null = Download-File "repos/$repo/actions/artifacts/$($artifact.id)/zip" $dest }
                    catch { Report-Failure "Artifact '$name': $($_.Exception.Message)" }
                }
            }
        } catch { Report-Failure "Artifact listing: $($_.Exception.Message)" }

        try {
            $runs = @(Get-Pages "repos/$repo/actions/runs" 'workflow_runs')
            Save-Json $runs (Join-Path $actionsDir 'runs.json')
            foreach ($run in $runs) {
                $name = 'run-{0}-attempt-{1}' -f [long]$run.id, [int]$run.run_attempt
                $logPath = Join-Path $runsDir "$name-logs.zip"
                $marker = "$logPath.unavailable"
                try {
                    Save-Json $run (Join-Path $runsDir "$name.json")
                    if ($SkipLogs -or $run.status -ne 'completed') { continue }
                    if (-not $full -and ([IO.File]::Exists($logPath) -or [IO.File]::Exists($marker))) { continue }
                    $downloaded = Download-File "repos/$repo/actions/runs/$($run.id)/attempts/$($run.run_attempt)/logs" $logPath -AllowUnavailable
                    if ($downloaded) {
                        [IO.File]::Delete($marker)
                    } else {
                        Save-Text 'Logs unavailable on GitHub.' $marker
                        Write-Warning "Logs unavailable on GitHub: $name"
                    }
                } catch { Report-Failure "Workflow run '$name': $($_.Exception.Message)" }
            }
        } catch { Report-Failure "Workflow run listing: $($_.Exception.Message)" }
    }
} catch {
    Report-Failure "Backup stopped: $($_.Exception.Message)"
} finally {
    try {
        $failureLog = Join-Path $Backup 'backup-errors.txt'
        if ($failures.Count) {
            $failures | Set-Content -LiteralPath $failureLog -Encoding UTF8
        } else {
            [IO.File]::Delete($failureLog)
        }
        Remove-StagingDirectory $work
    } finally {
        $lock.Dispose()
    }
}

if ($failures.Count) { throw "Backup finished with $($failures.Count) issue(s). See $failureLog." }
Write-Host 'Backup completed successfully.' -ForegroundColor Green
