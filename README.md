# vcf9offlinescript

Scripts for standing up an **offline VCF Software Depot** for VMware Cloud Foundation 9.x,
and importing the depot CA certificate into VCF Installer, SDDC Manager, and VCF OPS appliances.

> **Ways to build/deliver the depot** (pick per scenario):
> - **[DOWNLOAD-INTO-DEPOT.md](DOWNLOAD-INTO-DEPOT.md)** — official VCF Download Tool: activation code → `binaries download` straight into a `PROD/` depot.
> - **[CUSTOMER-DEPLOY-GUIDE.md](CUSTOMER-DEPLOY-GUIDE.md)** / **[UPLOAD-STEPS.md](UPLOAD-STEPS.md)** — ship a complete depot tar, stand it up (external server or on the installer).
> - **[DEPLOY_TARBALL_TO_V5_DEPOT.md](DEPLOY_TARBALL_TO_V5_DEPOT.md)** — simple 5-step: scp a depot tar.gz onto a v5 server and extract it into place.
> - **[OA-FLAT-SORT-DEPOT.md](OA-FLAT-SORT-DEPOT.md)** — customer dumps all downloads flat → `sort-flat-depot.sh` auto-arranges into `PROD/COMP/`.
> - **[METADATA-ZIP-DEPOT.md](METADATA-ZIP-DEPOT.md)** — official metadata zip + token-downloaded binaries (lightweight).
> - **[METADATA-ZIP-0400-RUNBOOK.md](METADATA-ZIP-0400-RUNBOOK.md)** — the self-made 0400 metadata zip + flat-sort flow, pinned to the real 9.1.0.0400 files.
> - **[MY_VCF_DEPOT.md](MY_VCF_DEPOT.md)** — `My-VcfDepot.ps1` token-only catalog reader / depot builder.

---

## Quick start — VCF 9.1 (recommended)

```bash
# 1. Set up the depot server (nginx, fresh Ubuntu VM with a second disk)
sudo bash create_vcf9_depot_server_v5.sh \
  --fqdn vcf91-depot.lab --ip 10.0.0.80 \
  --web-server nginx \
  --data-disk /dev/sdb \
  --activation-code /root/activation-code.txt \
  --download-tool-tgz /root/vcf-download-tool-9.1.0.0.tar.gz \
  --download-binaries \
  --import-ca

# 2. On the VCF Installer appliance — import the depot cert
sudo bash import_vcf9depot_ca.sh \
  --url-insecure https://vcf91-depot.lab \
  --vcf-installer

# 3. On SDDC Manager (after deployment)
sudo bash import_vcf9depot_ca.sh \
  --url-insecure https://vcf91-depot.lab \
  --sddc-manager

# 4. On VCF OPS appliance
sudo bash import_vcf9depot_ca.sh \
  --url-insecure https://vcf91-depot.lab \
  --vcf-ops
```

---

## All scripts

### Depot server scripts

| Script | Web server | VCF | Protocol | Auth | Notes |
| --- | --- | --- | --- | --- | --- |
| **`create_vcf9_depot_server_v5.sh`** | **nginx or apache** | **9.1** | **HTTPS** | **Basic** | **⭐ Recommended — unified (Ubuntu)** |
| `create_vcf9_depot_server_rhel.sh` | nginx | 9.1 | HTTPS | Basic | RHEL/Rocky/Alma variant — see [OFFLINE-OS-REPO.md](OFFLINE-OS-REPO.md) |

> v1–v4 (`create_vcf9_depot_server{.sh,_v2,_v3,_v4_nginx,_v4_apache}`) were consolidated into **v5** and removed.
> For the VCF 9.1 **HTTP no-auth** endpoint (`:8888`), see the nginx snippet in [OFFLINE-OS-REPO.md](OFFLINE-OS-REPO.md).

### CA import script

| Script | Version | Notes |
| --- | --- | --- |
| **`import_vcf9depot_ca.sh`** | **v2.0** | System trust store + Java cacerts. Supports VCF Installer, VCF OPS, SDDC Manager (Photon OS). |

### Post-setup maintenance scripts

| Script | Notes |
| --- | --- |
| **`change_depot_hostname_ip.sh`** | **Change hostname and/or IP after initial setup — regenerates cert automatically** |
| `fix_sshd_config.sh` | Fix duplicate sshd_config entries from sftpv1.sh |
| `sftpv1.sh` / `test_sftp.sh` | SFTP setup and connectivity test |

---

## v5 — Unified depot server (⭐ recommended)

`create_vcf9_depot_server_v5.sh` replaces the separate v4_nginx / v4_apache scripts.
Choose the web server with `--web-server nginx` (default) or `--web-server apache`.

### What v5 handles on a fresh Ubuntu VM

| Problem | v4 | v5 |
| --- | --- | --- |
| Firewall (Ubuntu uses ufw, not firewalld) | ❌ silently skipped | ✅ auto-detects ufw / firewalld |
| Second data disk for depot files | ❌ not handled | ✅ `--data-disk /dev/sdb` |
| keytool / JRE not installed | ❌ silently skipped | ✅ installs `default-jre-headless` with `--import-ca` |
| Apache 403 on `/PROD/` (outside DocumentRoot) | ❌ symlink broke | ✅ `Alias + <Directory>` |
| RHEL httpd path | apache only | ✅ `/etc/httpd/conf.d/vcf9-depot-ssl.conf` |

### v5 flags

| Flag | Default | Description |
| --- | --- | --- |
| `--fqdn` | *(required)* | FQDN of the depot server |
| `--ip` | *(required)* | Server IP (used in cert SAN) |
| `--web-server` | `nginx` | `nginx` or `apache` |
| `--vcf-version` | `9.1.0.0` | VCF version string |
| `--port` | `443` | HTTPS port |
| `--http-port` | `80` | HTTP redirect port (nginx only) |
| `--user` | `vcfdepot` | Basic auth username |
| `--password` | `VMware1!VMware1!` | Basic auth password |
| `--data-disk` | — | Block device to format + mount as `/var/www/html` |
| `--skip-disk-setup` | — | Skip disk format/mount |
| `--activation-code` | — | `activation-code.txt` from Broadcom (VCF 9.1) |
| `--token-file` | — | Download token file (VCF 9.0 legacy, still works) |
| `--download-tool-tgz` | — | Path to `vcf-download-tool-*.tar.gz` |
| `--download-binaries` | — | Run download after setup |
| `--download-type` | `INSTALL` | `INSTALL` / `UPGRADE` / `ALL` |
| `--import-ca` | — | Import cert into system + Java truststores (installs JRE if needed) |
| `--ca-url` | — | Fetch CA from URL instead of local cert |
| `--existing-cert` | — | Use an existing PEM cert (skip generation) |
| `--existing-key` | — | Use an existing PEM key (skip generation) |
| `--skip-firewall` | — | Skip firewall config |

### v5 examples

```bash
# nginx, fresh Ubuntu + second disk + download binaries
sudo bash create_vcf9_depot_server_v5.sh \
  --fqdn vcf91-depot.lab --ip 10.0.0.80 \
  --web-server nginx \
  --data-disk /dev/sdb \
  --activation-code /root/activation-code.txt \
  --download-tool-tgz /root/vcf-download-tool-9.1.0.0.tar.gz \
  --download-binaries \
  --import-ca

# Apache2, custom cert subject (e.g. internal CA workflow)
sudo bash create_vcf9_depot_server_v5.sh \
  --fqdn vcf91-repo.cmb1.lab --ip 10.0.0.80 \
  --web-server apache \
  --org "Thinkon" --ou "Cloud-Services" \
  --data-disk /dev/sdb \
  --import-ca

# nginx, disk already mounted, no download yet
sudo bash create_vcf9_depot_server_v5.sh \
  --fqdn vcf91-depot.lab --ip 10.0.0.80 \
  --skip-disk-setup
```

---

## CA import — `import_vcf9depot_ca.sh` v2

Run as **root on the target machine** (VCF Installer, SDDC Manager, VCF OPS).
All three appliance types run **Photon OS** — v2 adds full Photon OS support.

### What v2 covers

| | v1 (old) | v2 (new) |
| --- | --- | --- |
| Ubuntu / RHEL system trust store | ✅ | ✅ |
| **Photon OS** system trust store | ❌ | ✅ `c_rehash` + `update-ca-trust` |
| Generic JVM (`/usr/lib/jvm`) | ✅ | ✅ |
| **VCF Installer** bundled JRE | ❌ | ✅ `--vcf-installer` |
| **VCF OPS** bundled JRE | ❌ | ✅ `--vcf-ops` |
| **SDDC Manager** bundled JRE | ❌ | ✅ `--sddc-manager` |
| Service restart after import | ❌ | ✅ (all component services) |

### v2 flags

| Flag | Description |
| --- | --- |
| `--cert PATH` | Local PEM certificate file |
| `--url URL` | Fetch cert via HTTPS (TLS verified) |
| `--url-insecure URL` | Fetch server cert via `openssl s_client` (no TLS verify) |
| `--vcf-installer` | Add VCF Installer JRE paths + restart `vcf-installer` |
| `--vcf-ops` | Add VCF OPS (Aria Ops) JRE paths + restart its services |
| `--sddc-manager` | Add SDDC Manager JRE paths + restart its services |
| `--all-components` | Short for all three above |
| `--no-restart` | Skip service restarts (useful for testing) |
| `--alias NAME` | keytool alias (default: `vcf9depot-ca`) |

### v2 examples

```bash
# VCF Installer appliance — fetch cert from depot, import + restart
sudo bash import_vcf9depot_ca.sh \
  --url-insecure https://vcf91-depot.lab \
  --vcf-installer

# SDDC Manager — use a cert file already copied over
sudo bash import_vcf9depot_ca.sh \
  --cert /tmp/vcf9-depot.crt \
  --sddc-manager

# VCF OPS appliance
sudo bash import_vcf9depot_ca.sh \
  --cert /tmp/vcf9-depot.crt \
  --vcf-ops

# All components at once, no restart (dry-run style)
sudo bash import_vcf9depot_ca.sh \
  --cert /tmp/vcf9-depot.crt \
  --all-components \
  --no-restart
```

> **"Invalid credentials" in VCF Installer when creds are correct?**
> This error is misleading — it means the depot certificate has **not** been imported
> into the Java truststore. Run `import_vcf9depot_ca.sh --vcf-installer` and retry.

---

## VCF 9.1 — HTTP no-auth depot (`:8888`)

VCF 9.1 supports an offline depot over plain HTTP with **no auth** (API-only; the Installer **UI**
does not support HTTP depots). Add a `:8888` nginx server block on the depot and point the installer
via API at `http://<IP>:8888` — snippet + steps in **[OFFLINE-OS-REPO.md](OFFLINE-OS-REPO.md)**.

---

## Changing hostname / IP after setup — `change_depot_hostname_ip.sh`

Run on the depot server itself when you need to rename or re-IP it after initial setup.

### What it does

| Step | Action |
| --- | --- |
| 1 | `hostnamectl set-hostname` + update `/etc/hosts` |
| 2 | Update static IP via **netplan** (Ubuntu) or **nmcli** (RHEL) |
| 3 | **Regenerate TLS certificate** with new CN + SAN (FQDN + IP) |
| 4 | Update `server_name` in nginx / apache2 / httpd config + reload |
| 5 | Print exact `import_vcf9depot_ca.sh` commands to re-import the new cert |

### Usage

```bash
# Change both hostname and IP
sudo bash change_depot_hostname_ip.sh \
  --fqdn vcf91-depot.lab \
  --ip 10.0.1.80 \
  --gw 10.0.1.1

# Change hostname only (keep IP)
sudo bash change_depot_hostname_ip.sh \
  --fqdn vcf91-depot.lab

# Change IP only (keep hostname)
sudo bash change_depot_hostname_ip.sh \
  --ip 10.0.1.80 --gw 10.0.1.1
```

### Flags

| Flag | Description |
| --- | --- |
| `--fqdn` | New FQDN (e.g. `vcf91-depot.lab`) |
| `--ip` | New static IP (e.g. `10.0.1.80`) |
| `--gw` | New gateway (keeps current if omitted) |
| `--prefix` | Subnet prefix, default `24` |
| `--country/--state/--city/--org/--ou` | Override cert subject fields |
| `--no-cert-regen` | Skip certificate regeneration (not recommended) |
| `--no-restart` | Skip web server reload |

### After running — re-import cert on VCF components

The TLS cert is regenerated with the new hostname/IP.
**Re-import on every machine that connects to the depot:**

```bash
# VCF Installer
sudo bash import_vcf9depot_ca.sh --url-insecure https://<NEW_FQDN> --vcf-installer

# SDDC Manager
sudo bash import_vcf9depot_ca.sh --url-insecure https://<NEW_FQDN> --sddc-manager

# VCF OPS
sudo bash import_vcf9depot_ca.sh --url-insecure https://<NEW_FQDN> --vcf-ops
```

Also update the Depot URL in **VCF Installer → Administration → Depot Settings**.

---

## Docs in this repo

**VCF Download Tool**
- [VCF-DOWNLOAD-TOOL.md](VCF-DOWNLOAD-TOOL.md) — the tool itself: install, activation code, commands, flags, gotchas (syntax verified vs `--help`)
- [DOWNLOAD-CMDS-ONELINE.md](DOWNLOAD-CMDS-ONELINE.md) — copy-paste one-line commands (placeholders)

**Build / deliver a depot**
- [DOWNLOAD-INTO-DEPOT.md](DOWNLOAD-INTO-DEPOT.md) — official `vcf-download-tool`: activation code → `binaries download` into a `PROD/` depot
- [CUSTOMER-DEPLOY-GUIDE.md](CUSTOMER-DEPLOY-GUIDE.md) — ship a complete depot tar, two deploy models (external server / on the installer)
- [UPLOAD-STEPS.md](UPLOAD-STEPS.md) — depot-side + installer-side upload steps (incl. 7z split reassembly)
- [OA-FLAT-SORT-DEPOT.md](OA-FLAT-SORT-DEPOT.md) — customer dumps downloads flat → `sort-flat-depot.sh` arranges into `PROD/COMP/`
- [METADATA-ZIP-DEPOT.md](METADATA-ZIP-DEPOT.md) — official metadata zip + token-downloaded binaries
- [MY_VCF_DEPOT.md](MY_VCF_DEPOT.md) — `My-VcfDepot.ps1` (token-only catalog reader / depot builder)

**RHEL / air-gapped OS**
- [OFFLINE-OS-REPO.md](OFFLINE-OS-REPO.md) — offline DNF/apt package repos + RHEL VCF depot + `:8888` no-auth endpoint

**Troubleshooting**
- [INSTALLER_CONNECT_TROUBLESHOOTING.md](INSTALLER_CONNECT_TROUBLESHOOTING.md) — installer → depot connection gotchas

## References

- [vstellar.com — VCF 9.1 Home Lab Series Part 4: VCF Offline Depot](https://vstellar.com/2026/05/vcf-9-1-home-lab-series-part-4-vcf-offline-depo/)
- [williamlam.com — VCF 9.1 New HTTP Offline Depot Support](https://williamlam.com/2026/05/vcf-9-1-new-http-offline-depot-support-for-vcf-installer-fleet-depot-service.html)
