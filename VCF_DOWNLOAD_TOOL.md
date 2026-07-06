# VCF Download Tool — Usage Guide

The **VCF Download Tool** (`vcf-download-tool`) is Broadcom's CLI for populating
an offline VCF Software Depot: it downloads VCF binaries + metadata from the
Broadcom depot into a local directory that you then serve over HTTP(S) to the
VCF Installer / SDDC Manager.

> Secrets (download token) are **not** in this public repo — use `<TOKEN>` /
> `<TOKEN_FILE>` placeholders with your own value.

---

## 1. Get + install the tool

1. Download `vcf-download-tool-<version>.tar.gz` from the **Broadcom Support
   Portal** → *My Downloads* → VCF → *Drivers & Tools*.
2. Upload it to the depot server:
   ```bash
   scp  vcf-download-tool-9.1.0.0.*.tar.gz root@<DEPOT_IP>:/root/   # Linux/macOS
   pscp vcf-download-tool-9.1.0.0.*.tar.gz root@<DEPOT_IP>:/root/   # Windows PuTTY
   ```
3. Install it with the helper script in this repo:
   ```bash
   sudo bash setup_vcf_download_tool.sh --tgz /root/vcf-download-tool-9.1.0.0.*.tar.gz --token '<TOKEN>'
   ```
   or extract manually:
   ```bash
   mkdir -p /opt/vcf-depot/tools
   tar -xzf /root/vcf-download-tool-*.tar.gz -C /opt/vcf-depot/tools
   /opt/vcf-depot/tools/bin/vcf-download-tool -v
   ```

The binary lives at `/opt/vcf-depot/tools/bin/vcf-download-tool`.

---

## 2. The download token

All `list` / `download` commands need a **download token** from the Broadcom
Support Portal (*Generate Download Token*). Put it in a file:

```bash
echo '<TOKEN>' > /root/token.txt
chmod 600 /root/token.txt
```

Then pass `--depot-download-token-file /root/token.txt`.
(VCF 9.1 also accepts `--depot-download-activation-code-file activation-code.txt`.)

---

## 3. Commands

`vcf-download-tool [COMMAND]`

| Command | Purpose |
| --- | --- |
| `-v`, `--version` | Show the tool version |
| `binaries list` | List available binaries in the depot |
| `binaries download` | Download binaries + metadata into a local depot store |
| `binaries upload` | Upload downloaded binaries into an SDDC Manager |
| `configuration generate --software-depot-id` | Generate a software depot ID (some setups) |

### Key flags (list / download)

| Flag | Meaning |
| --- | --- |
| `--depot-store`, `-d` | Local depot directory (where binaries are written) |
| `--depot-download-token-file` | Path to the token file |
| `--vcf-version` | VCF version, e.g. `9.1.0` (supports ranges `9.1.0..9.1.0.0300`) |
| `--sku` | `VCF` or `VVF` |
| `--type`, `-t` | `INSTALL` or `UPGRADE` |
| `--automated-install` | Download the set the **VCF Installer** needs |

---

## 4. Common workflows

### List what's available (no download)

```bash
vcf-download-tool binaries list \
  --sku VCF --vcf-version 9.1.0 \
  --depot-download-token-file /root/token.txt \
  --type INSTALL --automated-install
```

### Download everything for a VCF version (initial populate)

```bash
vcf-download-tool binaries download \
  --sku VCF --vcf-version 9.1.0 \
  --depot-download-token-file /root/token.txt \
  --automated-install \
  --depot-store /opt/vcf-depot/vcf9
```

### Update to the latest (idempotent — skips already-downloaded)

Re-running the **same** download command later pulls only new binaries
(e.g. a new patch like `9.1.0.0300`) and reports the rest as
`ALREADY_DOWNLOADED`:

```bash
bash /opt/vcf-depot/download-vcf-binaries.sh     # helper created by the setup script
# or the raw command above again
```

### Download UPGRADE bundles (for in-place upgrades)

```bash
vcf-download-tool binaries download \
  --sku VCF --vcf-version 9.1.0 \
  --depot-download-token-file /root/token.txt \
  --type UPGRADE \
  --depot-store /opt/vcf-depot/vcf9
```

### A version range

```bash
# everything from 9.1.0 up to (and including) 9.1.0.0300
vcf-download-tool binaries list --sku VCF \
  --vcf-version 9.1.0..9.1.0.0300 \
  --depot-download-token-file /root/token.txt \
  --type INSTALL --automated-install
```

---

## 5. What gets downloaded

Into `--depot-store` (e.g. `/opt/vcf-depot/vcf9`):

```
PROD/
├── COMP/                       # component binaries (OVA / ISO / bundles)
│   ├── VCENTER/  NSX_T_MANAGER/  SDDC_MANAGER_VCF/  VROPS/
│   ├── VCF_OPS_CLOUD_PROXY/  VRA/  VIDB/  ESX_HOST/ ...
├── metadata/
│   ├── manifest/v1/vcfManifest.json
│   └── productVersionCatalog/v1/productVersionCatalog.json (+ .sig ← signed!)
└── vsan/hcl/all.json
```

> **Do not edit `productVersionCatalog.json`** — it is Broadcom-signed
> (`.sig`). Editing it (e.g. to strip old versions) breaks the signature and
> the VCF Installer will reject the whole depot.

You then serve `PROD/` over HTTP(S). See `create_vcf9_depot_server_*.sh` /
`setup_rhel_offline_all.sh` for the web-server side, and `DEPOT_SERVERS.md`
for the live lab layout.

---

## 5b. Getting binaries INTO the VCF Installer / SDDC Manager

There are two ways to make downloaded binaries available to VCF:

### Method A — Offline Depot (URL) *(recommended, what the lab uses)*

Download to a directory, serve it over HTTP(S), and point the VCF Installer /
SDDC Manager at the **depot URL**. It pulls what it needs. Nothing runs on the
appliance itself.

```
vcf-download-tool binaries download  →  /opt/vcf-depot/vcf9  →  nginx :8888
VCF Installer depot setting: url = http://<DEPOT_IP>:8888
```

Set it via the VCF Installer API (the UI cannot do HTTP no-auth depots):

```bash
TOKEN=$(curl -sk -X POST https://<INSTALLER>/v1/tokens \
  -H 'Content-Type: application/json' \
  -d '{"username":"admin@local","password":"<PASSWORD>"}' \
  | sed -n 's/.*"accessToken":"\([^"]*\)".*/\1/p')
curl -sk -X PUT https://<INSTALLER>/v1/system/settings/depot \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"depotConfiguration":{"isOfflineDepot":true,"hostname":"<DEPOT_IP>","port":8888,"url":"http://<DEPOT_IP>:8888"}}'
```

### Method B — Direct upload into SDDC Manager (`binaries upload`)

Push the binaries **directly into the SDDC Manager's internal store** — no
separate depot web server needed.

> **Prerequisites (from the tool):** the downloaded binaries must first be
> **transferred onto the SDDC Manager appliance**, and the command must be run
> **from within the SDDC Manager**.

```bash
# 1) download on any box
vcf-download-tool binaries download --sku VCF --vcf-version 9.1.0 \
  --automated-install --depot-download-token-file /root/token.txt \
  --depot-store /data/vcf-depot/vcf9

# 2) copy /data/vcf-depot/vcf9 onto the SDDC Manager appliance (scp / rsync)

# 3) ON the SDDC Manager, run:
echo '<SDDC_MANAGER_PASSWORD>' > /root/sddcpass.txt; chmod 600 /root/sddcpass.txt
vcf-download-tool binaries upload \
  --depot-store=/data/vcf-depot/vcf9 \
  --sddc-manager-fqdn=<SDDC_MANAGER_FQDN> \
  --sddc-manager-user=<admin_user> \
  --sddc-manager-user-password-file=/root/sddcpass.txt
```

| | Method A (Depot URL) | Method B (Direct upload) |
| --- | --- | --- |
| Use when | Initial deploy (VCF Installer) + ongoing | You already have an SDDC Manager |
| Web server needed | yes (nginx/apache) | no |
| Runs where | depot server | inside SDDC Manager |
| Binaries live | on the depot server | pushed into SDDC Manager |

---

## 6. Real lab example (10.0.0.61)

```bash
# tool:   /opt/vcf-depot/tools/bin/vcf-download-tool
# store:  /opt/vcf-depot/vcf9
# served: http://10.0.0.61:8888/PROD  (VCF 9.1 Installer connects here)

echo '<TOKEN>' > /root/token.txt
/opt/vcf-depot/tools/bin/vcf-download-tool binaries download \
  --vcf-version 9.1.0 --automated-install \
  --depot-download-token-file /root/token.txt \
  --depot-store /opt/vcf-depot/vcf9
```

Result: VCF `9.1.0.0 / 0100 / 0200 / 0300` (INSTALL + PATCH), ~366 GB.

---

## References

- `setup_vcf_download_tool.sh` — installs the tool + makes a re-runnable helper
- `DEPOT_SERVERS.md` — live depot server inventory
- Broadcom Support Portal — token generation + tool download
