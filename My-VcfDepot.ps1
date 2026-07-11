<#
  My-VcfDepot.ps1 - a minimal "roll-your-own" VCF depot lister / downloader.

  WHY: the official vcf-download-tool filters the product catalog by SKU / type,
  so its `binaries list` only surfaces a subset of components - and OLDER tool
  builds surface even fewer (a 9.0.2 build lists ~13 components, a 9.1 build
  lists ~24). But the depot download token grants raw HTTP access to the FULL
  Broadcom product-version catalog, which enumerates ALL ~49 components
  (VSP, SUPERVISOR_SERVICE_*, VKR, VLR, DSM, VCF_SALT, VCF_LICENSE_SERVER, ...).
  The cap is the TOOL VERSION, not the token. This script reads that catalog
  directly, so it lists / downloads everything regardless of tool version.

  AUTH MODEL: the token is embedded in the dl.broadcom.com URL path -
      https://dl.broadcom.com/<TOKEN>/PROD/metadata/productVersionCatalog/v1/productVersionCatalog.json
      https://dl.broadcom.com/<TOKEN>/PROD/COMP/<COMPONENT>/<fileName>

  The token itself is NOT stored here - put it in a file and pass -TokenFile.

  USAGE:
    .\My-VcfDepot.ps1 -TokenFile .\token.txt                       # list ALL components/files
    .\My-VcfDepot.ps1 -TokenFile .\token.txt -Summary              # per-component file count + size
    .\My-VcfDepot.ps1 -TokenFile .\token.txt -Component VSP        # one component's files (+checksum)
    .\My-VcfDepot.ps1 -TokenFile .\token.txt -Component VSP -Download -OutDir .\vcf9-depot
                                                                   # download + verify sha256 (idempotent)
  Cross-platform: works in PowerShell 7 on Windows/Linux/macOS.
#>
param(
  [Parameter(Mandatory)][string]$TokenFile,   # path to a file containing ONLY the depot download token
  [string]$Component,                          # filter to one component (catalog key); omit for all
  [switch]$Download,                           # actually download the files (default: list only)
  [string]$OutDir = '.\vcf9-depot',            # depot-store root for downloads (PROD/COMP/... is created under it)
  [switch]$Summary                             # print only the per-component summary
)
$ErrorActionPreference = 'Stop'
$token = (Get-Content $TokenFile -Raw).Trim()
$base  = "https://dl.broadcom.com/$token/PROD"

Write-Host "Fetching product version catalog..." -ForegroundColor Cyan
$cat  = Invoke-RestMethod -Uri "$base/metadata/productVersionCatalog/v1/productVersionCatalog.json" -TimeoutSec 60
$root = if ($cat -is [array]) { $cat[0] } else { $cat }
$patch = $root.patches[0]

# flatten catalog -> one row per binary
$rows = foreach ($comp in $patch.PSObject.Properties.Name) {
  if ($Component -and $comp -ne $Component) { continue }
  foreach ($ver in $patch.$comp) {
    foreach ($b in $ver.artifacts.bundles) {
      foreach ($bin in $b.binaries) {
        [pscustomobject]@{
          Component = $comp
          Version   = $ver.productVersion
          Type      = $b.type
          FileName  = $bin.fileName
          SizeGB    = [math]::Round($bin.size/1GB, 3)
          Checksum  = $bin.checksum
          Url       = "$base/COMP/$comp/$($bin.fileName)"
        }
      }
    }
  }
}

if ($Summary) {
  $rows | Group-Object Component | Sort-Object Name |
    Select-Object @{n='Component';e={$_.Name}},
                  @{n='Files';e={$_.Count}},
                  @{n='TotalGB';e={[math]::Round(($_.Group | Measure-Object SizeGB -Sum).Sum,2)}} |
    Format-Table -Auto
  Write-Host ("`nComponents: {0}   Files: {1}   Total: {2} GB" -f `
    ($rows.Component | Sort-Object -Unique).Count, $rows.Count,
    [math]::Round(($rows | Measure-Object SizeGB -Sum).Sum,1)) -ForegroundColor Green
  return
}

if (-not $Download) {
  $rows | Select-Object Component,Version,Type,SizeGB,FileName | Format-Table -Auto
  Write-Host ("`nComponents: {0}   Files: {1}   Total: {2} GB   (token-visible, tool-independent)" -f `
    ($rows.Component | Sort-Object -Unique).Count, $rows.Count,
    [math]::Round(($rows | Measure-Object SizeGB -Sum).Sum,1)) -ForegroundColor Green
  return
}

# ---- download mode ----
foreach ($r in $rows) {
  $destDir = Join-Path $OutDir "PROD/COMP/$($r.Component)"
  New-Item -ItemType Directory -Path $destDir -Force | Out-Null
  $dest = Join-Path $destDir $r.FileName
  if (Test-Path $dest -PathType Leaf) {
    $existing = (Get-FileHash $dest -Algorithm SHA256).Hash.ToLower()
    if ($existing -eq $r.Checksum) { Write-Host "ALREADY_OK  $($r.FileName)" -ForegroundColor DarkGray; continue }
  }
  Write-Host "DOWNLOAD    $($r.FileName)  ($($r.SizeGB) GB)" -ForegroundColor Cyan
  Invoke-WebRequest -Uri $r.Url -OutFile $dest -TimeoutSec 0
  $got = (Get-FileHash $dest -Algorithm SHA256).Hash.ToLower()
  if ($got -eq $r.Checksum) { Write-Host "  OK  sha256 matches catalog" -ForegroundColor Green }
  else { Write-Host "  !! CHECKSUM MISMATCH (got $got expect $($r.Checksum))" -ForegroundColor Red }
}
