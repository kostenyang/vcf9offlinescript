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
