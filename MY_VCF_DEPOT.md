# My-VcfDepot.ps1 — read the FULL catalog directly with the token

`My-VcfDepot.ps1` is a tiny, dependency-free alternative to the official
`vcf-download-tool` for **listing and downloading** VCF binaries. It talks to the
Broadcom depot over plain HTTPS using only your download token — no Java, no tool
install.

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
the catalog. Re-runs skip files whose checksum already matches (`ALREADY_OK`).

## Usage

```powershell
# token goes in a file (never commit it)
'<TOKEN>' | Set-Content .\token.txt

# list everything the token can see
.\My-VcfDepot.ps1 -TokenFile .\token.txt

# per-component size summary
.\My-VcfDepot.ps1 -TokenFile .\token.txt -Summary

# inspect a single component (files + checksums + URLs)
.\My-VcfDepot.ps1 -TokenFile .\token.txt -Component VSP

# download a component the official old tool couldn't even list, with sha256 verify
.\My-VcfDepot.ps1 -TokenFile .\token.txt -Component VCFMS_METRICS_STORE -Download -OutDir .\vcf9-depot
```

Output layout matches a real offline depot (`PROD/COMP/<component>/...`), so it can
be merged into a depot store served by `create_vcf9_depot_server_*.sh`.

## Notes / caveats

- Requires **PowerShell 7** and outbound HTTPS to `dl.broadcom.com`.
- Listing shows **all historical versions** in the catalog. There is no
  latest-only filter yet — filter by `Version` if you only want the newest.
- This reads the catalog directly; it does **not** replace `binaries upload`
  into an SDDC Manager (see `VCF_DOWNLOAD_TOOL.md` §5b for that).
- Do **not** hand-edit `productVersionCatalog.json` on a depot — it is
  Broadcom-signed (`.sig`) and editing it breaks VCF Installer validation.
