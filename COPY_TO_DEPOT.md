# Copying VCF binaries into the depot (air-gapped)

When you carry the depot in by hand (USB / external disk / tar / scp) instead
of `rsync`, the files land owned by `root` with the wrong permissions and
SELinux context, so nginx returns **403/404**. After copying you must fix
ownership + permissions (+ SELinux on RHEL). Two ways to do it.

> Depot path must be exactly `/opt/vcf-depot/vcf9/PROD/` (what nginx serves).
> Keep the structure intact: `PROD/COMP/<component>`, `PROD/metadata/manifest`,
> `PROD/metadata/productVersionCatalog`, `PROD/vsan/hcl` — do NOT rename or
> nest them.

---

## Method 1 — Manual (raw commands)

```bash
# 1. Put the files in the right place (from USB / tar / scp)
cp -a /media/usb/PROD/.  /opt/vcf-depot/vcf9/PROD/
#   or:  tar -xf depot.tar -C /opt/vcf-depot/vcf9/

# 2. Fix ownership  (RHEL: nginx | Ubuntu: www-data)
chown -R nginx:nginx /opt/vcf-depot/vcf9/PROD

# 3. Fix permissions
find /opt/vcf-depot/vcf9/PROD -type d -exec chmod 755 {} +
find /opt/vcf-depot/vcf9/PROD -type f -exec chmod 644 {} +

# 4. SELinux context (RHEL, only if Enforcing)
restorecon -R /opt/vcf-depot/vcf9/PROD

# 5. Reload the web server + verify
systemctl reload nginx
curl -s -o /dev/null -w '%{http_code}\n' \
  http://localhost:8888/PROD/metadata/manifest/v1/vcfManifest.json
# 200 (or 401 if the depot uses basic auth) = serving OK
```

---

## Method 2 — Script (one command)

`sync-vcf-depot.sh --local` does steps 2–5 automatically (auto-detects the web
user, fixes perms, restores SELinux, reloads, verifies):

```bash
# After the files are in /opt/vcf-depot/vcf9/PROD/, run ON the depot server:
sudo bash sync-vcf-depot.sh --local \
  --verify-url http://localhost:8888/PROD/metadata/manifest/v1/vcfManifest.json
```

Options:
- `--depot-store PATH` if your depot root isn't `/opt/vcf-depot/vcf9`
- `--web-user USER` to override the auto-detected web user
- `--no-reload` / `--no-perms` to skip a step

---

## Which to use

| | Manual | Script (`--local`) |
| --- | --- | --- |
| Steps | 5 commands to remember | 1 command |
| Web user | you must pick nginx/www-data | auto-detected |
| SELinux | you must remember `restorecon` | automatic |
| Verify | manual curl | built-in `--verify-url` |

Both are equivalent — the script just wraps the manual steps so nothing is
forgotten (the usual cause of a 403 after a manual copy).

See also: `sync-vcf-depot.sh --target HOST` to **rsync** the depot from the
download box to a serving node (when the two have network connectivity).
