# Deploy the VCF 9.1 depot tarball onto a `create_vcf9_depot_server_v5.sh` server

This is the customer-side procedure for standing up the offline depot from the
delivered tarball (`vcf9-depot-latest.tar.gz`) on a depot server built with
**`create_vcf9_depot_server_v5.sh`** (HTTPS :443 + basic auth, data at
`/opt/vcf-depot/vcf9`).

> Replace the placeholders with your values:
> - `<DEPOT_FQDN>`  e.g. `vcf91-depot.customer.lab`
> - `<DEPOT_IP>`    e.g. `10.20.30.40`
> - `<DEPOT_USER>` / `<DEPOT_PASS>` — the basic-auth creds you set in v5
>   (v5 defaults: `vcfdepot` / `VMware1!VMware1!`)

The tarball contains a ready-to-serve `PROD/` tree:
`PROD/COMP/<component>/…` binaries + `PROD/metadata/…` (Broadcom-signed
`productVersionCatalog.json` + `.sig`, `manifest`, vSAN HCL, **Compatibility data**)
— so VCF Installer sync succeeds out of the box.

---

## 0. Prerequisite — the depot server itself

If the depot server is **not built yet**, build it first (one time). Example
(nginx, 500 GB second disk mounted as the web root — adjust to your VM):

```bash
sudo bash create_vcf9_depot_server_v5.sh \
  --fqdn <DEPOT_FQDN> --ip <DEPOT_IP> \
  --web-server nginx \
  --data-disk /dev/sdb            # omit if you already have space on /var/www/html
```

This creates the empty depot tree at `/opt/vcf-depot/vcf9/PROD/`, the TLS cert,
basic auth, firewall rules, and the nginx `/PROD/` alias. **You then fill that
tree from the tarball below** (skip v5's `--download-binaries` — the tarball
already has everything).

---

## 1. Copy the tarball to the depot server

```bash
# from wherever you received it (scp / USB / etc.)
scp vcf9-depot-latest.tar.gz root@<DEPOT_IP>:/root/
```

## 2. Extract it into the v5 depot root

The tarball's top entry is `PROD/`, and v5 serves `/opt/vcf-depot/vcf9/PROD/`,
so extract **into `/opt/vcf-depot/vcf9/`**:

```bash
sudo mkdir -p /opt/vcf-depot/vcf9
sudo tar -xzf /root/vcf9-depot-latest.tar.gz -C /opt/vcf-depot/vcf9/
# result: /opt/vcf-depot/vcf9/PROD/COMP/... and /opt/vcf-depot/vcf9/PROD/metadata/...
```

Quick check:

```bash
ls /opt/vcf-depot/vcf9/PROD/COMP        # component dirs (VCENTER, NSX_T_MANAGER, ...)
ls /opt/vcf-depot/vcf9/PROD/metadata    # manifest, productVersionCatalog(+.sig), vsan, Compatibility
du -sh /opt/vcf-depot/vcf9/PROD
```

## 3. Re-apply ownership + permissions (IMPORTANT)

v5 locks the depot tree down to the web user (`0500` dirs / `0400` files). The
extracted files come in as `root` with default perms, so the web server can't
read them until you re-apply v5's ownership/permissions:

```bash
# web user: Ubuntu/Debian = www-data ; RHEL/Rocky = nginx (or apache for httpd)
WEB_USER=www-data
sudo chown -R "$WEB_USER:$WEB_USER" /opt/vcf-depot/vcf9
sudo find /opt/vcf-depot/vcf9 -type d -exec chmod 0500 {} +
sudo find /opt/vcf-depot/vcf9 -type f -exec chmod 0400 {} +
```

> RHEL + SELinux Enforcing: also
> `sudo restorecon -Rv /opt/vcf-depot/vcf9` (v5 already added the fcontext rule).

## 4. Reload the web server

```bash
sudo nginx -t && sudo systemctl reload nginx      # nginx
# or:  sudo apachectl configtest && sudo systemctl reload apache2   # Apache
```

## 5. Verify it serves (on the depot server or any host that trusts the cert)

```bash
# -k skips cert trust just for this smoke test; auth is required
curl -sk -u '<DEPOT_USER>:<DEPOT_PASS>' \
  https://<DEPOT_FQDN>:443/PROD/metadata/productVersionCatalog/v1/productVersionCatalog.json \
  -o /dev/null -w 'HTTP %{http_code}\n'          # expect HTTP 200

curl -sk -u '<DEPOT_USER>:<DEPOT_PASS>' https://<DEPOT_FQDN>:443/PROD/COMP/   # dir listing
```

---

## 6. Point VCF Installer / SDDC Manager at it

**6a. Import the depot certificate FIRST** (skipping this makes VCF report a
misleading `Invalid credentials` even when the username/password are correct):

```bash
# on the VCF Installer host, using the helper shipped with v5:
sudo bash import_vcf9depot_ca.sh --url-insecure https://<DEPOT_FQDN>:443
# or from the cert file: sudo bash import_vcf9depot_ca.sh --cert vcf9-depot.crt
```

**6b. Configure the depot** — VCF Installer UI → *Administration → Depot
Settings* (or the API):

| Field | Value |
|-------|-------|
| URL | `https://<DEPOT_FQDN>:443` |
| Username | `<DEPOT_USER>` |
| Password | `<DEPOT_PASS>` |

API equivalent:

```bash
TOKEN=$(curl -sk -X POST https://<INSTALLER>/v1/tokens \
  -H 'Content-Type: application/json' \
  -d '{"username":"admin@local","password":"<INSTALLER_PASS>"}' \
  | sed -n 's/.*"accessToken":"\([^"]*\)".*/\1/p')

curl -sk -X PUT https://<INSTALLER>/v1/system/settings/depot \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"depotConfiguration":{"isOfflineDepot":true,"url":"https://<DEPOT_FQDN>:443",
       "username":"<DEPOT_USER>","password":"<DEPOT_PASS>"}}'

# trigger metadata sync, then poll until syncStatus = SYNCED
curl -sk -X PATCH https://<INSTALLER>/v1/system/settings/depot/depot-sync-info \
  -H "Authorization: Bearer $TOKEN"
```

Metadata sync should reach **`SYNCED`** (the tarball includes the Compatibility
data, so it will not fail with *"Vmware compatibility data download failed"*).
Bundles then show as available for bring-up.

---

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| `Invalid credentials` in VCF Installer (creds are correct) | Depot **cert not imported** into the Java truststore — do step 6a, retry. |
| `403 Forbidden` from the web server | Permissions — re-run step 3 (`chown`/`chmod`); RHEL: `restorecon`. |
| Sync `SYNC_FAILED: Vmware compatibility data download failed` | `PROD/COMP/SDDC_MANAGER_VCF/Compatibility/VmwareCompatibilityData.json` missing — confirm step 2 extracted it. |
| `404` on a bundle during bring-up | That version isn't in this depot (it's a *latest-only* build). Pull the extra version with the download tool, or request an updated tarball. |
