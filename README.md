# vcf9offlinescript

Scripts for standing up an **offline VCF Software Depot** for VMware Cloud Foundation 9.x.

## Scripts

| Script | Web Server | VCF | Protocol | Auth | Notes |
| --- | --- | --- | --- | --- | --- |
| `create_vcf9_depot_server.sh` | nginx | 9.0.x | HTTPS | Basic | Original |
| `create_vcf9_depot_server_v2.sh` | nginx | 9.0.x | HTTPS + HTTP | Basic | Adds HTTP redirect |
| `create_vcf9_depot_server_v3.sh` | nginx | 9.1 | HTTP | **None** | VCF 9.1 new no-auth mode via API |
| `create_vcf9_depot_server_v4_nginx.sh` | **nginx** | **9.1** | HTTPS + HTTP | Basic | 9.1 + activation-code download |
| `create_vcf9_depot_server_v4_apache.sh` | **Apache2** | **9.1** | HTTPS | Basic | Based on vstellar.com Part 4 |
| `import_vcf9depot_ca.sh` | — | — | — | — | Import depot cert into system + Java truststores |
| `fix_sshd_config.sh` | — | — | — | — | Fix duplicate sshd_config entries |
| `sftpv1.sh` / `test_sftp.sh` | — | — | — | — | SFTP setup and connectivity test |

## Choosing a script

```
Need VCF 9.1 HTTPS + basic auth?
  ├─ Prefer nginx   → create_vcf9_depot_server_v4_nginx.sh
  └─ Prefer Apache2 → create_vcf9_depot_server_v4_apache.sh   ← follows vstellar.com Part 4

Need VCF 9.1 HTTP with NO auth (new 9.1 feature)?
  └─ create_vcf9_depot_server_v3.sh   (must configure via VCF Installer API, not UI)

Need VCF 9.0.x?
  ├─ HTTPS only       → create_vcf9_depot_server.sh
  └─ HTTPS + HTTP     → create_vcf9_depot_server_v2.sh
```

## VCF 9.1 — HTTPS + basic auth (v4)

Two equivalent scripts — same flags, same behaviour, different web server.

### nginx version

```bash
# Minimal
sudo bash create_vcf9_depot_server_v4_nginx.sh \
  --fqdn vcf91-depot.lab --ip 10.0.0.80

# Full: download binaries + import cert
sudo bash create_vcf9_depot_server_v4_nginx.sh \
  --fqdn vcf91-depot.lab --ip 10.0.0.80 \
  --activation-code /root/activation-code.txt \
  --download-tool-tgz /root/vcf-download-tool-9.1.0.0.tar.gz \
  --download-binaries \
  --import-ca
```

### Apache2 version (vstellar.com Part 4)

```bash
# Minimal
sudo bash create_vcf9_depot_server_v4_apache.sh \
  --fqdn vcf91-repo.cmb1.lab --ip 10.0.0.80

# Full: download binaries + import cert, custom cert subject
sudo bash create_vcf9_depot_server_v4_apache.sh \
  --fqdn vcf91-repo.cmb1.lab --ip 10.0.0.80 \
  --org "Thinkon" --ou "Cloud-Services" \
  --activation-code /root/activation-code.txt \
  --download-tool-tgz /root/vcf-download-tool-9.1.0.0.tar.gz \
  --download-binaries \
  --import-ca
```

### Common flags (both v4 scripts)

| Flag | Default | Description |
| --- | --- | --- |
| `--fqdn` | *(required)* | FQDN of the depot server |
| `--ip` | *(required)* | Server IP (used in cert SAN) |
| `--vcf-version` | `9.1.0.0` | VCF version to download |
| `--user` | `vcfadmin` | Basic auth username |
| `--password` | `VMware1!VMware1!` | Basic auth password |
| `--port` | `443` | HTTPS port |
| `--activation-code` | — | `activation-code.txt` from Broadcom (VCF 9.1) |
| `--token-file` | — | Download token file (VCF 9.0 legacy) |
| `--download-tool-tgz` | — | Path to `vcf-download-tool-*.tar.gz` |
| `--download-binaries` | — | Run download after setup |
| `--download-type` | `INSTALL` | `INSTALL` / `UPGRADE` / `ALL` |
| `--import-ca` | — | Auto-import cert into system + Java truststores |
| `--ca-url` | — | Fetch CA from URL (instead of local cert file) |

### What each v4 script generates under `/opt/vcf-depot`

- `download-vcf9-binaries.sh` — re-runnable download wrapper (supports both activation-code and token-file)

Both scripts call `import_vcf9depot_ca.sh` (must be in the same directory) when `--import-ca` is set.

---

## VCF 9.1 — HTTP offline depot (v3, no-auth)

VCF 9.1 adds native support for an offline depot over **plain HTTP with no basic authentication**.

| Protocol | Basic Auth | 9.0.x | 9.1.0 | Behavior |
| --- | --- | --- | --- | --- |
| HTTPS | yes | ✅ | ✅ | Default |
| HTTPS | no | ❌ | ❌ | Not supported |
| HTTP | yes | ✅ | ✅ | Legacy workaround |
| HTTP | no | ❌ | ✅ | **New in 9.1 — API only** (v3) |

> The VCF 9.1 Installer **UI does not** support HTTP offline depots.
> Use the VCF Installer **API**. Configuration is automatically propagated to the Fleet Depot Service.

```bash
# HTTP no-auth (port 8888 default)
sudo bash create_vcf9_depot_server_v3.sh --fqdn depot.home.lab --ip 10.0.0.60

# Apply via VCF Installer API
sudo bash create_vcf9_depot_server_v3.sh \
  --fqdn depot.home.lab --ip 10.0.0.60 \
  --vcf-installer-fqdn sddcm01.vcf.lab \
  --vcf-installer-password 'VMware1!VMware1!' \
  --configure-installer
```

`create_vcf9_depot_server_v3.sh` also generates:
- `configure-vcf-installer-depot.sh` — bash/curl helper to apply depot config via API
- `configure-vcf-installer-depot.ps1` — PowerShell equivalent
- `download-vcf9-binaries.sh` — vcf-download-tool wrapper

---

## CA import (`import_vcf9depot_ca.sh`)

Run on any machine that needs to trust the depot certificate (SDDC Manager, VCF Installer, etc.):

```bash
# Import from a local cert file
sudo bash import_vcf9depot_ca.sh --cert /path/to/vcf9-depot.crt

# Fetch cert directly from the depot server (useful when running on SDDC Manager)
sudo bash import_vcf9depot_ca.sh --url-insecure https://vcf91-depot.lab:443
```

> **"Invalid credentials" when adding depot in VCF Installer?**
> This error is misleading — it almost always means the depot certificate has
> **not** been imported into the Java truststore. Import the cert and retry.

---

## References

- [vstellar.com — VCF 9.1 Home Lab Series Part 4: VCF Offline Depot](https://vstellar.com/2026/05/vcf-9-1-home-lab-series-part-4-vcf-offline-depo/)
- [williamlam.com — VCF 9.1 New HTTP Offline Depot Support](https://williamlam.com/2026/05/vcf-9-1-new-http-offline-depot-support-for-vcf-installer-fleet-depot-service.html)
