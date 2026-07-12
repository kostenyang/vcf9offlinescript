#!/usr/bin/env bash
# Stand up a LOCAL offline depot ON the VCF Installer appliance itself (Photon),
# serving an already-populated depot tree via a STANDALONE nginx on :8443
# (does NOT touch the appliance's own UI nginx). Then import the cert into the
# JRE truststore lcm uses, so the installer can consume https://<self-ip>:8443.
#
# VALIDATED on VCF Installer 9.1 (Photon, OpenJDK 21). Run as ROOT (su -).
#
# Usage:  bash _localdepot_on_installer.sh <SELF_IP> <DEPOT_ROOT>
#   DEPOT_ROOT must contain PROD/  (e.g. /nfs/vmware/vcf/nfs-mount/localdepot/vcf9)
#
# NOTE: keep LF line endings. If cloned on Windows, run:  sed -i 's/\r$//' this-file
set -eu
IP="${1:?need self ip}"; ROOT="${2:?need depot root (contains PROD/)}"
USER_="vcfdepot"; PASS='VMware1!VMware1!'; PORT=8443
CERTDIR=/root/vcf9-localdepot
[ -d "$ROOT/PROD" ] || { echo "ERROR: $ROOT/PROD not found"; exit 1; }

echo "== make depot readable =="
chmod -R a+rX "$ROOT"

echo "== self-signed cert (SAN: IP $IP + 127.0.0.1) =="
mkdir -p "$CERTDIR"
cat >/tmp/san.cnf <<EOF
[req]
default_bits=4096
prompt=no
default_md=sha256
x509_extensions=v3
distinguished_name=dn
[dn]
CN=$IP
[v3]
subjectAltName=@alt
basicConstraints=critical,CA:TRUE
keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign,cRLSign
extendedKeyUsage=serverAuth
[alt]
IP.1=$IP
IP.2=127.0.0.1
EOF
openssl req -x509 -nodes -days 825 -newkey rsa:4096 \
  -keyout "$CERTDIR/depot.key" -out "$CERTDIR/depot.crt" -config /tmp/san.cnf 2>/dev/null

echo "== basic-auth (python crypt SHA-512; Photon openssl 'passwd -apr1' yields an EMPTY hash) =="
HASH="$(python3 -c 'import crypt,sys;print(crypt.crypt(sys.argv[1],crypt.mksalt(crypt.METHOD_SHA512)))' "$PASS")"
printf '%s:%s\n' "$USER_" "$HASH" > "$CERTDIR/htpasswd"

echo "== standalone nginx on :$PORT (separate master; does not touch UI nginx) =="
cat >"$CERTDIR/nginx8443.conf" <<EOF
user root;
worker_processes 1;
pid /run/nginx-depot8443.pid;
error_log /var/log/nginx-depot8443-err.log;
events { worker_connections 128; }
http {
  access_log /var/log/nginx-depot8443-acc.log;
  server {
    listen $PORT ssl;
    ssl_certificate     $CERTDIR/depot.crt;
    ssl_certificate_key $CERTDIR/depot.key;
    auth_basic "VCF9 Local Depot";
    auth_basic_user_file $CERTDIR/htpasswd;
    client_max_body_size 0;
    location /PROD/ { alias $ROOT/PROD/; autoindex on; }
  }
}
EOF
[ -f /run/nginx-depot8443.pid ] && kill "$(cat /run/nginx-depot8443.pid)" 2>/dev/null || true
sleep 1
nginx -c "$CERTDIR/nginx8443.conf" -t
nginx -c "$CERTDIR/nginx8443.conf"

echo "== open $PORT (iptables best-effort) =="
iptables -C INPUT -p tcp --dport $PORT -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport $PORT -j ACCEPT 2>/dev/null || true

echo "== import cert into the JRE cacerts lcm uses (NOT just system trust) =="
CACERTS="$(find /usr/lib/jvm -name cacerts 2>/dev/null | head -1)"
[ -n "$CACERTS" ] || CACERTS="$(find / -name cacerts 2>/dev/null | head -1)"
KT="$(command -v keytool || true)"
if [ -n "$CACERTS" ] && [ -n "$KT" ]; then
  "$KT" -delete -alias vcf9depot-ca -keystore "$CACERTS" -storepass changeit -noprompt 2>/dev/null || true
  "$KT" -importcert -trustcacerts -alias vcf9depot-ca -file "$CERTDIR/depot.crt" \
     -keystore "$CACERTS" -storepass changeit -noprompt && echo "  imported -> $CACERTS"
else
  echo "  WARN: keytool/cacerts not found; import manually or lcm TLS fails (certificate_unknown)"
fi
command -v rehash_ca_certificates.sh >/dev/null 2>&1 && rehash_ca_certificates.sh >/dev/null 2>&1 || true

echo "== restart lcm to reload truststore =="
systemctl restart lcm.service 2>/dev/null || true

echo "== self-test =="
sleep 3
curl -sk -u "$USER_:$PASS" "https://$IP:$PORT/PROD/metadata/productVersionCatalog/v1/productVersionCatalog.json" -o /dev/null -w '  serve check -> HTTP %{http_code}\n'
echo "DONE. Point the installer offline depot at:  https://$IP:$PORT   (user $USER_)"
echo "Reminder: the depot tree must include COMP/SDDC_MANAGER_VCF/Compatibility/VmwareCompatibilityData.json or sync fails with 'Vmware compatibility data download failed'."
