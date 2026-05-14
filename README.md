# vcf9offlinescript

Scripts for standing up an **offline VCF Software Depot** for VMware Cloud Foundation 9.x.

## Scripts

| Script | Purpose |
| --- | --- |
| `create_vcf9_depot_server.sh` | Original VCF 9.0.x depot server — HTTPS + basic auth (nginx, self-signed cert). |
| `create_vcf9_depot_server_v2.sh` | VCF 9.0.x depot server — HTTPS **and** HTTP, basic auth, self-signed cert. |
| `create_vcf9_depot_server_v3.sh` | **VCF 9.1** depot server — HTTP with **no basic auth** (the new 9.1 capability), plus VCF Installer API helper scripts. |
| `import_vcf9depot_ca.sh` | Import the depot CA/cert into the system and Java truststores. |
| `fix_sshd_config.sh` | Fix common sshd_config issues. |
| `sftpv1.sh` / `test_sftp.sh` | SFTP setup and connectivity test helpers. |

## VCF 9.1 — HTTP offline depot (v3)

VCF 9.1 adds native support for an offline Software Depot served over **plain HTTP with no basic authentication**.

Supported offline depot scenarios:

| Protocol | Basic Auth | 9.0.x | 9.1.0 | Behavior |
| --- | --- | --- | --- | --- |
| HTTPS | yes | ✅ | ✅ | Default |
| HTTPS | no | ❌ | ❌ | Not supported |
| HTTP | yes | ✅ | ✅ | Requires previous workaround |
| HTTP | no | ❌ | ✅ | **Supported via API** (v3) |

> The VCF 9.1 Installer **UI does not** support an HTTP offline depot. The VCF
> Installer **API must be used**. Once applied, the configuration is
> automatically transferred to the deployed VCF Fleet Depot Service.

### Usage

```bash
# Minimal VCF 9.1 HTTP offline depot (no auth, port 8888)
sudo bash create_vcf9_depot_server_v3.sh --fqdn depot.home.lab --ip 10.0.0.60

# Build the depot AND point the VCF Installer at it via the API
sudo bash create_vcf9_depot_server_v3.sh \
  --fqdn depot.home.lab --ip 10.0.0.60 \
  --vcf-installer-fqdn sddcm01.vcf.lab \
  --vcf-installer-password 'VMware1!VMware1!' \
  --configure-installer
```

`create_vcf9_depot_server_v3.sh` also generates, under `/opt/vcf-depot`:

- `configure-vcf-installer-depot.sh` — bash/curl helper to apply the depot config via the API
- `configure-vcf-installer-depot.ps1` — equivalent PowerShell helper
- `download-vcf9-binaries.sh` — wrapper around `vcf-download-tool`

`--enable-https` and `--enable-auth` are still available if you need the
9.0-style HTTPS + basic-auth behaviour.

## Reference

- [VCF 9.1 — New HTTP Offline Depot Support for VCF Installer & Fleet Depot Service](https://williamlam.com/2026/05/vcf-9-1-new-http-offline-depot-support-for-vcf-installer-fleet-depot-service.html)
