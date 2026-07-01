# Offline Depot Servers — Inventory

Home-lab inventory of the offline depot / repo servers built with the scripts
in this repo.

> **Security note:** this is a **public** repo. Passwords, download tokens, and
> API secrets are intentionally **NOT** stored here — they are kept separately.
> Replace the `<...>` placeholders below with your own values at use time.

---

## Primary VCF Offline Depot (production)

| Field | Value |
| --- | --- |
| Hostname | `vcf9depotserver.home.lab` |
| IP | `10.0.0.61` (also `10.0.0.69`) |
| OS | Ubuntu (nginx) |
| Role | **Main VCF 9.1 offline depot** — the one the VCF Installer uses |
| Depot data | `/opt/vcf-depot/vcf9/PROD` |
| Download tool | `/opt/vcf-depot/tools/bin/vcf-download-tool` |
| Download token | *(kept separately — not in this repo)* |

### Serving modes (nginx)

| URL | Port | Auth | Purpose |
| --- | --- | --- | --- |
| `http://10.0.0.61:8888/PROD` | 8888 | none | **HTTP no-auth** — VCF 9.1 Installer connects here |
| `https://10.0.0.61/PROD` | 443 | basic | HTTPS + basic auth (legacy/alt) |

### VCF versions present

- VCF `9.0.1`, `9.0.2`
- VCF `9.1.0.0`, `9.1.0.0100`, `9.1.0.0200`, `9.1.0.0300` (kept current)

### Connected VCF Installer

| Field | Value |
| --- | --- |
| Installer VM | `vcf-m01-cb01.home.lab-9.1` |
| Installer IP | `10.0.1.4` |
| API user | `admin@local` / *(password kept separately)* |
| Depot config | `isOfflineDepot=true`, `url=http://10.0.0.61:8888` |
| Status | `DEPOT_CONNECTION_SUCCESSFUL` ✅ |

### Update to latest

```bash
# On 10.0.0.61 — pulls any newer VCF 9.1 patch, skips already-downloaded
bash /opt/vcf-depot/download-vcf91-binaries.sh
```

### Point the VCF Installer at this depot (API)

```bash
TOKEN=$(curl -sk -X POST https://10.0.1.4/v1/tokens \
  -H 'Content-Type: application/json' \
  -d '{"username":"admin@local","password":"<PASSWORD>"}' \
  | sed -n 's/.*"accessToken":"\([^"]*\)".*/\1/p')

curl -sk -X PUT https://10.0.1.4/v1/system/settings/depot \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"depotConfiguration":{"isOfflineDepot":true,"hostname":"10.0.0.61","port":8888,"url":"http://10.0.0.61:8888"}}'
```

---

## RHEL 9.8 All-in-One (repo + depot)

| Field | Value |
| --- | --- |
| Hostname | `rhel98-test.home.lab` |
| IP | `10.0.0.72` |
| OS | RHEL 9.8 (nginx) |
| Built with | `setup_rhel_offline_all.sh` |
| DNF repo | `http://10.0.0.72/rhel/` (BaseOS + AppStream) |
| Client repo file | `http://10.0.0.72/rhel-offline.repo` |
| VCF depot (HTTPS+auth) | `https://10.0.0.72/PROD` — user `vcfdepot` / *(pw separate)* |
| VCF depot (HTTP no-auth) | `http://10.0.0.72:8888/PROD` |
| VCF binaries | 9.1.0.0 / 0100 / 0200 (synced from 61) on a 200 GB xfs disk at `/opt/vcf-depot` |
| Depot cert | `/etc/nginx/vcf9-certs/vcf9-depot.crt` (self-signed **CA cert**) |

---

## RHEL 10.2 All-in-One (repo + depot)

| Field | Value |
| --- | --- |
| Hostname | `rhel10-repo.home.lab` |
| IP | `10.0.0.71` |
| OS | RHEL 10.2 (nginx) |
| DNF repo | `http://10.0.0.71/rhel/` |
| VCF depot (HTTPS+auth) | `https://10.0.0.71/PROD` |
| Notes | DNF repo :80 + VCF depot :443 coexist on one nginx |

---

## Which script built / maintains each

| Task | Script |
| --- | --- |
| RHEL repo + VCF depot (all-in-one) | `setup_rhel_offline_all.sh` |
| VCF depot only (RHEL, coexist-safe) | `create_vcf9_depot_server_rhel.sh` |
| VCF depot (Ubuntu/RHEL, nginx/apache) | `create_vcf9_depot_server_v5.sh` |
| RHEL DNF repo only | `setup_rhel10_offline_repo.sh` |
| Change hostname / IP (RHEL) | `change_rhel_offline_hostname_ip.sh` |
| Change hostname / IP (Ubuntu depot) | `change_depot_hostname_ip.sh` |
| Import depot cert (Installer/SDDC/OPS) | `import_vcf9depot_ca.sh` |

---

## Network / access notes

- Lab subnet: `10.0.0.0/23` (covers `10.0.0.x` and `10.0.1.x`).
- VCF management appliances live on `10.0.1.x` (same /23, reachable from `10.0.0.x`).
- SSH / API credentials for all hosts are kept **outside** this public repo.
