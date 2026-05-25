#!/usr/bin/env bash
# ===========================================================================
# setup_vcf91_apache_offline_depot.sh
#
# VCF 9.1 Offline Software Depot — Apache2 + HTTPS + Basic Auth
#
# Based on: https://vstellar.com/2026/05/vcf-9-1-home-lab-series-part-4-vcf-offline-depo/
#
# What this script does:
#   1. Installs Apache2, openssl, apache2-utils
#   2. (Optional) Formats and mounts a data disk as /var/www/html
#   3. Generates a CSR + self-signed cert, or uses an existing cert/key pair
#   4. Configures Apache HTTPS virtual host with basic authentication
#   5. Imports the depot certificate into the VCF Installer Java truststore
#   6. Extracts the vcf-download-tool tarball
#   7. Generates a software depot ID configuration
#   8. (Optional) Lists and downloads VCF 9.1.0.0 INSTALL binaries
#
# Tested on: Ubuntu 24.04 LTS
# VCF version: 9.1.0.0
# ===========================================================================
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_VERSION="1.0.0"

# ---------------------------------------------------------------------------
# Defaults — override via CLI flags or environment variables
# ---------------------------------------------------------------------------
VCF_VERSION="${VCF_VERSION:-9.1.0.0}"
DEPOT_FQDN="${DEPOT_FQDN:-vcf91-repo.example.lab}"
DEPOT_IP="${DEPOT_IP:-}"

# Certificate subject fields
CERT_COUNTRY="${CERT_COUNTRY:-US}"
CERT_STATE="${CERT_STATE:-California}"
CERT_CITY="${CERT_CITY:-Palo Alto}"
CERT_ORG="${CERT_ORG:-Lab}"
CERT_OU="${CERT_OU:-Cloud-Services}"

# SSL paths
SSL_DIR="${SSL_DIR:-/etc/apache2/ssl}"
CERT_FILE="${SSL_DIR}/${DEPOT_FQDN}.crt"
KEY_FILE="${SSL_DIR}/${DEPOT_FQDN}.key"
CSR_FILE="${SSL_DIR}/${DEPOT_FQDN}.csr"

# Optional: bring your own cert/key (skip generation)
EXISTING_CERT="${EXISTING_CERT:-}"
EXISTING_KEY="${EXISTING_KEY:-}"

# Apache basic auth
DEPOT_USER="${DEPOT_USER:-vcfadmin}"
DEPOT_PASS="${DEPOT_PASS:-}"
HTPASSWD_FILE="${HTPASSWD_FILE:-/etc/apache2/.htpasswd}"

# Data disk (set SKIP_DISK_SETUP=true if /var/www/html is already mounted)
DATA_DISK="${DATA_DISK:-/dev/sdb}"
SKIP_DISK_SETUP="${SKIP_DISK_SETUP:-false}"
WEB_ROOT="${WEB_ROOT:-/var/www/html}"

# vcf-download-tool
VDT_TGZ="${VDT_TGZ:-}"            # path to vcf-download-tool-*.tar.gz
VDT_DIR="${VDT_DIR:-/opt/vdt}"
VDT_BIN="${VDT_DIR}/vcf-download-tool"
ACTIVATION_CODE_FILE="${ACTIVATION_CODE_FILE:-}"   # activation-code.txt from Broadcom

# Behaviour flags
DOWNLOAD_BINARIES="${DOWNLOAD_BINARIES:-false}"
DOWNLOAD_TYPE="${DOWNLOAD_TYPE:-INSTALL}"          # INSTALL | UPGRADE | ALL
IMPORT_CERT_TO_KEYSTORE="${IMPORT_CERT_TO_KEYSTORE:-false}"
JAVA_TRUSTSTORE="${JAVA_TRUSTSTORE:-/etc/ssl/certs/java/cacerts}"
JAVA_TRUSTSTORE_PASS="${JAVA_TRUSTSTORE_PASS:-changeit}"
CERT_ALIAS="${CERT_ALIAS:-vcfRepoCert}"

# ---------------------------------------------------------------------------
# Colour helpers
# ---------------------------------------------------------------------------
green()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$*"; }
red()    { printf '\033[0;31m%s\033[0m\n' "$*" >&2; }
info()   { green   "[INFO]  $*"; }
warn()   { yellow  "[WARN]  $*"; }
die()    { red     "[ERROR] $*"; exit 1; }
step()   { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
Usage: sudo bash ${SCRIPT_NAME} --fqdn vcf91-repo.example.lab [options]

Sets up a VCF 9.1 offline depot server (Apache2 + HTTPS + basic auth).
Based on: https://vstellar.com/2026/05/vcf-9-1-home-lab-series-part-4-vcf-offline-depo/

Required:
  --fqdn FQDN              Fully qualified domain name of this depot server

Certificate options:
  --ip IP                  IP address for the SAN (optional but recommended)
  --country CODE           Certificate subject country  [${CERT_COUNTRY}]
  --state STATE            Certificate subject state    [${CERT_STATE}]
  --city CITY              Certificate subject city     [${CERT_CITY}]
  --org ORG                Certificate subject org      [${CERT_ORG}]
  --ou OU                  Certificate subject OU       [${CERT_OU}]
  --existing-cert PATH     Use an existing PEM certificate (skip generation)
  --existing-key PATH      Use an existing PEM private key (skip generation)
  --import-cert            Import the depot cert into the Java truststore
                           (required if VCF Installer is on this host)
  --truststore PATH        Java cacerts path  [${JAVA_TRUSTSTORE}]
  --truststore-pass PASS   Java cacerts passphrase  [${JAVA_TRUSTSTORE_PASS}]
  --cert-alias ALIAS       keytool alias  [${CERT_ALIAS}]

Auth options:
  --user USER              htpasswd username  [${DEPOT_USER}]
  --password PASS          htpasswd password  (prompted if omitted)

Disk options:
  --disk DEVICE            Block device to format as web root  [${DATA_DISK}]
  --skip-disk-setup        Skip formatting/mounting (use if already mounted)
  --web-root PATH          Apache document root  [${WEB_ROOT}]

Download tool options:
  --vdt-tgz PATH           Path to vcf-download-tool-*.tar.gz
  --vdt-dir PATH           Extraction directory  [${VDT_DIR}]
  --activation-code PATH   Path to activation-code.txt from Broadcom
  --download-binaries      Run the download tool after setup
  --download-type TYPE     INSTALL | UPGRADE | ALL  [${DOWNLOAD_TYPE}]

  --help                   Show this help

Environment variables:
  Any option can also be set as an env var (e.g. DEPOT_FQDN=... DEPOT_PASS=...).

Examples:
  # Basic setup — prompts for password
  sudo bash ${SCRIPT_NAME} --fqdn vcf91-repo.cmb1.lab --ip 10.0.0.80

  # Full unattended setup including download
  sudo DEPOT_PASS='VMware1!' bash ${SCRIPT_NAME} \\
    --fqdn vcf91-repo.cmb1.lab --ip 10.0.0.80 \\
    --vdt-tgz /root/vcf-download-tool-9.1.0.0.tar.gz \\
    --activation-code /root/activation-code.txt \\
    --download-binaries \\
    --import-cert
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --fqdn)               DEPOT_FQDN="${2:-}"; shift 2 ;;
      --ip)                 DEPOT_IP="${2:-}"; shift 2 ;;
      --vcf-version)        VCF_VERSION="${2:-}"; shift 2 ;;
      --country)            CERT_COUNTRY="${2:-}"; shift 2 ;;
      --state)              CERT_STATE="${2:-}"; shift 2 ;;
      --city)               CERT_CITY="${2:-}"; shift 2 ;;
      --org)                CERT_ORG="${2:-}"; shift 2 ;;
      --ou)                 CERT_OU="${2:-}"; shift 2 ;;
      --existing-cert)      EXISTING_CERT="${2:-}"; shift 2 ;;
      --existing-key)       EXISTING_KEY="${2:-}"; shift 2 ;;
      --import-cert)        IMPORT_CERT_TO_KEYSTORE="true"; shift 1 ;;
      --truststore)         JAVA_TRUSTSTORE="${2:-}"; shift 2 ;;
      --truststore-pass)    JAVA_TRUSTSTORE_PASS="${2:-}"; shift 2 ;;
      --cert-alias)         CERT_ALIAS="${2:-}"; shift 2 ;;
      --user)               DEPOT_USER="${2:-}"; shift 2 ;;
      --password)           DEPOT_PASS="${2:-}"; shift 2 ;;
      --disk)               DATA_DISK="${2:-}"; shift 2 ;;
      --skip-disk-setup)    SKIP_DISK_SETUP="true"; shift 1 ;;
      --web-root)           WEB_ROOT="${2:-}"; shift 2 ;;
      --vdt-tgz)            VDT_TGZ="${2:-}"; shift 2 ;;
      --vdt-dir)            VDT_DIR="${2:-}"; VDT_BIN="${VDT_DIR}/vcf-download-tool"; shift 2 ;;
      --activation-code)    ACTIVATION_CODE_FILE="${2:-}"; shift 2 ;;
      --download-binaries)  DOWNLOAD_BINARIES="true"; shift 1 ;;
      --download-type)      DOWNLOAD_TYPE="${2:-}"; shift 2 ;;
      --help|-h)            usage; exit 0 ;;
      *) die "Unknown argument: $1  (run with --help for usage)" ;;
    esac
  done

  [[ -n "${DEPOT_FQDN}" ]] || die "--fqdn is required"

  if [[ "${DOWNLOAD_BINARIES}" == "true" ]]; then
    [[ -n "${ACTIVATION_CODE_FILE}" ]] || die "--download-binaries requires --activation-code"
    [[ -f "${ACTIVATION_CODE_FILE}" ]] || die "Activation code file not found: ${ACTIVATION_CODE_FILE}"
  fi

  if [[ -n "${EXISTING_CERT}" || -n "${EXISTING_KEY}" ]]; then
    [[ -n "${EXISTING_CERT}" && -n "${EXISTING_KEY}" ]] \
      || die "--existing-cert and --existing-key must both be supplied"
    [[ -f "${EXISTING_CERT}" ]] || die "Certificate not found: ${EXISTING_CERT}"
    [[ -f "${EXISTING_KEY}" ]]  || die "Key not found: ${EXISTING_KEY}"
    CERT_FILE="${EXISTING_CERT}"
    KEY_FILE="${EXISTING_KEY}"
  fi
}

# ---------------------------------------------------------------------------
# Prerequisite checks
# ---------------------------------------------------------------------------
require_root() {
  [[ "${EUID}" -eq 0 ]] || die "This script must be run as root (use sudo)."
}

require_ubuntu() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    if [[ "${ID:-}" != "ubuntu" ]]; then
      warn "This script is designed for Ubuntu. Detected: ${ID:-unknown}. Proceeding anyway."
    fi
  fi
}

# ---------------------------------------------------------------------------
# Step 1 – Install packages
# ---------------------------------------------------------------------------
install_packages() {
  step "Installing required packages"
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    apache2 openssl apache2-utils unzip curl jq
  info "Packages installed: apache2 openssl apache2-utils unzip curl jq"
}

# ---------------------------------------------------------------------------
# Step 2 – Data disk setup
# ---------------------------------------------------------------------------
setup_disk() {
  if [[ "${SKIP_DISK_SETUP}" == "true" ]]; then
    info "Skipping disk setup (--skip-disk-setup)"
    return 0
  fi

  step "Setting up data disk ${DATA_DISK} -> ${WEB_ROOT}"

  [[ -b "${DATA_DISK}" ]] \
    || die "Block device not found: ${DATA_DISK}. Use --skip-disk-setup if already mounted."

  if mount | grep -q "on ${WEB_ROOT} "; then
    warn "${WEB_ROOT} is already mounted — skipping format."
  else
    info "Formatting ${DATA_DISK} as ext4"
    mkfs.ext4 -F "${DATA_DISK}"

    # Add to fstab if not present
    if ! grep -q "^${DATA_DISK}" /etc/fstab; then
      info "Adding ${DATA_DISK} to /etc/fstab"
      echo "${DATA_DISK} ${WEB_ROOT} ext4 defaults 1 1" >> /etc/fstab
    fi

    mkdir -p "${WEB_ROOT}"
    mount -a
    systemctl daemon-reload
  fi

  info "Disk: $(df -h "${WEB_ROOT}" | tail -1)"
}

# ---------------------------------------------------------------------------
# Step 3 – Generate SSL certificate
# ---------------------------------------------------------------------------
generate_certificate() {
  if [[ -n "${EXISTING_CERT}" ]]; then
    info "Using existing certificate: ${EXISTING_CERT}"
    return 0
  fi

  step "Generating SSL certificate for ${DEPOT_FQDN}"
  mkdir -p "${SSL_DIR}"

  local subj="/C=${CERT_COUNTRY}/ST=${CERT_STATE}/L=${CERT_CITY}/O=${CERT_ORG}/OU=${CERT_OU}/CN=${DEPOT_FQDN}"

  # Build SAN extension config
  local san_entries="DNS.1 = ${DEPOT_FQDN}"
  if [[ -n "${DEPOT_IP}" ]]; then
    san_entries+=$'\nIP.1 = '"${DEPOT_IP}"
  fi

  local san_cnf
  san_cnf="$(mktemp)"
  cat > "${san_cnf}" <<EOF
[req]
default_bits       = 2048
prompt             = no
default_md         = sha256
distinguished_name = dn
req_extensions     = v3_req

[dn]
C  = ${CERT_COUNTRY}
ST = ${CERT_STATE}
L  = ${CERT_CITY}
O  = ${CERT_ORG}
OU = ${CERT_OU}
CN = ${DEPOT_FQDN}

[v3_req]
subjectAltName = @alt_names
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth

[alt_names]
${san_entries}
EOF

  info "Generating private key and CSR"
  openssl req -new \
    -newkey rsa:2048 -nodes \
    -keyout "${KEY_FILE}" \
    -out    "${CSR_FILE}" \
    -subj   "${subj}"

  info "Generating self-signed certificate (valid 825 days)"
  openssl x509 -req \
    -days 825 -sha256 \
    -in  "${CSR_FILE}" \
    -signkey "${KEY_FILE}" \
    -out "${CERT_FILE}" \
    -extensions v3_req \
    -extfile "${san_cnf}"

  rm -f "${san_cnf}"

  # Verify key/cert match
  local cert_mod key_mod
  cert_mod="$(openssl x509 -noout -modulus -in "${CERT_FILE}" | md5sum)"
  key_mod="$(openssl rsa  -noout -modulus -in "${KEY_FILE}"  | md5sum)"
  if [[ "${cert_mod}" == "${key_mod}" ]]; then
    info "Certificate/key modulus match verified."
  else
    die "Certificate and key modulus do NOT match — something went wrong."
  fi
}

# ---------------------------------------------------------------------------
# Step 4 – Install certificate into Apache ssl dir
# ---------------------------------------------------------------------------
install_certificate() {
  step "Installing certificate into ${SSL_DIR}"
  mkdir -p "${SSL_DIR}"

  if [[ -n "${EXISTING_CERT}" ]]; then
    cp -v "${EXISTING_CERT}" "${SSL_DIR}/$(basename "${EXISTING_CERT}")"
    cp -v "${EXISTING_KEY}"  "${SSL_DIR}/$(basename "${EXISTING_KEY}")"
    CERT_FILE="${SSL_DIR}/$(basename "${EXISTING_CERT}")"
    KEY_FILE="${SSL_DIR}/$(basename "${EXISTING_KEY}")"
  fi

  chmod 600 "${KEY_FILE}"
  chmod 644 "${CERT_FILE}"
  info "Certificate : ${CERT_FILE}"
  info "Private key : ${KEY_FILE}"
}

# ---------------------------------------------------------------------------
# Step 5 – Configure Apache basic authentication
# ---------------------------------------------------------------------------
configure_auth() {
  step "Configuring Apache basic authentication"

  if [[ -z "${DEPOT_PASS}" ]]; then
    read -rsp "Enter password for depot user '${DEPOT_USER}': " DEPOT_PASS
    echo
    [[ -n "${DEPOT_PASS}" ]] || die "Password cannot be empty."
  fi

  htpasswd -cb "${HTPASSWD_FILE}" "${DEPOT_USER}" "${DEPOT_PASS}"
  chmod 640 "${HTPASSWD_FILE}"
  chown root:www-data "${HTPASSWD_FILE}"
  info "htpasswd file created: ${HTPASSWD_FILE}"
}

# ---------------------------------------------------------------------------
# Step 6 – Configure Apache HTTPS virtual host
# ---------------------------------------------------------------------------
configure_apache() {
  step "Configuring Apache HTTPS virtual host"

  # Enable required modules
  a2enmod ssl headers
  a2ensite default-ssl

  local ssl_conf="/etc/apache2/sites-available/default-ssl.conf"

  # Write the SSL virtual host configuration
  cat > "${ssl_conf}" <<EOF
<IfModule mod_ssl.c>
  <VirtualHost _default_:443>
    ServerName ${DEPOT_FQDN}
    DocumentRoot ${WEB_ROOT}

    SSLEngine on
    SSLCertificateFile    ${CERT_FILE}
    SSLCertificateKeyFile ${KEY_FILE}

    # Modern TLS only
    SSLProtocol           all -SSLv3 -TLSv1 -TLSv1.1
    SSLHonorCipherOrder   off
    Header always set Strict-Transport-Security "max-age=63072000"

    <Directory ${WEB_ROOT}>
      Options Indexes FollowSymLinks
      AllowOverride None
      AuthType Basic
      AuthName "VCF Depot"
      AuthUserFile ${HTPASSWD_FILE}
      Require valid-user
    </Directory>

    ErrorLog  \${APACHE_LOG_DIR}/vcf91-depot-error.log
    CustomLog \${APACHE_LOG_DIR}/vcf91-depot-access.log combined
  </VirtualHost>
</IfModule>
EOF

  apache2ctl configtest
  systemctl enable apache2
  systemctl restart apache2
  info "Apache restarted successfully."
}

# ---------------------------------------------------------------------------
# Step 7 – Import depot cert into Java truststore (optional)
# ---------------------------------------------------------------------------
import_cert_to_keystore() {
  [[ "${IMPORT_CERT_TO_KEYSTORE}" == "true" ]] || return 0
  step "Importing depot certificate into Java truststore"

  local keytool_bin
  keytool_bin="$(command -v keytool 2>/dev/null || true)"
  [[ -n "${keytool_bin}" ]] || die "keytool not found. Install a JRE/JDK first."

  # Remove stale alias if present
  "${keytool_bin}" -delete \
    -alias "${CERT_ALIAS}" \
    -cacerts \
    -storepass "${JAVA_TRUSTSTORE_PASS}" \
    -noprompt 2>/dev/null || true

  "${keytool_bin}" -import \
    -trustcacerts \
    -cacerts \
    -storepass "${JAVA_TRUSTSTORE_PASS}" \
    -alias "${CERT_ALIAS}" \
    -file  "${CERT_FILE}" \
    -noprompt

  info "Certificate imported as alias '${CERT_ALIAS}'"

  # Verify
  "${keytool_bin}" -list \
    -cacerts \
    -storepass "${JAVA_TRUSTSTORE_PASS}" \
    | grep -i "${CERT_ALIAS}" \
    && info "Verification passed." \
    || warn "Alias not found after import — check manually."
}

# ---------------------------------------------------------------------------
# Step 8 – Extract vcf-download-tool
# ---------------------------------------------------------------------------
setup_download_tool() {
  [[ -n "${VDT_TGZ}" ]] || { info "No --vdt-tgz supplied; skipping tool setup."; return 0; }
  [[ -f "${VDT_TGZ}" ]] || die "vcf-download-tool tarball not found: ${VDT_TGZ}"

  step "Extracting vcf-download-tool"
  mkdir -p "${VDT_DIR}"
  tar -zxvf "${VDT_TGZ}" -C "${VDT_DIR}"

  # Locate the binary (may be nested inside a subdirectory)
  local found_bin
  found_bin="$(find "${VDT_DIR}" -type f -name "vcf-download-tool" 2>/dev/null | head -1)"
  [[ -n "${found_bin}" ]] || die "vcf-download-tool binary not found after extraction"
  VDT_BIN="${found_bin}"

  chmod +x "${VDT_BIN}"
  info "vcf-download-tool: $("${VDT_BIN}" -v 2>&1 || echo '(version flag not supported)')"
}

# ---------------------------------------------------------------------------
# Step 9 – Generate depot ID configuration
# ---------------------------------------------------------------------------
generate_depot_id() {
  [[ -f "${VDT_BIN}" ]] || return 0
  step "Generating software depot ID"
  "${VDT_BIN}" configuration generate --software-depot-id \
    || warn "Depot ID generation returned non-zero (may already exist)."
}

# ---------------------------------------------------------------------------
# Step 10 – List available binaries
# ---------------------------------------------------------------------------
list_binaries() {
  [[ "${DOWNLOAD_BINARIES}" == "true" ]] || return 0
  [[ -f "${VDT_BIN}" ]] || return 0

  step "Listing available VCF ${VCF_VERSION} ${DOWNLOAD_TYPE} binaries"
  "${VDT_BIN}" binaries list \
    --sku vcf \
    --vcf-version "${VCF_VERSION}" \
    --depot-download-activation-code-file "${ACTIVATION_CODE_FILE}" \
    --type "${DOWNLOAD_TYPE}" \
    --automated-install \
    || warn "Binary listing returned non-zero — check activation code."
}

# ---------------------------------------------------------------------------
# Step 11 – Download binaries
# ---------------------------------------------------------------------------
download_binaries() {
  [[ "${DOWNLOAD_BINARIES}" == "true" ]] || return 0
  [[ -f "${VDT_BIN}" ]] || die "vcf-download-tool not found. Supply --vdt-tgz."

  step "Downloading VCF ${VCF_VERSION} ${DOWNLOAD_TYPE} binaries -> ${WEB_ROOT}"
  "${VDT_BIN}" binaries download \
    --depot-download-activation-code-file "${ACTIVATION_CODE_FILE}" \
    --vcf-version "${VCF_VERSION}" \
    --depot-store "${WEB_ROOT}" \
    --automated-install \
    --type "${DOWNLOAD_TYPE}"

  info "Download complete. Fixing permissions on ${WEB_ROOT}"
  find "${WEB_ROOT}" -type d -exec chmod 755 {} +
  find "${WEB_ROOT}" -type f -exec chmod 644 {} +
  chown -R www-data:www-data "${WEB_ROOT}"
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print_summary() {
  cat <<EOF

===========================================================================
 VCF 9.1 Offline Depot setup complete  (script v${SCRIPT_VERSION})
===========================================================================

  Depot URL  : https://${DEPOT_FQDN}/PROD
  Certificate: ${CERT_FILE}
  Auth user  : ${DEPOT_USER}
  Web root   : ${WEB_ROOT}

Next steps:
  1. Copy ${CERT_FILE} to the machine running VCF Installer.
  2. Import it into the VCF Installer Java truststore:
       sudo keytool -import -trustcacerts -cacerts \\
         -storepass changeit \\
         -alias ${CERT_ALIAS} \\
         -file <path-to-cert> -noprompt

  3. Verify:
       keytool -list -cacerts -storepass changeit | grep -i ${CERT_ALIAS}

  4. In VCF Installer -> Administration -> Depot Settings, set:
       URL      : https://${DEPOT_FQDN}
       Username : ${DEPOT_USER}
       Password : <your password>

  5. If binaries were not downloaded now, run later:
       ${VDT_BIN} binaries download \\
         --depot-download-activation-code-file <activation-code.txt> \\
         --vcf-version ${VCF_VERSION} \\
         --depot-store ${WEB_ROOT} \\
         --automated-install \\
         --type ${DOWNLOAD_TYPE}

NOTE: If you see "invalid credentials" when adding the depot in VCF Installer,
the depot certificate has NOT been imported into the Java truststore — that
error message is misleading. Import the cert and try again.

EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  require_root
  require_ubuntu
  parse_args "$@"

  info "VCF 9.1 Offline Depot Setup  v${SCRIPT_VERSION}"
  info "Target FQDN : ${DEPOT_FQDN}"
  info "VCF version : ${VCF_VERSION}"

  install_packages
  setup_disk
  generate_certificate
  install_certificate
  configure_auth
  configure_apache
  import_cert_to_keystore
  setup_download_tool
  generate_depot_id
  list_binaries
  download_binaries
  print_summary
}

main "$@"
