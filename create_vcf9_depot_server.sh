#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
VCF_VERSION="9.0.2"
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
DEPOT_FQDN="vcf9depotserver.home.lab"
DEPOT_IP="10.0.0.61"
DEPOT_PORT="443"
TOKEN_FILE=""
TOKEN_VALUE=""
VCF_DOWNLOAD_TOOL_TGZ="/root/vcf-download-tool-9.0.2.0.25151284.tar.gz"
AUTO_EXTRACT_TOOL="true"
DOWNLOAD_BINARIES="false"
OPEN_FIREWALL="true"
IMPORT_CA="false"
CA_URL=""

# web user will be detected (e.g., www-data or nginx)
WEB_USER=""

green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$*"; }
red() { printf '\033[0;31m%s\033[0m\n' "$*" >&2; }
info() { green "[INFO] $*"; }
warn() { yellow "[WARN] $*"; }
die() { red "[ERROR] $*"; exit 1; }

usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} --fqdn depot.example.lab --ip 10.0.0.50 [options]

Required:
  --fqdn FQDN                  FQDN used by VCF to access the depot
  --ip IP                      IPv4 address used by the depot server

Optional:
  --depot-root PATH            Depot data root. Default: ${DEPOT_ROOT}
  --depot-name NAME            URL path name under web root. Default: ${DEPOT_NAME}
  --port PORT                  HTTPS port. Default: ${DEPOT_PORT}
  --user USER                  Basic auth username. Default: ${DEPOT_USER}
  --password PASS              Basic auth password. Default: ${DEPOT_PASS}
  --token-file PATH            Broadcom download token file for vcf-download-tool
  --download-tool-tgz PATH     Path to vcf-download-tool-*.tar.gz
  --download-binaries          Run vcf-download-tool after setup
  --skip-tool-extract          Do not extract the tool tarball
  --skip-firewall              Do not open the firewall port
  --help                       Show this help

Example:
  sudo bash ${SCRIPT_NAME} \\
    --fqdn depot.home.lab \\
    --ip 10.0.0.60 \\
    --token-file /root/token.txt \\
    --download-tool-tgz /root/vcf-download-tool-9.0.0.0.24703747.tar.gz \\
    --download-binaries
EOF
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Run this script as root."
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --fqdn) DEPOT_FQDN="${2:-}"; shift 2 ;;
      --ip) DEPOT_IP="${2:-}"; shift 2 ;;
      --depot-root) DEPOT_ROOT="${2:-}"; shift 2 ;;
      --depot-name) DEPOT_NAME="${2:-}"; shift 2 ;;
      --port) DEPOT_PORT="${2:-}"; shift 2 ;;
      --user) DEPOT_USER="${2:-}"; shift 2 ;;
      --password) DEPOT_PASS="${2:-}"; shift 2 ;;
      --token-file) TOKEN_FILE="${2:-}"; shift 2 ;;
      --download-tool-tgz) VCF_DOWNLOAD_TOOL_TGZ="${2:-}"; shift 2 ;;
      --download-binaries) DOWNLOAD_BINARIES="true"; shift 1 ;;
      --import-ca) IMPORT_CA="true"; shift 1 ;;
      --ca-url) CA_URL="${2:-}"; shift 2 ;;
      --skip-tool-extract) AUTO_EXTRACT_TOOL="false"; shift 1 ;;
      --skip-firewall) OPEN_FIREWALL="false"; shift 1 ;;
      --help|-h) usage; exit 0 ;;
      *) die "Unknown argument: $1" ;;
    esac
  done

  [[ -n "${DEPOT_FQDN}" ]] || die "--fqdn is required"
  [[ -n "${DEPOT_IP}" ]] || die "--ip is required"
}

import_ca() {
  [[ "${IMPORT_CA}" == "true" ]] || return 0
  info "Attempting to import depot CA into system and Java truststores"
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
  IMPORTER="${SCRIPT_DIR}/import_vcf9depot_ca.sh"
  if [[ -x "${IMPORTER}" ]]; then
    if [[ -n "${CA_URL}" ]]; then
      info "Using importer to fetch and import CA from ${CA_URL}"
      "${IMPORTER}" --url-insecure "${CA_URL}"
    else
      info "Using importer to import generated cert ${CERT_FILE}"
      "${IMPORTER}" --cert "${CERT_FILE}"
    fi
  else
    warn "Importer script not found at ${IMPORTER}; skipping automatic CA import.\nPlace import_vcf9depot_ca.sh alongside this script or run it manually."
  fi
}

detect_web_user() {
  if command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
    # RHEL-based systems (CentOS, Rocky, etc.)
    WEB_USER="nginx"
  elif command -v apt-get >/dev/null 2>&1; then
    # Debian-based systems (Ubuntu, etc.)
    WEB_USER="www-data"
  else
    # Fallback, but should be caught by package manager detection
    WEB_USER="nginx"
    warn "Could not reliably detect web user, defaulting to 'nginx'. You may need to adjust ownership manually."
  fi
  info "Detected web user as '${WEB_USER}'"
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

install_packages() {
  local pkg_mgr
  pkg_mgr="$(detect_pkg_mgr)"
  info "Installing required packages using ${pkg_mgr}"

  case "${pkg_mgr}" in
    dnf|yum)
      # policycoreutils-python-utils provides semanage for SELinux contexts
      local packages_to_install="nginx httpd-tools openssl jq tar"
      if [[ -f /etc/redhat-release ]]; then
        packages_to_install+=" policycoreutils-python-utils"
      fi
      "${pkg_mgr}" install -y ${packages_to_install}
      ;;
    apt)
      apt-get update -y
      DEBIAN_FRONTEND=noninteractive apt-get install -y nginx apache2-utils openssl jq tar
      ;;
  esac
}

create_depot_tree() {
  local depot_data_root="${DEPOT_ROOT}/${DEPOT_NAME}"
  info "Creating VCF9 offline depot directory structure at ${depot_data_root}"

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

  # Set ownership and strict permissions recommended by Broadcom article:
  # - Owner: web user (apache/www-data/nginx)
  # - Dirs: 0500 (owner traverse/list)
  # - Files: 0400 (owner read-only)
  info "Setting ownership to ${WEB_USER} and permissions for ${depot_data_root}"
  chown -R "${WEB_USER}:${WEB_USER}" "${depot_data_root}"
  find "${depot_data_root}" -type d -exec chmod 0500 {} +
  find "${depot_data_root}" -type f -exec chmod 0400 {} +
}

create_certificate() {
  info "Creating HTTPS certificate with CN=${DEPOT_FQDN} and SAN DNS/IP entries"
  mkdir -p "${CERT_DIR}"

  local san_cfg
  san_cfg="$(mktemp)"
  cat > "${san_cfg}" <<EOF
[req]
default_bits = 4096
prompt = no
default_md = sha256
x509_extensions = v3_req
distinguished_name = dn

[dn]
CN = ${DEPOT_FQDN}

[v3_req]
subjectAltName = @alt_names
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth

[alt_names]
DNS.1 = ${DEPOT_FQDN}
IP.1 = ${DEPOT_IP}
EOF

  openssl req -x509 -nodes -days 825 \
    -newkey rsa:4096 \
    -keyout "${KEY_FILE}" \
    -out "${CERT_FILE}" \
    -config "${san_cfg}"

  # Lock down key and cert per guidance
  chmod 0400 "${KEY_FILE}" || true
  chmod 0400 "${CERT_FILE}" || true
  chown root:root "${KEY_FILE}" || true
  chown root:root "${CERT_FILE}" || true
  rm -f "${san_cfg}"
}

create_auth() {
  info "Creating basic auth file for nginx"
  mkdir -p "$(dirname "${AUTH_FILE}")"
  htpasswd -bc "${AUTH_FILE}" "${DEPOT_USER}" "${DEPOT_PASS}"
  # .htpasswd should be owned by the http daemon user and be readable only by it
  chown "${WEB_USER}:${WEB_USER}" "${AUTH_FILE}"
  chmod 0400 "${AUTH_FILE}"
}

configure_nginx() {
  info "Configuring nginx for the offline depot"
  mkdir -p /etc/nginx/conf.d
  cat > "${NGINX_CONF}" <<EOF
server {
    listen ${DEPOT_PORT} ssl;
    server_name ${DEPOT_FQDN};

    ssl_certificate ${CERT_FILE};
    ssl_certificate_key ${KEY_FILE};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;

    auth_basic "VCF9 Offline Depot";
    auth_basic_user_file ${AUTH_FILE};

    root ${WEB_ROOT};
    autoindex on;
    client_max_body_size 0;

    # Serve the official depot structure at /PROD/ so SDDC Manager can use /PROD
    location /PROD/ {
      alias ${DEPOT_ROOT}/${DEPOT_NAME}/PROD/;
      autoindex on;
    }
}
EOF

  nginx -t
  systemctl enable --now nginx
}

configure_selinux() {
  # Check if on a RHEL-based system and SELinux is enforcing
  if [[ -f /etc/redhat-release ]] && command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce)" == "Enforcing" ]]; then
    info "SELinux is enforcing. Applying httpd_sys_content_t context to depot."
    if command -v semanage >/dev/null 2>&1; then
      local depot_path_selinux="${DEPOT_ROOT}/${DEPOT_NAME}"
      # Allow nginx to read files in the depot directory
      semanage fcontext -a -t httpd_sys_content_t "${depot_path_selinux}(/.*)?"
      restorecon -Rv "${depot_path_selinux}"
    else
      warn "semanage command not found. Could not configure SELinux contexts automatically. This may cause 500 errors. Please install policycoreutils-python-utils and run the semanage/restorecon commands manually."
    fi
  fi
}

configure_firewall() {
  [[ "${OPEN_FIREWALL}" == "true" ]] || return 0
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    info "Opening firewall for TCP/${DEPOT_PORT}"
    firewall-cmd --permanent --add-port="${DEPOT_PORT}/tcp"
    firewall-cmd --reload
  else
    warn "firewalld not active; skip firewall configuration"
  fi
}

extract_download_tool() {
  [[ "${AUTO_EXTRACT_TOOL}" == "true" ]] || return 0
  [[ -n "${VCF_DOWNLOAD_TOOL_TGZ}" ]] || return 0
  [[ -f "${VCF_DOWNLOAD_TOOL_TGZ}" ]] || die "Tool tarball not found: ${VCF_DOWNLOAD_TOOL_TGZ}"

  local extract_root="${DEPOT_ROOT}/tools"
  info "Extracting vcf-download-tool to ${extract_root}"
  mkdir -p "${extract_root}"
  tar -xzf "${VCF_DOWNLOAD_TOOL_TGZ}" -C "${extract_root}"
}

find_download_tool_bin() {
  local extract_root="${DEPOT_ROOT}/tools"
  find "${extract_root}" -type f -name "vcf-download-tool" 2>/dev/null | head -n 1
}

create_helper_script() {
  local helper="${DEPOT_ROOT}/download-vcf9-binaries.sh"
  local tool_bin=""
  tool_bin="$(find_download_tool_bin || true)"

  info "Creating helper download script at ${helper}"
  cat > "${helper}" <<EOF
#!/usr/bin/env bash
set -euo pipefail

VCF_VERSION="${VCF_VERSION}"
DEPOT_STORE="${DEPOT_ROOT}/${DEPOT_NAME}"
TOKEN_FILE="${TOKEN_FILE}"
TOKEN_VALUE="${TOKEN_VALUE}"
TOOL_BIN="${tool_bin}"

if [[ -z "\${TOKEN_FILE}" ]]; then
  if [[ -z "\${TOKEN_VALUE}" ]]; then
    echo "No token source configured. Set TOKEN_FILE or TOKEN_VALUE." >&2
    exit 1
  fi
  TOKEN_FILE="/tmp/vcf-download-token.txt"
  printf '%s\n' "\${TOKEN_VALUE}" > "\${TOKEN_FILE}"
fi

if [[ ! -f "\${TOKEN_FILE}" ]]; then
  echo "Token file not found: \${TOKEN_FILE}" >&2
  exit 1
fi

if [[ -z "\${TOOL_BIN}" || ! -x "\${TOOL_BIN}" ]]; then
  echo "vcf-download-tool binary not found. Extract the Broadcom tarball first." >&2
  exit 1
fi

"\${TOOL_BIN}" binaries download \\
  --vcf-version "\${VCF_VERSION}" \\
  --automated-install \\
  --depot-download-token-file="\${TOKEN_FILE}" \\
  --depot-store "\${DEPOT_STORE}"
EOF
  chmod +x "${helper}"
}

run_download_if_requested() {
  [[ "${DOWNLOAD_BINARIES}" == "true" ]] || return 0
  [[ -n "${TOKEN_FILE}" || -n "${TOKEN_VALUE}" ]] || die "--download-binaries requires --token-file or TOKEN_VALUE"

  local helper="${DEPOT_ROOT}/download-vcf9-binaries.sh"
  [[ -x "${helper}" ]] || die "Helper script missing: ${helper}"

  info "Downloading VCF9 binaries into the depot structure"
  "${helper}"
}

print_summary() {
  local depot_url="https://${DEPOT_FQDN}:${DEPOT_PORT}/${DEPOT_NAME}/PROD"
  cat <<EOF

[DONE] VCF9 depot server is ready.

Depot URL:
  ${depot_url}

Basic Auth:
  Username: ${DEPOT_USER}
  Password: ${DEPOT_PASS}

Certificate:
  ${CERT_FILE}

Notes:
  1. Import the certificate into the VCF Installer / SDDC Manager trust store before adding the depot.
  2. Use the FQDN ${DEPOT_FQDN} in VCF. The certificate CN/SAN is built for that name.
  3. Download helper:
     ${DEPOT_ROOT}/download-vcf9-binaries.sh
EOF
}

main() {
  require_root
  parse_args "$@"
  install_packages
  detect_web_user
  create_depot_tree
  create_certificate
  create_auth
  configure_nginx
  configure_selinux
  configure_firewall
  extract_download_tool
  create_helper_script
  run_download_if_requested
  print_summary
}

main "$@"
