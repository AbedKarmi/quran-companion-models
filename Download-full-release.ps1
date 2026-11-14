$ErrorActionPreference = 'Stop'
$Repo = 'AbedKarmi/quran-companion-models'
$Backup = 'B:\Flutter\quran-companion-models\Release'
$DownloadActions = $true
$DownloadLogs = $true

foreach ($cmd in @('gh', 'curl.exe')) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        throw "Missing command: $cmd"
    }
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
$ReleasesDir = Join-Path $Backup 'Releases'
$ActionsDir = Join-Path $Backup 'Actions'
$ArtifactsDir = Join-Path $ActionsDir 'Artifacts'
$RunsDir = Join-Path $ActionsDir 'Runs'
$Work = Join-Path $Backup ('.backup-work-' + [System.Guid]::NewGuid().ToString('N'))
foreach ($dir in @($Backup, $ReleasesDir, $ActionsDir, $ArtifactsDir, $RunsDir, $Work)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
}
$script:Failures = New-Object 'System.Collections.Generic.List[string]'
$script:Token = $null

function Report-Failure([string]$Message) {
    $script:Failures.Add($Message)
    Write-Warning $Message
}
function Safe-Name([string]$Name) {
    $value = ($Name -replace '[<>:"/\\|?*\x00-\x1F]', '_').Trim().TrimEnd('.')
    if ([System.String]::IsNullOrWhiteSpace($value)) { $value = 'unnamed' }
    if ($value.Length -gt 80) { $value = $value.Substring(0, 80) }
    return $value
}
function Get-Pages([string]$Endpoint, [string]$Property = '') {
    $page = 1
    do {
        $sep = '?'
        if ($Endpoint.Contains('?')) { $sep = '&' }
        $raw = & gh api --hostname github.com "${Endpoint}${sep}per_page=100&page=$page"
        if ($LASTEXITCODE -ne 0) { throw "API failed: $Endpoint" }
        $data = ($raw -join "`n") | ConvertFrom-Json
        if ($Property) { $items = @($data.$Property) }
        else { $items = @($data) }
        foreach ($item in $items) {
            if ($null -ne $item) { Write-Output $item }
        }
        $page++
    } while ($items.Count -eq 100)
}
function Save-Json($Value, [string]$Path) {
    ConvertTo-Json -InputObject $Value -Depth 100 | Set-Content -LiteralPath $Path -Encoding UTF8
}
function Download-File([string]$Endpoint, [string]$Destination, [string]$Accept = 'application/vnd.github+json', [long]$ExpectedSize = -1) {
    $temp = Join-Path $Work ([System.Guid]::NewGuid().ToString('N') + '.download')
    try {
        Write-Host "Downloading: $Destination" -ForegroundColor Green
        $config = 'header = "Authorization: Bearer ' + $script:Token + '"'
        $curlArgs = @('--config', '-', '--location', '--fail', '--show-error', '--retry', '3', '--connect-timeout', '30', '--proto', '=https', '--proto-redir', '=https', '--header', "Accept: $Accept", '--output', $temp, "https://api.github.com/$Endpoint")
        $config | & curl.exe @curlArgs
        if ($LASTEXITCODE -ne 0) { throw "Download failed: $Endpoint" }
        if ($ExpectedSize -ge 0 -and (Get-Item -LiteralPath $temp).Length -ne $ExpectedSize) {
            throw "Downloaded size does not match: $Destination"
        }
        Move-Item -LiteralPath $temp -Destination $Destination -Force
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
    }
}

try {
    if ($env:GH_TOKEN) { $script:Token = $env:GH_TOKEN }
    elseif ($env:GITHUB_TOKEN) { $script:Token = $env:GITHUB_TOKEN }
    else {
        $rawToken = & gh auth token --hostname github.com
        if ($LASTEXITCODE -ne 0) { throw 'Run gh auth login first.' }
        $script:Token = ($rawToken -join '').Trim()
    }
    if ([System.String]::IsNullOrWhiteSpace($script:Token)) { throw 'No authentication token found.' }

    Write-Host 'Getting releases...' -ForegroundColor Cyan
    $releases = @(Get-Pages "repos/$Repo/releases")
    Save-Json $releases (Join-Path $ReleasesDir 'releases.json')
    foreach ($release in $releases) {
        $name = '{0}__{1}' -f (Safe-Name $release.tag_name), $release.id
        $stage = Join-Path $Work $name
        $assetsDir = Join-Path $stage 'assets'
        $zip = Join-Path $Work "$name.zip"
        try {
            Write-Host "Release: $($release.tag_name)" -ForegroundColor Yellow
            New-Item -ItemType Directory -Path $assetsDir -Force | Out-Null
            Save-Json $release (Join-Path $stage 'release.json')
            Set-Content -LiteralPath (Join-Path $stage 'release-notes.md') -Value ([string]$release.body) -Encoding UTF8
            $assets = @(Get-Pages "repos/$Repo/releases/$($release.id)/assets")
            Save-Json $assets (Join-Path $stage 'assets.json')
            foreach ($asset in $assets) {
                $assetName = [string]$asset.name
                if ([System.String]::IsNullOrWhiteSpace($assetName) -or $assetName -in @('.', '..') -or $assetName -match '[<>:"/\\|?*\x00-\x1F]' -or $assetName.EndsWith('.') -or $assetName.EndsWith(' ') -or $assetName -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)') {
                    throw "Unsafe Windows asset filename: $assetName"
                }
                Download-File "repos/$Repo/releases/assets/$($asset.id)" (Join-Path $assetsDir $assetName) 'application/octet-stream' ([long]$asset.size)
            }
            $tag = [System.Uri]::EscapeDataString([string]$release.tag_name)
            Download-File "repos/$Repo/zipball/$tag" (Join-Path $stage 'source.zip')
            Write-Host "Compressing: $name.zip" -ForegroundColor Cyan
            [System.IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip, [System.IO.Compression.CompressionLevel]::Optimal, $false)
            Move-Item -LiteralPath $zip -Destination (Join-Path $ReleasesDir "$name.zip") -Force
        } catch {
            Report-Failure "Release '$name': $($_.Exception.Message)"
        } finally {
            if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
            if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
        }
    }
    try {
        Download-File "repos/$Repo/zipball" (Join-Path $Backup 'Repository-source.zip')
    } catch { Report-Failure "Repository snapshot: $($_.Exception.Message)" }

    if ($DownloadActions) {
        try {
            $artifacts = @(Get-Pages "repos/$Repo/actions/artifacts" 'artifacts')
            Save-Json $artifacts (Join-Path $ActionsDir 'artifacts.json')
            foreach ($artifact in $artifacts) {
                if ($artifact.expired) {
                    Write-Warning "Expired artifact skipped: $($artifact.name)"
                    continue
                }
                $name = '{0}__{1}.zip' -f (Safe-Name $artifact.name), $artifact.id
                try {
                    Download-File "repos/$Repo/actions/artifacts/$($artifact.id)/zip" (Join-Path $ArtifactsDir $name)
                } catch { Report-Failure "Artifact '$name': $($_.Exception.Message)" }
            }
        } catch { Report-Failure "Artifact listing: $($_.Exception.Message)" }
        try {
            $runs = @(Get-Pages "repos/$Repo/actions/runs" 'workflow_runs')
            Save-Json $runs (Join-Path $ActionsDir 'runs.json')
            foreach ($run in $runs) {
                $name = 'run-{0}-attempt-{1}' -f $run.id, $run.run_attempt
                Save-Json $run (Join-Path $RunsDir "$name.json")
                if ($DownloadLogs -and $run.status -eq 'completed') {
                    try {
                        Download-File "repos/$Repo/actions/runs/$($run.id)/attempts/$($run.run_attempt)/logs" (Join-Path $RunsDir "$name-logs.zip")
                    } catch { Report-Failure "Logs '$name': $($_.Exception.Message)" }
                }
            }
        } catch { Report-Failure "Workflow runs: $($_.Exception.Message)" }
    }
} catch {
    Report-Failure "Backup stopped: $($_.Exception.Message)"
} finally {
    $script:Token = $null
    if (Test-Path -LiteralPath $Work) { Remove-Item -LiteralPath $Work -Recurse -Force }
}

$failureLog = Join-Path $Backup 'backup-errors.txt'
if ($script:Failures.Count -gt 0) {
    $script:Failures | Set-Content -LiteralPath $failureLog -Encoding UTF8
    Write-Warning "Backup finished with $($script:Failures.Count) issue(s). See $failureLog"
} else {
    if (Test-Path -LiteralPath $failureLog) { Remove-Item -LiteralPath $failureLog -Force }
    Write-Host 'Backup completed successfully.' -ForegroundColor Green
}
Write-Host "Location: $Backup" -ForegroundColor Cyan
