# Copy the VCF 9.1 depot tarball into a `create_vcf9_depot_server_v5.sh` server

How to populate an already-built v5 depot server from the delivered
`vcf9-depot-latest.tar.gz`. The v5 server serves `/opt/vcf-depot/vcf9/PROD/`,
and the tarball's top entry is `PROD/`, so you extract it straight into the
depot root.

> Prereq: the depot server already exists (built with
> `create_vcf9_depot_server_v5.sh`). Run that **without** `--download-binaries` —
> the tarball already has the binaries.

## 1. Copy the tarball to the depot server

```bash
scp vcf9-depot-latest.tar.gz root@<DEPOT_IP>:/root/
```

## 2. Extract it into the depot root

```bash
sudo mkdir -p /opt/vcf-depot/vcf9
sudo tar -xzf /root/vcf9-depot-latest.tar.gz -C /opt/vcf-depot/vcf9/
# -> /opt/vcf-depot/vcf9/PROD/COMP/...  and  /opt/vcf-depot/vcf9/PROD/metadata/...
```

## 3. Re-apply ownership + permissions (required)

v5 locks the tree to the web user (`0500` dirs / `0400` files); extracted files
come in as root, so the web server can't read them until you fix this:

```bash
WEB_USER=www-data        # Ubuntu/Debian = www-data ; RHEL/Rocky = nginx
sudo chown -R "$WEB_USER:$WEB_USER" /opt/vcf-depot/vcf9
sudo find /opt/vcf-depot/vcf9 -type d -exec chmod 0500 {} +
sudo find /opt/vcf-depot/vcf9 -type f -exec chmod 0400 {} +
# RHEL + SELinux: sudo restorecon -Rv /opt/vcf-depot/vcf9
```

## 4. Reload the web server

```bash
sudo nginx -t && sudo systemctl reload nginx
# Apache:  sudo apachectl configtest && sudo systemctl reload apache2
```

## 5. Verify it serves

```bash
curl -sk -u '<DEPOT_USER>:<DEPOT_PASS>' \
  https://<DEPOT_FQDN>:443/PROD/metadata/productVersionCatalog/v1/productVersionCatalog.json \
  -o /dev/null -w 'HTTP %{http_code}\n'          # expect HTTP 200
```

Done — the depot is populated. Point VCF Installer at `https://<DEPOT_FQDN>:443`
(import the depot cert first, then set the depot URL + basic-auth creds).
