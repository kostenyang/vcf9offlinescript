#!/usr/bin/env bash
set -euo pipefail

# ===========================================================================
# create_vcf9_depot_server_v4_nginx.sh — VCF 9.1 Offline Depot (nginx)
#
# HTTPS + Basic Auth, nginx web server
# Supports VCF 9.1 activation-code based download and legacy token-file.
#
# Reference:
#   https://vstellar.com/2026/05/vcf-9-1-home-lab-series-part-4-vcf-offline-depo/
#
# Differences from v1/v2 (9.0.x nginx):
#   - Default VCF version bumped to 9.1.0.0
#   - Supports --activation-code (vcf-download-tool 9.1 API)
#   - Generates software depot ID before download
#   - Lists available binaries before downloading
#   - Generates configure-vcf-installer-depot helpers (bash + PowerShell)
#   - import_ca() auto-runs after cert creation when --import-ca is set
#
# Compatible with:
#   import_vcf9depot_ca.sh  — CA import (system + Java truststore)
# ===========================================================================

SCRIPT_NAME="$(basename "$0")"
SCRIPT_VERSION="4.1.0"
VCF_VERSION="9.1.0.0"
DEPOT_ROOT="/opt/vcf-depot"
DEPOT_NAME="vcf9"
WEB_ROOT="/var/www/html"
NGINX_CONF="/etc/nginx/conf.d/vcf9-depot.conf"
AUTH_FILE="/etc/nginx/.htpasswd-vcf9"
CERT_DIR="/etc/nginx/vcf9-certs"
CERT_FILE="${CERT_DIR}/vcf9-depot.crt"
KEY_FILE="${CERT_DIR}/vcf9-depot.key"
DEPOT_USER="vcfdepot"
DEPOT_PASS="VMware1!VMware1!"
DEPOT_FQDN="vcf91-depot.home.lab"
DEPOT_IP=""
DEPOT_PORT="443"
DEPOT_HTTP_PORT="80"

# Download tool — supports both 9.0 token-file and 9.1 activation-code
TOKEN_FILE=""
TOKEN_VALUE=""
ACTIVATION_CODE_FILE=""
DOWNLOAD_TYPE="INSTALL"           # INSTALL | UPGRADE | ALL

VCF_DOWNLOAD_TOOL_TGZ=""
AUTO_EXTRACT_TOOL="true"
DOWNLOAD_BINARIES="false"
OPEN_FIREWALL="true"
IMPORT_CA="false"
CA_URL=""

# Data disk (optional — formats and mounts a block device as the web root)
# Set DATA_DISK to a device like /dev/sdb, or leave empty to skip.
# On a fresh Ubuntu VM add a 500 GB+ disk and pass --data-disk /dev/sdb.
DATA_DISK=""
SKIP_DISK_SETUP="false"

WEB_USER=""

# ---------------------------------------------------------------------------
green()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$*"; }
red()    { printf '\033[0;31m%s\033[0m\n' "$*" >&2; }
info()   { green   "[INFO] $*"; }
warn()   { yellow  "[WARN] $*"; }
die()    { red     "[ERROR] $*"; exit 1; }

# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} --fqdn depot.example.lab --ip 10.0.0.50 [options]

Sets up a VCF 9.1 offline depot server using nginx + HTTPS + basic auth.
Equivalent to v1/v2 (VCF 9.0.x) but updated for VCF 9.1.0.0.

Required:
  --fqdn FQDN                  FQDN used by VCF to access the depot
  --ip IP                      IPv4 address used by the depot server

Depot options:
  --vcf-version VERSION        VCF version. Default: ${VCF_VERSION}
  --depot-root PATH            Depot data root. Default: ${DEPOT_ROOT}
  --depot-name NAME            URL path under web root. Default: ${DEPOT_NAME}
  --port PORT                  HTTPS port. Default: ${DEPOT_PORT}
  --http-port PORT             HTTP redirect port. Default: ${DEPOT_HTTP_PORT}
  --user USER                  Basic auth username. Default: ${DEPOT_USER}
  --password PASS              Basic auth password. Default: ${DEPOT_PASS}

Download tool options:
  --activation-code PATH       activation-code.txt from Broadcom (VCF 9.1)
  --token-file PATH            Download token file (VCF 9.0 legacy)
  --download-tool-tgz PATH     Path to vcf-download-tool-*.tar.gz
  --download-binaries          Run vcf-download-tool after setup
  --download-type TYPE         INSTALL | UPGRADE | ALL. Default: ${DOWNLOAD_TYPE}
  --skip-tool-extract          Do not extract the tool tarball

CA / certificate options:
  --import-ca                  Import depot cert into system + Java truststores
                               (calls import_vcf9depot_ca.sh; also installs JRE on Ubuntu)
  --ca-url URL                 Fetch CA from URL instead of using generated cert

Data disk options (Ubuntu fresh install with a separate data disk):
  --data-disk DEVICE           Block device to format (ext4) and mount as web root
                               e.g. --data-disk /dev/sdb  (article uses 500 GB+)
  --skip-disk-setup            Skip format/mount (disk already prepared)

Misc:
  --skip-firewall              Do not open the firewall port(s)
  --help                       Show this help

Examples:
  sudo bash ${SCRIPT_NAME} --fqdn depot.home.lab --ip 10.0.0.80

  sudo bash ${SCRIPT_NAME} \\
    --fqdn vcf91-depot.lab --ip 10.0.0.80 \\
    --activation-code /root/activation-code.txt \\
    --download-tool-tgz /root/vcf-download-tool-9.1.0.0.tar.gz \\
    --download-binaries \\
    --import-ca
EOF
}

# ---------------------------------------------------------------------------
require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Run this script as root."
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --vcf-version)        VCF_VERSION="${2:-}";          shift 2 ;;
      --fqdn)               DEPOT_FQDN="${2:-}";           shift 2 ;;
      --ip)                 DEPOT_IP="${2:-}";             shift 2 ;;
      --depot-root)         DEPOT_ROOT="${2:-}";           shift 2 ;;
      --depot-name)         DEPOT_NAME="${2:-}";           shift 2 ;;
      --port)               DEPOT_PORT="${2:-}";           shift 2 ;;
      --http-port)          DEPOT_HTTP_PORT="${2:-}";      shift 2 ;;
      --user)               DEPOT_USER="${2:-}";           shift 2 ;;
      --password)           DEPOT_PASS="${2:-}";           shift 2 ;;
      --activation-code)    ACTIVATION_CODE_FILE="${2:-}"; shift 2 ;;
      --token-file)         TOKEN_FILE="${2:-}";           shift 2 ;;
      --download-tool-tgz)  VCF_DOWNLOAD_TOOL_TGZ="${2:-}"; shift 2 ;;
      --download-binaries)  DOWNLOAD_BINARIES="true";      shift 1 ;;
      --download-type)      DOWNLOAD_TYPE="${2:-}";        shift 2 ;;
      --skip-tool-extract)  AUTO_EXTRACT_TOOL="false";     shift 1 ;;
      --import-ca)          IMPORT_CA="true";              shift 1 ;;
      --ca-url)             CA_URL="${2:-}";               shift 2 ;;
      --data-disk)          DATA_DISK="${2:-}";            shift 2 ;;
      --skip-disk-setup)    SKIP_DISK_SETUP="true";        shift 1 ;;
      --skip-firewall)      OPEN_FIREWALL="false";         shift 1 ;;
      --help|-h)            usage; exit 0 ;;
      *) die "Unknown argument: $1  (run with --help)" ;;
    esac
  done

  [[ -n "${DEPOT_FQDN}" ]] || die "--fqdn is required"
  [[ -n "${DEPOT_IP}" ]]   || die "--ip is required"

  if [[ "${DOWNLOAD_BINARIES}" == "true" ]]; then
    [[ -n "${ACTIVATION_CODE_FILE}" || -n "${TOKEN_FILE}" || -n "${TOKEN_VALUE}" ]] \
      || die "--download-binaries requires --activation-code or --token-file"
    if [[ -n "${ACTIVATION_CODE_FILE}" ]]; then
      [[ -f "${ACTIVATION_CODE_FILE}" ]] || die "Activation code file not found: ${ACTIVATION_CODE_FILE}"
    fi
  fi
}

# ---------------------------------------------------------------------------
detect_web_user() {
  if command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
    WEB_USER="nginx"
  elif command -v apt-get >/dev/null 2>&1; then
    WEB_USER="www-data"
  else
    WEB_USER="nginx"
    warn "Could not detect web user; defaulting to 'nginx'."
  fi
  info "Web user: ${WEB_USER}"
}

detect_pkg_mgr() {
  if command -v dnf >/dev/null 2>&1; then
    echo "dnf"
  elif command -v yum >/dev/null 2>&1; then
    echo "yum"
  elif command -v apt-get >/dev/null 2>&1; then
    echo "apt"
  else
    die "Unsupported OS: no dnf/yum/apt-get found"
  fi
}

# ---------------------------------------------------------------------------
install_packages() {
  local pkg_mgr
  pkg_mgr="$(detect_pkg_mgr)"
  info "Installing packages via ${pkg_mgr}"
  case "${pkg_mgr}" in
    dnf|yum)
      local pkgs="nginx httpd-tools openssl jq tar curl"
      [[ -f /etc/redhat-release ]] && pkgs+=" policycoreutils-python-utils"
      # keytool for Java truststore import (only when --import-ca is set)
      [[ "${IMPORT_CA}" == "true" ]] && pkgs+=" java-11-openjdk-headless"
      "${pkg_mgr}" install -y ${pkgs}
      ;;
    apt)
      apt-get update -y
      # ca-certificates: provides update-ca-certificates (usually pre-installed)
      # default-jre-headless: provides keytool, needed for Java truststore import
      local pkgs="nginx apache2-utils openssl jq tar curl ca-certificates"
      [[ "${IMPORT_CA}" == "true" ]] && pkgs+=" default-jre-headless"
      DEBIAN_FRONTEND=noninteractive apt-get install -y ${pkgs}
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Data disk setup (optional — formats a block device and mounts as web root)
# Use on a fresh Ubuntu VM where /var/www/html should live on a separate disk.
# Article recommends 500 GB+. Pass --data-disk /dev/sdb to enable.
setup_data_disk() {
  if [[ "${SKIP_DISK_SETUP}" == "true" ]]; then
    info "Skipping data disk setup (--skip-disk-setup)"
    return 0
  fi
  [[ -n "${DATA_DISK}" ]] || return 0   # no disk configured — skip silently

  [[ -b "${DATA_DISK}" ]] \
    || die "Block device not found: ${DATA_DISK}  (use --skip-disk-setup if already mounted)"

  if mount | grep -q " on ${WEB_ROOT} "; then
    warn "${WEB_ROOT} is already mounted — skipping format/mount."
    return 0
  fi

  info "Formatting ${DATA_DISK} as ext4 and mounting to ${WEB_ROOT}"
  mkfs.ext4 -F "${DATA_DISK}"
  mkdir -p "${WEB_ROOT}"

  if ! grep -q "^${DATA_DISK}[[:space:]]" /etc/fstab; then
    info "Adding ${DATA_DISK} to /etc/fstab"
    echo "${DATA_DISK} ${WEB_ROOT} ext4 defaults 1 1" >> /etc/fstab
  fi

  mount -a
  systemctl daemon-reload
  info "Data disk ready: $(df -h "${WEB_ROOT}" | tail -1)"
}

# ---------------------------------------------------------------------------
create_depot_tree() {
  local depot_data_root="${DEPOT_ROOT}/${DEPOT_NAME}"
  info "Creating depot directory tree at ${depot_data_root}"

  # Ensure web root exists (nginx package creates it, but be defensive)
  mkdir -p "${WEB_ROOT}"

  mkdir -p "${depot_data_root}/PROD/COMP/ESX_HOST"
  mkdir -p "${depot_data_root}/PROD/COMP/NSX_T_MANAGER"
  mkdir -p "${depot_data_root}/PROD/COMP/SDDC_MANAGER_VCF/Compatibility"
  mkdir -p "${depot_data_root}/PROD/COMP/VCENTER"
  mkdir -p "${depot_data_root}/PROD/COMP/VCF_OPS_CLOUD_PROXY"
  mkdir -p "${depot_data_root}/PROD/COMP/VRA"
  mkdir -p "${depot_data_root}/PROD/COMP/VROPS"
  mkdir -p "${depot_data_root}/PROD/COMP/VRSLCM"
  mkdir -p "${depot_data_root}/PROD/metadata/manifest/v1"
  mkdir -p "${depot_data_root}/PROD/metadata/productVersionCatalog/v1"
  mkdir -p "${depot_data_root}/PROD/vsan/hcl"

  ln -sfn "${depot_data_root}/PROD" "${WEB_ROOT}/PROD"

  chown -R "${WEB_USER}:${WEB_USER}" "${depot_data_root}"
  find "${depot_data_root}" -type d -exec chmod 0500 {} +
  find "${depot_data_root}" -type f -exec chmod 0400 {} +
}

# ---------------------------------------------------------------------------
create_certificate() {
  info "Generating self-signed certificate: CN=${DEPOT_FQDN}"
  mkdir -p "${CERT_DIR}"

  local san_cfg
  san_cfg="$(mktemp)"
  cat > "${san_cfg}" <<EOF
[req]
default_bits       = 4096
prompt             = no
default_md         = sha256
x509_extensions    = v3_req
distinguished_name = dn

[dn]
CN = ${DEPOT_FQDN}

[v3_req]
subjectAltName = @alt_names
basicConstraints = critical, CA:TRUE
keyUsage = critical, digitalSignature, keyEncipherment, keyCertSign, cRLSign
extendedKeyUsage = serverAuth

[alt_names]
DNS.1 = ${DEPOT_FQDN}
IP.1  = ${DEPOT_IP}
EOF

  openssl req -x509 -nodes -days 825 \
    -newkey rsa:4096 \
    -keyout "${KEY_FILE}" \
    -out    "${CERT_FILE}" \
    -config "${san_cfg}"

  chmod 0400 "${KEY_FILE}"
  chmod 0444 "${CERT_FILE}"
  chown root:root "${KEY_FILE}" "${CERT_FILE}"
  rm -f "${san_cfg}"
  info "Certificate: ${CERT_FILE}"
}

# ---------------------------------------------------------------------------
create_auth() {
  info "Creating nginx basic auth file"
  mkdir -p "$(dirname "${AUTH_FILE}")"
  htpasswd -bc "${AUTH_FILE}" "${DEPOT_USER}" "${DEPOT_PASS}"
  chown "${WEB_USER}:${WEB_USER}" "${AUTH_FILE}"
  chmod 0400 "${AUTH_FILE}"
}

# ---------------------------------------------------------------------------
configure_nginx() {
  info "Writing nginx configuration"

  # Remove Ubuntu default site to prevent conflicts
  rm -f /etc/nginx/sites-enabled/default /etc/nginx/conf.d/default.conf 2>/dev/null || true

  cat > "${NGINX_CONF}" <<EOF
# VCF 9.1 Offline Depot — nginx (HTTPS + basic auth)
server {
    listen ${DEPOT_PORT} ssl default_server;
    server_name ${DEPOT_FQDN};

    ssl_certificate     ${CERT_FILE};
    ssl_certificate_key ${KEY_FILE};
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;

    auth_basic "VCF9 Offline Depot";
    auth_basic_user_file ${AUTH_FILE};

    root ${WEB_ROOT};
    autoindex on;
    client_max_body_size 0;

    location /PROD/ {
        alias ${DEPOT_ROOT}/${DEPOT_NAME}/PROD/;
        autoindex on;
    }
}

# HTTP -> HTTPS redirect
server {
    listen ${DEPOT_HTTP_PORT};
    server_name ${DEPOT_FQDN};
    return 301 https://\$host\$request_uri;
}
EOF

  nginx -t
  systemctl enable --now nginx
}

# ---------------------------------------------------------------------------
configure_selinux() {
  [[ -f /etc/redhat-release ]] || return 0
  command -v getenforce >/dev/null 2>&1 || return 0
  [[ "$(getenforce)" == "Enforcing" ]] || return 0

  info "SELinux enforcing — setting httpd_sys_content_t on depot path"
  if command -v semanage >/dev/null 2>&1; then
    semanage fcontext -a -t httpd_sys_content_t "${DEPOT_ROOT}/${DEPOT_NAME}(/.*)?" || true
    restorecon -Rv "${DEPOT_ROOT}/${DEPOT_NAME}"
    semanage port -a -t http_port_t -p tcp "${DEPOT_PORT}" 2>/dev/null \
      || semanage port -m -t http_port_t -p tcp "${DEPOT_PORT}" 2>/dev/null || true
  else
    warn "semanage not found; skip SELinux context. Install policycoreutils-python-utils."
  fi
}

# ---------------------------------------------------------------------------
configure_firewall() {
  [[ "${OPEN_FIREWALL}" == "true" ]] || return 0

  # firewalld — RHEL / CentOS / Rocky / AlmaLinux
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
    info "firewalld: opening TCP/${DEPOT_PORT} (HTTPS) and TCP/${DEPOT_HTTP_PORT} (HTTP)"
    firewall-cmd --permanent --add-port="${DEPOT_PORT}/tcp"
    firewall-cmd --permanent --add-port="${DEPOT_HTTP_PORT}/tcp"
    firewall-cmd --reload

  # ufw — Ubuntu / Debian (default on Ubuntu 24.04)
  elif command -v ufw >/dev/null 2>&1; then
    if ufw status 2>/dev/null | grep -q "^Status: active"; then
      info "ufw: allowing TCP/${DEPOT_PORT} (HTTPS) and TCP/${DEPOT_HTTP_PORT} (HTTP)"
      ufw allow "${DEPOT_PORT}/tcp"
      ufw allow "${DEPOT_HTTP_PORT}/tcp"
    else
      warn "ufw is installed but NOT active. Rules not applied."
      warn "To enable: sudo ufw enable && sudo ufw allow ${DEPOT_PORT}/tcp && sudo ufw allow ${DEPOT_HTTP_PORT}/tcp"
    fi

  else
    warn "No firewall manager found (firewalld / ufw)."
    warn "If needed, open TCP/${DEPOT_PORT} and TCP/${DEPOT_HTTP_PORT} manually."
  fi
}

# ---------------------------------------------------------------------------
import_ca() {
  [[ "${IMPORT_CA}" == "true" ]] || return 0
  info "Importing depot CA into system + Java truststores"
  local importer
  importer="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/import_vcf9depot_ca.sh"
  if [[ -x "${importer}" ]]; then
    if [[ -n "${CA_URL}" ]]; then
      "${importer}" --url-insecure "${CA_URL}"
    else
      "${importer}" --cert "${CERT_FILE}"
    fi
  else
    warn "import_vcf9depot_ca.sh not found at ${importer}; run it manually:\n  sudo ${importer} --cert ${CERT_FILE}"
  fi
}

# ---------------------------------------------------------------------------
extract_download_tool() {
  [[ "${AUTO_EXTRACT_TOOL}" == "true" ]] || return 0
  [[ -n "${VCF_DOWNLOAD_TOOL_TGZ}" ]]    || return 0
  [[ -f "${VCF_DOWNLOAD_TOOL_TGZ}" ]]    || { warn "Tool tarball not found: ${VCF_DOWNLOAD_TOOL_TGZ} (skip)"; return 0; }

  local extract_root="${DEPOT_ROOT}/tools"
  info "Extracting vcf-download-tool to ${extract_root}"
  mkdir -p "${extract_root}"
  tar -xzf "${VCF_DOWNLOAD_TOOL_TGZ}" -C "${extract_root}"
}

find_download_tool_bin() {
  find "${DEPOT_ROOT}/tools" -type f -name "vcf-download-tool" 2>/dev/null | head -n 1
}

# ---------------------------------------------------------------------------
generate_depot_id() {
  local tool_bin
  tool_bin="$(find_download_tool_bin || true)"
  [[ -n "${tool_bin}" && -x "${tool_bin}" ]] || return 0
  info "Generating software depot ID"
  "${tool_bin}" configuration generate --software-depot-id || true
}

# ---------------------------------------------------------------------------
# Determine which credential arg to pass to vcf-download-tool:
#   VCF 9.1 prefers --depot-download-activation-code-file
#   VCF 9.0 used   --depot-download-token-file
_credential_args() {
  if [[ -n "${ACTIVATION_CODE_FILE}" ]]; then
    echo "--depot-download-activation-code-file ${ACTIVATION_CODE_FILE}"
  elif [[ -n "${TOKEN_FILE}" ]]; then
    echo "--depot-download-token-file ${TOKEN_FILE}"
  else
    echo ""
  fi
}

# ---------------------------------------------------------------------------
create_helper_script() {
  local helper="${DEPOT_ROOT}/download-vcf9-binaries.sh"
  local tool_bin
  tool_bin="$(find_download_tool_bin || true)"

  info "Creating download helper: ${helper}"
  cat > "${helper}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
# Auto-generated by ${SCRIPT_NAME} v${SCRIPT_VERSION}

VCF_VERSION="${VCF_VERSION}"
DEPOT_STORE="${DEPOT_ROOT}/${DEPOT_NAME}"
ACTIVATION_CODE_FILE="${ACTIVATION_CODE_FILE}"
TOKEN_FILE="${TOKEN_FILE}"
TOKEN_VALUE="${TOKEN_VALUE}"
DOWNLOAD_TYPE="${DOWNLOAD_TYPE}"
TOOL_BIN="${tool_bin}"

[[ -x "\${TOOL_BIN}" ]] || { echo "vcf-download-tool not found: \${TOOL_BIN}" >&2; exit 1; }

if [[ -n "\${ACTIVATION_CODE_FILE}" && -f "\${ACTIVATION_CODE_FILE}" ]]; then
  CRED_ARGS="--depot-download-activation-code-file \${ACTIVATION_CODE_FILE}"
elif [[ -n "\${TOKEN_FILE}" && -f "\${TOKEN_FILE}" ]]; then
  CRED_ARGS="--depot-download-token-file \${TOKEN_FILE}"
elif [[ -n "\${TOKEN_VALUE}" ]]; then
  TOKEN_FILE="/tmp/vcf-dl-token.txt"
  printf '%s\n' "\${TOKEN_VALUE}" > "\${TOKEN_FILE}"
  CRED_ARGS="--depot-download-token-file \${TOKEN_FILE}"
else
  echo "No credential source found. Set ACTIVATION_CODE_FILE or TOKEN_FILE." >&2
  exit 1
fi

"\${TOOL_BIN}" binaries download \${CRED_ARGS} \\
  --vcf-version "\${VCF_VERSION}" \\
  --automated-install \\
  --depot-store "\${DEPOT_STORE}" \\
  --type "\${DOWNLOAD_TYPE}"
EOF
  chmod +x "${helper}"
}

# ---------------------------------------------------------------------------
run_download_if_requested() {
  [[ "${DOWNLOAD_BINARIES}" == "true" ]] || return 0
  local helper="${DEPOT_ROOT}/download-vcf9-binaries.sh"
  [[ -x "${helper}" ]] || die "Helper missing: ${helper}"
  info "Downloading VCF ${VCF_VERSION} ${DOWNLOAD_TYPE} binaries"
  "${helper}"
}

# ---------------------------------------------------------------------------
print_summary() {
  local depot_url="https://${DEPOT_FQDN}:${DEPOT_PORT}"
  cat <<EOF

[DONE] VCF 9.1 nginx offline depot ready  (v${SCRIPT_VERSION})

  Depot URL  : ${depot_url}
  Certificate: ${CERT_FILE}
  Auth user  : ${DEPOT_USER}
  Auth pass  : ${DEPOT_PASS}
  Download   : ${DEPOT_ROOT}/download-vcf9-binaries.sh

Next steps:
  1. Import ${CERT_FILE} into VCF Installer / SDDC Manager truststore:
       sudo ./import_vcf9depot_ca.sh --cert ${CERT_FILE}
     OR fetch from server (run on SDDC Manager host):
       sudo ./import_vcf9depot_ca.sh --url-insecure https://${DEPOT_FQDN}:${DEPOT_PORT}

  2. In VCF Installer -> Administration -> Depot Settings:
       URL      : ${depot_url}
       Username : ${DEPOT_USER}
       Password : ${DEPOT_PASS}

  NOTE: If you see "invalid credentials" but creds are correct, the depot cert
        has NOT been imported into the Java truststore — that error is misleading.
EOF
}

# ---------------------------------------------------------------------------
main() {
  require_root
  parse_args "$@"
  info "VCF 9.1 Offline Depot (nginx) — v${SCRIPT_VERSION}"

  install_packages
  setup_data_disk
  detect_web_user
  create_depot_tree
  create_certificate
  create_auth
  configure_nginx
  configure_selinux
  configure_firewall
  import_ca
  extract_download_tool
  generate_depot_id
  create_helper_script
  run_download_if_requested
  print_summary
}

main "$@"
