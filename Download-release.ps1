$ErrorActionPreference = "Stop"

$Repo   = "AbedKarmi/quran-companion-models"
$Backup = "B:\Flutter\quran-companion-models\Release"

New-Item -ItemType Directory -Force -Path $Backup | Out-Null

Write-Host "Getting releases from GitHub..." -ForegroundColor Cyan

$releases = gh api `
    --paginate `
    "repos/$Repo/releases?per_page=100" |
    ConvertFrom-Json

foreach ($release in $releases) {

    $tag = $release.tag_name

    Write-Host ""
    Write-Host "=== $tag ===" -ForegroundColor Yellow

    $folder = Join-Path $Backup $tag
    New-Item -ItemType Directory -Force -Path $folder | Out-Null

    foreach ($asset in $release.assets) {

        $url  = $asset.browser_download_url
        $name = $asset.name
        $size = [long]$asset.size

        $destination = Join-Path $folder $name

        # Skip files already downloaded completely
        if (Test-Path $destination) {

            $localSize = (Get-Item $destination).Length

            if ($localSize -eq $size) {
                Write-Host "SKIP: $name (already complete)" -ForegroundColor DarkGray
                continue
            }
        }

        $sizeMB = [Math]::Round($size / 1MB, 2)

        Write-Host ""
        Write-Host "Downloading: $name ($sizeMB MB)" -ForegroundColor Green

        & aria2c `
            --continue=true `
            --max-connection-per-server=8 `
            --split=8 `
            --min-split-size=1M `
            --file-allocation=none `
            --auto-file-renaming=false `
            --allow-overwrite=true `
            --summary-interval=5 `
            --dir="$folder" `
            --out="$name" `
            "$url"

        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Download failed: $name"
        }
    }
}

Write-Host ""
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host "Release backup completed." -ForegroundColor Green
Write-Host "Location: $Backup" -ForegroundColor Cyan
Write-Host "==============================" -ForegroundColor Cyan