# My-VcfDepot.ps1 — read the FULL catalog directly with the token

`My-VcfDepot.ps1` is a tiny, dependency-free alternative to the official
`vcf-download-tool` for **listing, downloading, and building a complete offline
VCF depot**. It talks to the Broadcom depot over plain HTTPS using only your
download token — no Java, no tool install, no activation code.

## Why it exists — the tool caps what you can see

The official `vcf-download-tool binaries list` filters the catalog by
`--sku` / `--type` / `--automated-install`, and **older tool builds surface fewer
components**. Same token, same `--vcf-version 9.1.0.0 -t INSTALL`:

| Source | Components visible |
| --- | --- |
| `vcf-download-tool` **9.0.2** | **13** |
| `vcf-download-tool` **9.1** | **24** |
| **Raw catalog (this script)** | **~49** |

The extra components the filtered views hide include the VCF 9.1 fleet/services
pieces: `VSP`, `VCF_FLEET_LCM`, `VCF_SDDC_LCM`, `VCF_LICENSE_SERVER`, `VCF_SALT`,
`VCF_SALT_RAAS`, `VCF_OBSERVABILITY_DATA_PLATFORM`, `VCFMS_METRICS_STORE`,
`DEPOT_SERVICE`, `TELEMETRY_ACCEPTOR`, `VCF_SERVICE_*`, plus all the
`SUPERVISOR_SERVICE_*`, `VKR`, `VKS_*`, `VLR`, `DSM`, ...

> **The limit is the tool version, not the token.** A depot token grants raw
> access to the full, Broadcom-signed `productVersionCatalog.json`, which lists
> every component with each file's `fileName` / `size` / `checksum`.

## How it works

The token is embedded directly in the dl.broadcom.com URL path:

```
https://dl.broadcom.com/<TOKEN>/PROD/metadata/productVersionCatalog/v1/productVersionCatalog.json
https://dl.broadcom.com/<TOKEN>/PROD/COMP/<COMPONENT>/<fileName>
```

The catalog JSON is shaped:

```
{ version, sequenceNumber, publishedTime,
  patches: [ { <COMPONENT>: [ { productVersion,
                                artifacts: { bundles: [ { type,           # INSTALL | PATCH | UPGRADE
                                                          binaries: [ { fileName, size, checksum } ] } ] } } ] } ] }
```

The script flattens that to one row per binary and either prints it or downloads
each file to `OutDir/PROD/COMP/<component>/<fileName>`, verifying SHA-256 against
the catalog. Re-runs skip files whose checksum already matches (`ALREADY_OK`),
and partial files resume instead of restarting.

## Build a complete, ready-to-serve depot

`-BuildDepot` lays down everything a depot needs to serve a **bring-up**, using
only the token + public endpoints (no activation code):

```powershell
.\My-VcfDepot.ps1 -TokenFile .\token.txt -BuildDepot -OutDir /depot
```

That produces a depot store byte-compatible with what the official tool writes:

| Depot file | Source | Auth |
| --- | --- | --- |
| `PROD/COMP/<component>/<fileName>` | `dl.broadcom.com/<TOKEN>` | token |
| `PROD/metadata/productVersionCatalog/v1/*.json` + `.sig` | `dl.broadcom.com/<TOKEN>` | token |
| `PROD/metadata/manifest/v1/vcfManifest.json` | `dl.broadcom.com/<TOKEN>` | token |
| `PROD/metadata/vsan/hcl/all.json` | `partnerweb.vmware.com/service/vsan/all.json` | **public** |
| `PROD/metadata/vsan/hcl/lastupdatedtime.json` | generated from `all.json` | — |

`-BuildDepot` downloads the **management/bring-up component set** (an internal
whitelist) so you don't accidentally pull all ~2.8 TB. Add extra components
afterward with `-Component ... -Download` against the same `-OutDir`.

### What it does NOT fetch (on purpose)

`PROD/metadata/Compatibility/v1|v2/VmwareCompatibilityData.json` — the
interop/upgrade matrix — comes from `vvs.broadcom.com`, which requires a Broadcom
OAuth handshake (`eapi.broadcom.com/vcf/generateToken`, clientId `vcf-tools`) and
therefore an **activation code**. It is **day-2 lifecycle/upgrade** data and does
**not** gate bring-up, so this script skips it. If you need it: run one pass of
the official tool, or copy the two files from an existing depot.

## Usage

```powershell
# token goes in a file (never commit it)
'<TOKEN>' | Set-Content .\token.txt

# list everything the token can see / per-component size summary
.\My-VcfDepot.ps1 -TokenFile .\token.txt
.\My-VcfDepot.ps1 -TokenFile .\token.txt -Summary

# only INSTALL bundles (skip PATCH duplicates)
.\My-VcfDepot.ps1 -TokenFile .\token.txt -Type INSTALL -Summary

# one or more components (interactive/-Command passes a real array;
# note: `pwsh -File` turns a comma list into ONE string — pass a single -Component there)
.\My-VcfDepot.ps1 -TokenFile .\token.txt -Component VSP,VKR

# narrow within a component by fileName (e.g. one Kubernetes release)
.\My-VcfDepot.ps1 -TokenFile .\token.txt -Component VKR -FileNameLike '*1.33*' -Summary

# build a full bring-up depot (mgmt set + metadata), no activation code
.\My-VcfDepot.ps1 -TokenFile .\token.txt -BuildDepot -OutDir /depot

# add just what you want to an existing depot, resume-safe + sha256-verified
.\My-VcfDepot.ps1 -TokenFile .\token.txt -Component VKR -Type INSTALL -FileNameLike '*1.33*' -Download -OutDir /depot
```

### Parameters

| Param | Meaning |
| --- | --- |
| `-TokenFile` | file containing ONLY the download token (required) |
| `-Component` | filter to one/more catalog keys; omit for all |
| `-Type` | filter bundle type (`INSTALL` / `PATCH` / ...); omit for all |
| `-FileNameLike` | wildcard filter on `fileName` (e.g. `*1.33*`) |
| `-Summary` | per-component file count + size only |
| `-Download` | download the filtered binaries (sha256-verified, resume-safe, idempotent) |
| `-Metadata` | lay down catalog + manifest + vSAN HCL metadata |
| `-LatestOnly` | keep only the newest `productVersion` per component (skip older patch levels) |
| `-BuildDepot` | one-shot: `-Metadata` + `-Download` of the mgmt/bring-up component set |
| `-OutDir` | depot-store root (default `.\vcf9-depot`) |
| `-NoResume` | disable HTTP resume of partial downloads (resume is on by default) |

Output layout matches a real offline depot (`PROD/COMP/...`, `PROD/metadata/...`),
so it can be served directly by `create_vcf9_depot_server_*.sh` or merged into an
existing depot store.

## Linux-native (bash): `my-vcfdepot.sh`

Same tool without PowerShell — a `curl` + `jq` port for depot servers where you'd
rather not install pwsh. Identical behaviour and output layout; long-option flags:

```bash
./my-vcfdepot.sh -t token.txt --type INSTALL --summary
./my-vcfdepot.sh -t token.txt --component VKR --filename-like '*1.33*' --summary
./my-vcfdepot.sh -t token.txt --build-depot --latest-only -o /opt/vcf-depot/vcf9
./my-vcfdepot.sh -t token.txt --component VSP,NSX_T_MANAGER --type INSTALL --latest-only --download -o /depot
```

Flag map: `--component --type --filename-like --latest-only --summary --download
--metadata --build-depot --out-dir --no-resume`. Requires `bash curl jq sha256sum awk`
(`apt-get install -y jq` if missing). Resume via `curl -C -`, sha256-verified,
idempotent — same as the PowerShell version.

## Notes / caveats

- Requires **PowerShell 7** and outbound HTTPS to `dl.broadcom.com` (+
  `partnerweb.vmware.com` for the vSAN HCL). Cross-platform: Windows / Linux / macOS.
- Verified end-to-end on Windows: list / summary / metadata / download / checksum
  / idempotent re-run all pass — so a customer can run it locally and download.
- Listing shows **all historical versions** in the catalog. Filter by `Version`
  (or `-FileNameLike`) if you only want the newest.
- Full catalog is ~2.8 TB; `INSTALL`-only is ~1.35 TB. Filter before `-Download`.
- This reads the catalog directly; it does **not** replace `binaries upload`
  into an SDDC Manager (see `VCF_DOWNLOAD_TOOL.md` §5b for that).
- Do **not** hand-edit `productVersionCatalog.json` on a depot — it is
  Broadcom-signed (`.sig`) and editing it breaks VCF Installer validation.
