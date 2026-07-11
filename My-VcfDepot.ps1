<#
  My-VcfDepot.ps1 (v3) - roll-your-own COMPLETE offline VCF depot builder.

  WHY: the official vcf-download-tool caps its `binaries list` by SKU / tool
  version (a 9.0.2 build lists ~13 components, a 9.1 build ~24), and needs an
  activation code for the compatibility/interop metadata. But the depot download
  TOKEN grants raw HTTP access to the FULL product-version catalog (~49
  components) plus the catalog/manifest metadata, and the vSAN HCL is a public
  endpoint. So everything a depot needs to serve a BRING-UP can be built with
  the token alone - no activation code, no tool-version cap.

  WHAT THIS BUILDS (all reachable with token + public endpoints, no activation code):
    <OutDir>/PROD/COMP/<Component>/<fileName>                       binaries  (dl.broadcom.com/<tok>)
    <OutDir>/PROD/metadata/productVersionCatalog/v1/*.json|.sig     master catalog (dl.broadcom.com/<tok>)
    <OutDir>/PROD/metadata/manifest/v1/vcfManifest.json             VCF manifest   (dl.broadcom.com/<tok>)
    <OutDir>/PROD/metadata/vsan/hcl/all.json                        vSAN HCL  (partnerweb.vmware.com, PUBLIC)
    <OutDir>/PROD/metadata/vsan/hcl/lastupdatedtime.json            GENERATED from all.json (2 fields)

  WHAT THIS DOES NOT BUILD (needs Broadcom vvs OAuth / activation code - skipped on purpose):
    <OutDir>/PROD/metadata/Compatibility/v1|v2/VmwareCompatibilityData.json
      source: vvs.broadcom.com/v1/products/bundles/type/{vcf-lcm-v2-bundle,vcf-interop-bundle}
      auth  : eapi.broadcom.com/vcf/generateToken (clientId=vcf-tools) -> Bearer -> vvs
      This is the interop/upgrade matrix, used for DAY-2 lifecycle/upgrade
      planning - it does NOT gate bring-up. If you need it: run one pass of the
      official tool, or copy the two files from an existing depot.

  AUTH: token is embedded in the dl.broadcom.com URL path. Keep it in a file, pass -TokenFile.

  USAGE:
    .\My-VcfDepot.ps1 -TokenFile .\token.txt -Summary                       # list catalog (all 49)
    .\My-VcfDepot.ps1 -TokenFile .\token.txt -Type INSTALL -Summary         # INSTALL bundles only
    .\My-VcfDepot.ps1 -TokenFile .\token.txt -Component VKR -FileNameLike '*1.33*' -Summary   # pick TKr versions
    .\My-VcfDepot.ps1 -TokenFile .\token.txt -BuildDepot -OutDir /depot      # FULL depot: bring-up mgmt set + metadata
    .\My-VcfDepot.ps1 -TokenFile .\token.txt -Component VKR -Type INSTALL -FileNameLike '*1.33*' -Download -OutDir /depot
                                                                            # add just what you want to an existing depot
  Cross-platform: PowerShell 7 on Windows / Linux / macOS.
#>
param(
  [Parameter(Mandatory)][string]$TokenFile,   # file containing ONLY the depot download token
  [string[]]$Component,                        # filter to one/more components (catalog keys); omit for all
  [string]$Type,                               # filter bundle type (e.g. INSTALL, PATCH); omit for all
  [string]$FileNameLike,                       # wildcard filter on fileName (e.g. '*1.33*'); omit for all
  [switch]$Download,                           # download the (filtered) binaries
  [switch]$Metadata,                           # lay down catalog + manifest + vSAN HCL metadata
  [switch]$BuildDepot,                         # one-shot: -Metadata + -Download of the mgmt/bring-up component set
  [string]$OutDir = '.\vcf9-depot',            # depot-store root
  [switch]$Summary,                            # print only the per-component summary
  [switch]$NoResume                            # disable HTTP resume of partial downloads (resume on by default)
)
$ErrorActionPreference = 'Stop'
$token = (Get-Content $TokenFile -Raw).Trim()
$base  = "https://dl.broadcom.com/$token/PROD"

# component set the official tool pulls for a bring-up depot (mgmt plane). -BuildDepot uses this
# when no explicit -Component is given, so you don't accidentally grab all 2.8 TB (VKR/HCX/VRNI...).
$MgmtSet = @(
  'DEPOT_SERVICE','ESX_HOST','NSX_ALB','NSX_T_MANAGER','SDDC_MANAGER_VCF','TELEMETRY_ACCEPTOR',
  'VCENTER','VCFDT','VCF_FLEET_LCM','VCF_LICENSE_SERVER','VCFMS_METRICS_STORE',
  'VCF_OBSERVABILITY_DATA_PLATFORM','VCF_OPS_CLOUD_PROXY','VCF_SALT','VCF_SALT_RAAS','VCF_SDDC_LCM',
  'VIDB','VSP','VSAN_FILE_SERVICES'
)

if ($BuildDepot) { $Metadata = $true; $Download = $true; if (-not $Component) { $Component = $MgmtSet } }

Write-Host "Fetching product version catalog..." -ForegroundColor Cyan
$cat  = Invoke-RestMethod -Uri "$base/metadata/productVersionCatalog/v1/productVersionCatalog.json" -TimeoutSec 60
$root = if ($cat -is [array]) { $cat[0] } else { $cat }
$patch = $root.patches[0]

# flatten catalog -> one row per binary (honour -Component / -Type / -FileNameLike filters)
$rows = foreach ($comp in $patch.PSObject.Properties.Name) {
  if ($Component -and $comp -notin $Component) { continue }
  foreach ($ver in $patch.$comp) {
    foreach ($b in $ver.artifacts.bundles) {
      if ($Type -and $b.type -ne $Type) { continue }
      foreach ($bin in $b.binaries) {
        if ($FileNameLike -and $bin.fileName -notlike $FileNameLike) { continue }
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
  Write-Host ("`nComponents: {0}   Files: {1}   Total: {2} GB{3}" -f `
    ($rows.Component | Sort-Object -Unique).Count, $rows.Count,
    [math]::Round(($rows | Measure-Object SizeGB -Sum).Sum,1),
    $(if($Type){"   (Type=$Type)"}else{''})) -ForegroundColor Green
  return
}

if (-not $Download -and -not $Metadata) {
  $rows | Select-Object Component,Version,Type,SizeGB,FileName | Format-Table -Auto
  Write-Host ("`nComponents: {0}   Files: {1}   Total: {2} GB   (token-visible, tool-independent)" -f `
    ($rows.Component | Sort-Object -Unique).Count, $rows.Count,
    [math]::Round(($rows | Measure-Object SizeGB -Sum).Sum,1)) -ForegroundColor Green
  return
}

# ---- helper: robust file fetch (resume + fallback) ----
function Get-File([string]$Url,[string]$Dest,[bool]$AllowResume=$true){
  New-Item -ItemType Directory -Path (Split-Path $Dest -Parent) -Force | Out-Null
  $p = @{ Uri = $Url; OutFile = $Dest; TimeoutSec = 0 }
  if ($AllowResume -and (Test-Path $Dest -PathType Leaf)) { $p.Resume = $true }
  try { Invoke-WebRequest @p }
  catch {
    Write-Host "  resume failed ($($_.Exception.Message)); retrying full" -ForegroundColor Yellow
    Remove-Item $Dest -Force -ErrorAction SilentlyContinue
    Invoke-WebRequest -Uri $Url -OutFile $Dest -TimeoutSec 0
  }
}

# ---- metadata: catalog + manifest + vSAN HCL (token + public, no activation code) ----
if ($Metadata) {
  foreach ($m in @(
      'metadata/productVersionCatalog/v1/productVersionCatalog.json',
      'metadata/productVersionCatalog/v1/productVersionCatalog.sig',
      'metadata/manifest/v1/vcfManifest.json')) {
    Write-Host "METADATA    $m" -ForegroundColor Cyan
    Get-File "$base/$m" (Join-Path $OutDir "PROD/$m") $false      # small files - clean fetch
    Write-Host "  OK" -ForegroundColor Green
  }
  # vSAN HCL - PUBLIC endpoint (no token), then generate lastupdatedtime.json from it
  $hclDir = Join-Path $OutDir 'PROD/metadata/vsan/hcl'
  $hclAll = Join-Path $hclDir 'all.json'
  Write-Host "METADATA    vsan/hcl/all.json  (partnerweb, public)" -ForegroundColor Cyan
  Get-File 'https://partnerweb.vmware.com/service/vsan/all.json' $hclAll $false
  try {
    $hcl = Get-Content $hclAll -Raw | ConvertFrom-Json
    ([ordered]@{ timestamp = $hcl.timestamp; jsonUpdatedTime = $hcl.jsonUpdatedTime } |
      ConvertTo-Json -Compress) | Set-Content (Join-Path $hclDir 'lastupdatedtime.json') -NoNewline
    Write-Host "  OK  (+ generated lastupdatedtime.json)" -ForegroundColor Green
  } catch { Write-Host "  !! could not generate lastupdatedtime.json: $($_.Exception.Message)" -ForegroundColor Red }
}

# ---- binaries: download + sha256 verify (resume-safe, idempotent) ----
if ($Download) {
  foreach ($r in $rows) {
    $dest = Join-Path $OutDir "PROD/COMP/$($r.Component)/$($r.FileName)"
    if (Test-Path $dest -PathType Leaf) {
      $existing = (Get-FileHash $dest -Algorithm SHA256).Hash.ToLower()
      if ($existing -eq $r.Checksum) { Write-Host "ALREADY_OK  $($r.FileName)" -ForegroundColor DarkGray; continue }
    }
    Write-Host "DOWNLOAD    $($r.FileName)  ($($r.SizeGB) GB)" -ForegroundColor Cyan
    Get-File $r.Url $dest (-not $NoResume)
    $got = (Get-FileHash $dest -Algorithm SHA256).Hash.ToLower()
    if ($got -eq $r.Checksum) { Write-Host "  OK  sha256 matches catalog" -ForegroundColor Green }
    else {
      Write-Host "  !! CHECKSUM MISMATCH - redownloading full" -ForegroundColor Red
      Remove-Item $dest -Force -ErrorAction SilentlyContinue
      Get-File $r.Url $dest $false
      $got2 = (Get-FileHash $dest -Algorithm SHA256).Hash.ToLower()
      if ($got2 -eq $r.Checksum) { Write-Host "  OK  sha256 matches (after refetch)" -ForegroundColor Green }
      else { Write-Host "  !! STILL MISMATCH - left for inspection" -ForegroundColor Red }
    }
  }
}

Write-Host "`nDone. Depot root: $OutDir" -ForegroundColor Green
if ($Metadata) {
  Write-Host "Note: Compatibility/ (interop matrix, vvs.broadcom.com) was NOT fetched - needs activation code." -ForegroundColor DarkYellow
  Write-Host "      It is day-2 only and does not gate bring-up. Copy from an existing depot if needed." -ForegroundColor DarkYellow
}
