#!/usr/bin/env bash
# Stand up a LOCAL offline depot ON the VCF Installer appliance itself (Photon).
# Serves an already-extracted depot tree via a dedicated nginx vhost on :8443
# (HTTPS + basic auth + self-signed cert with IP-SAN), then imports the cert into
# the appliance trust so the installer can consume https://<self-ip>:8443.
#
# Usage:  bash _localdepot_on_installer.sh <SELF_IP> <DEPOT_ROOT>
#   DEPOT_ROOT must already contain PROD/  (e.g. /nfs/vmware/vcf/nfs-mount/localdepot/vcf9)
set -euo pipefail
IP="${1:?need self ip}"; ROOT="${2:?need depot root (contains PROD/)}"
USER_="vcfdepot"; PASS="VMware1!VMware1!"; PORT=8443
CERTDIR=/etc/nginx/vcf9-certs
[ -d "$ROOT/PROD" ] || { echo "ERROR: $ROOT/PROD not found"; exit 1; }

echo "== make depot readable by nginx worker =="
chmod -R a+rX "$ROOT"

echo "== self-signed cert (SAN: IP $IP + 127.0.0.1 + localhost) =="
mkdir -p "$CERTDIR"
cat >/tmp/san.cnf <<EOF
[req]
default_bits=4096
prompt=no
default_md=sha256
x509_extensions=v3_req
distinguished_name=dn
[dn]
CN=$IP
[v3_req]
subjectAltName=@alt
basicConstraints=critical, CA:TRUE
keyUsage=critical, digitalSignature, keyEncipherment, keyCertSign, cRLSign
extendedKeyUsage=serverAuth
[alt]
IP.1=$IP
IP.2=127.0.0.1
DNS.1=localhost
EOF
openssl req -x509 -nodes -days 825 -newkey rsa:4096 \
  -keyout "$CERTDIR/vcf9-depot.key" -out "$CERTDIR/vcf9-depot.crt" -config /tmp/san.cnf
chmod 600 "$CERTDIR/vcf9-depot.key"; chmod 644 "$CERTDIR/vcf9-depot.crt"

echo "== basic-auth (htpasswd via openssl passwd -apr1, no htpasswd binary needed) =="
HASH=$(openssl passwd -apr1 "$PASS")
printf '%s:%s\n' "$USER_" "$HASH" > /etc/nginx/.htpasswd-vcf9
chmod 0640 /etc/nginx/.htpasswd-vcf9

echo "== nginx vhost on :$PORT =="
# find the http{} include dir
INCDIR=/etc/nginx/conf.d
grep -q 'conf.d/\*.conf' /etc/nginx/nginx.conf 2>/dev/null || {
  # fall back: append an include to http{} if conf.d not already included
  if ! grep -q "$INCDIR" /etc/nginx/nginx.conf; then
    sed -i "0,/http {/s//http {\n    include $INCDIR\/*.conf;/" /etc/nginx/nginx.conf
  fi
}
mkdir -p "$INCDIR"
cat >"$INCDIR/vcf9-localdepot.conf" <<EOF
server {
    listen $PORT ssl;
    server_name $IP;
    ssl_certificate     $CERTDIR/vcf9-depot.crt;
    ssl_certificate_key $CERTDIR/vcf9-depot.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    auth_basic "VCF9 Local Depot";
    auth_basic_user_file /etc/nginx/.htpasswd-vcf9;
    client_max_body_size 0;
    location /PROD/ {
        alias $ROOT/PROD/;
        autoindex on;
    }
}
EOF
nginx -t
systemctl reload nginx 2>/dev/null || systemctl restart nginx

echo "== open 8443 (iptables, best-effort) =="
iptables -C INPUT -p tcp --dport $PORT -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport $PORT -j ACCEPT 2>/dev/null || true

echo "== import cert into appliance trust + Java, restart lcm =="
cp "$CERTDIR/vcf9-depot.crt" /etc/ssl/certs/vcf9-localdepot.pem 2>/dev/null || true
if command -v rehash_ca_certificates.sh >/dev/null 2>&1; then rehash_ca_certificates.sh || true; fi
CACERTS=$(find / -name cacerts -path '*lib/security*' 2>/dev/null | head -1)
if [ -n "$CACERTS" ] && command -v keytool >/dev/null 2>&1; then
  keytool -import -noprompt -trustcacerts -alias vcf9localdepot \
    -file "$CERTDIR/vcf9-depot.crt" -keystore "$CACERTS" -storepass changeit 2>/dev/null || true
fi
systemctl restart lcm.service 2>/dev/null || true

echo "== self-test =="
sleep 3
curl -sk -u "$USER_:$PASS" "https://$IP:$PORT/PROD/metadata/productVersionCatalog/v1/productVersionCatalog.json" -o /dev/null -w 'HTTP %{http_code}\n'
echo "DONE local depot -> https://$IP:$PORT  (auth $USER_/$PASS)"
