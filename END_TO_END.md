# End-to-End: Download → Offline Depot → VCF 9.1 Installer

The full flow to feed VCF binaries to a **VCF 9.1 Installer** from an offline
depot. Based on the working lab setup (real values in the "Lab reference"
section at the bottom).

> Secrets (download token, passwords) are placeholders `<...>` — this is a
> public repo. Use your own values.

```
┌─ internet box ─┐        ┌─ depot server (offline) ─┐        ┌─ VCF 9.1 Installer ─┐
│ vcf-download-  │  copy  │  nginx serves            │  API   │  points at depot    │
│ tool downloads │ ─────► │  http://<depot>:8888/PROD│ ◄───── │  pulls binaries     │
│ → /opt/vcf-... │  (USB/ │                          │  set   │  = ready to deploy  │
└────────────────┘  rsync)└──────────────────────────┘        └─────────────────────┘
```

---

## Step 1 — Download the binaries (on an internet-connected box)

```bash
# install the download tool (see setup_vcf_download_tool.sh)
sudo bash setup_vcf_download_tool.sh --tgz /root/vcf-download-tool-9.1.0.0.tar.gz --token '<TOKEN>'

# download everything for the VCF release (idempotent — re-run to get new patches)
echo '<TOKEN>' > /root/token.txt
/opt/vcf-depot/tools/bin/vcf-download-tool binaries download \
  --sku VCF --vcf-version 9.1.0 --automated-install \
  --depot-download-token-file /root/token.txt \
  --depot-store /opt/vcf-depot/vcf9
```

Result: `/opt/vcf-depot/vcf9/PROD/` (COMP/ + metadata/ + vsan/). ~166 GB+ for
full 9.1.0 INSTALL+PATCH. See `VCF_DOWNLOAD_TOOL.md` and `COPY_TO_DEPOT.md`.

---

## Step 2 — Stand up the depot server (works offline)

On the depot server (RHEL bootstraps nginx from the install DVD — no internet):

```bash
# RHEL all-in-one (DNF repo :80 + VCF depot :443).  Add :8888 no-auth below.
sudo bash setup_rhel_offline_all.sh --fqdn <depot-fqdn> --ip <depot-ip>

# OR Ubuntu: install packages offline first (see ubuntu_offline_packages.sh),
#            then create_vcf9_depot_server_v5.sh
```

The VCF 9.1 Installer connects over **HTTP with no auth on port 8888** (the new
9.1 mode). Add that server block (nginx):

```nginx
# /etc/nginx/conf.d/vcf9-noauth.conf
server {
    listen 8888 default_server;
    server_name <depot-fqdn> <depot-ip>;
    root /opt/vcf-depot/vcf9;
    location /PROD/ { alias /opt/vcf-depot/vcf9/PROD/; autoindex on; }
}
```
```bash
nginx -t && systemctl reload nginx
curl -s -o /dev/null -w '%{http_code}\n' http://<depot-ip>:8888/PROD/metadata/manifest/v1/vcfManifest.json   # 200
```

---

## Step 3 — Put the binaries on the depot (if downloaded elsewhere)

If Steps 1 and 2 are different machines:

```bash
# rsync (both boxes reachable):    run on the download box
sudo bash sync-vcf-depot.sh --target <depot-ip>

# hand copy (USB / air-gapped):    copy PROD/, then run on the depot server
sudo bash sync-vcf-depot.sh --local \
  --verify-url http://localhost:8888/PROD/metadata/manifest/v1/vcfManifest.json
```

---

## Step 4 — Point the VCF 9.1 Installer at the depot (API)

> The VCF 9.1 Installer **UI cannot** set an HTTP no-auth depot — use the API.
> Run these from any box that can reach the Installer.

```bash
INSTALLER=<installer-ip>
DEPOT_IP=<depot-ip>

# 1) get an access token
TOKEN=$(curl -sk -X POST https://${INSTALLER}/v1/tokens \
  -H 'Content-Type: application/json' \
  -d '{"username":"admin@local","password":"<PASSWORD>"}' \
  | sed -n 's/.*"accessToken":"\([^"]*\)".*/\1/p')

# 2) set the offline depot (HTTP no-auth :8888)
curl -sk -X PUT https://${INSTALLER}/v1/system/settings/depot \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d "{\"depotConfiguration\":{\"isOfflineDepot\":true,\"hostname\":\"${DEPOT_IP}\",\"port\":8888,\"url\":\"http://${DEPOT_IP}:8888\"}}"
```

For an **HTTPS + basic-auth** depot instead: import the depot cert into the
Installer first (`import_vcf9depot_ca.sh --url-insecure https://<depot> --vcf-installer`),
then set `"url":"https://<depot>"` — otherwise you get a misleading
"invalid credentials" error.

---

## Step 5 — Verify the Installer sees the binaries

```bash
# depot connection status (should be DEPOT_CONNECTION_SUCCESSFUL)
curl -sk https://${INSTALLER}/v1/system/settings/depot -H "Authorization: Bearer $TOKEN"

# available bundles/versions the Installer can now deploy
curl -sk https://${INSTALLER}/v1/bundles -H "Authorization: Bearer $TOKEN" \
  | grep -oE '9\.1\.0\.0[0-9]+\.[0-9]+' | sort -u

# on the depot side, confirm the installer is fetching:
tail -f /var/log/nginx/access.log | grep ${INSTALLER}
```

Expected: `DEPOT_CONNECTION_SUCCESSFUL`, the 9.1.x versions listed, and the
Installer pulling `productVersionCatalog.json` / `.sig` / compatibility data
(HTTP 200). The Installer is now ready to deploy VCF 9.1 from the offline depot.

---

## Lab reference (actual working values)

| Role | Host | IP | Notes |
| --- | --- | --- | --- |
| Offline depot | `vcf9depotserver.home.lab` | `10.0.0.61` | nginx; `http://10.0.0.61:8888/PROD`; VCF 9.0.1/9.0.2 + 9.1.0.0/0100/0200/0300 |
| VCF 9.1 Installer | `vcf-m01-cb01.home.lab` | `10.0.1.4` | Cloud Foundation Manager appliance; API user `admin@local` |
| vCenter | `labvc.lab.com` | `10.0.0.101` | manages the lab |

Verified in this lab:
```
PUT /v1/system/settings/depot  →  http://10.0.0.61:8888
GET /v1/system/settings/depot  →  {"status":"DEPOT_CONNECTION_SUCCESSFUL"}
GET /v1/bundles                →  9.1.0.0100 / 9.1.0.0200 (+0300) listed
nginx access.log               →  10.0.1.4 GET /PROD/metadata/.../productVersionCatalog.json 200
                                  10.0.1.4 GET /PROD/.../productVersionCatalog.sig 200 (signature OK)
```

> Passwords / tokens for the lab hosts are kept outside this public repo.

## Related

- `VCF_DOWNLOAD_TOOL.md` — download-tool command reference + `binaries upload`
- `COPY_TO_DEPOT.md` — placing binaries into the depot (manual / `--local`)
- `DEPOT_SERVERS.md` — depot server inventory
- `setup_rhel_offline_all.sh`, `create_vcf9_depot_server_v5.sh`, `sync-vcf-depot.sh`,
  `import_vcf9depot_ca.sh`, `setup_vcf_download_tool.sh`
