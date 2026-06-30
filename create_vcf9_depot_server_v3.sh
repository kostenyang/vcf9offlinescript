#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# create_vcf9_depot_server_v3.sh
#
# VCF 9.1 introduces native support for an offline VCF Software Depot served
# over plain HTTP with NO basic authentication. This version of the script
# builds exactly that kind of depot server (HTTP only, no cert, no htpasswd)
# and also generates helper scripts that configure the VCF Installer / VCF
# Fleet Depot Service to point at it via the API.
#
# Reference:
#   https://williamlam.com/2026/05/vcf-9-1-new-http-offline-depot-support-for-vcf-installer-fleet-depot-service.html
#
# Supported offline depot scenarios:
#   Protocol  Basic Auth  9.0.x  9.1.0  Behavior
#   HTTPS     yes         yes    yes    Default
#   HTTP      yes         yes    yes    Requires previous workaround
#   HTTP      no          no     yes    Supported via API  <-- this script
#
# Note: the VCF 9.1 Installer UI does NOT support an HTTP offline depot.
#       The VCF Installer API must be used to apply the configuration, which
#       is automatically transferred to the deployed VCF Fleet Depot Service.
# ---------------------------------------------------------------------------

SCRIPT_NAME="$(basename "$0")"
SCRIPT_VERSION="3.0.0"
VCF_VERSION="9.1.0"
DEPOT_ROOT="/opt/vcf-depot"
DEPOT_NAME="vcf9"
WEB_ROOT="/var/www/html"
NGINX_CONF="/etc/nginx/conf.d/vcf9-depot.conf"
AUTH_FILE="/etc/nginx/.htpasswd-vcf9"
CERT_DIR="/etc/nginx/vcf9-certs"
CERT_FILE="${CERT_DIR}/vcf9-depot.crt"
KEY_FILE="${CERT_DIR}/vcf9-depot.key"
DEPOT_FQDN="vcf9depotserver.home.lab"
DEPOT_IP="10.0.0.61"

# VCF 9.1 default: HTTP, no basic auth, port 8888 (matches the published example)
DEPOT_HTTP_PORT="8888"
DEPOT_HTTPS_PORT="443"
ENABLE_HTTPS="false"          # --enable-https  -> also serve HTTPS (9.0 style)
ENABLE_AUTH="false"           # --enable-auth   -> turn on nginx basic auth
DEPOT_USER="vcfdepot"
DEPOT_PASS="VMware1!VMware1!"

# VCF Installer API integration (optional)
VCF_INSTALLER_FQDN=""
VCF_INSTALLER_USER="admin@local"
VCF_INSTALLER_PASSWORD=""
CONFIGURE_INSTALLER="false"   # --configure-installer -> call the API now

TOKEN_FILE=""
TOKEN_VALUE=""
VCF_DOWNLOAD_TOOL_TGZ="/root/vcf-download-tool-9.1.0.0.tar.gz"
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

Builds a VCF 9.1 offline Software Depot served over HTTP with no basic
authentication (the new 9.1 capability), and generates helper scripts that
configure the VCF Installer / Fleet Depot Service via the API.

Required:
  --fqdn FQDN                  FQDN used by VCF to access the depot
  --ip IP                      IPv4 address used by the depot server

Depot server options:
  --vcf-version VERSION        VCF version to download. Default: ${VCF_VERSION}
  --depot-root PATH            Depot data root. Default: ${DEPOT_ROOT}
  --depot-name NAME            URL path name under web root. Default: ${DEPOT_NAME}
  --http-port PORT             HTTP port. Default: ${DEPOT_HTTP_PORT}
  --enable-https               Also serve HTTPS (9.0-style, self-signed cert)
  --https-port PORT            HTTPS port. Default: ${DEPOT_HTTPS_PORT}
  --enable-auth                Enable nginx basic authentication
  --user USER                  Basic auth username. Default: ${DEPOT_USER}
  --password PASS              Basic auth password. Default: ${DEPOT_PASS}
  --skip-firewall              Do not open the firewall port(s)

VCF Installer API options:
  --vcf-installer-fqdn FQDN    VCF Installer / SDDC Manager FQDN
  --vcf-installer-user USER    VCF Installer API user. Default: ${VCF_INSTALLER_USER}
  --vcf-installer-password P   VCF Installer API password
  --configure-installer        Call the VCF Installer API now to apply the
                               offline depot configuration

Download tool options:
  --token-file PATH            Broadcom download token file for vcf-download-tool
  --download-tool-tgz PATH     Path to vcf-download-tool-*.tar.gz
  --download-binaries          Run vcf-download-tool after setup
  --skip-tool-extract          Do not extract the tool tarball

  --import-ca                  Import the depot CA (only meaningful with --enable-https)
  --ca-url URL                 CA URL to fetch and import
  --help                       Show this help

Examples:
  # Minimal VCF 9.1 HTTP offline depot (no auth)
  sudo bash ${SCRIPT_NAME} --fqdn depot.home.lab --ip 10.0.0.60

  # Build the depot AND point the VCF Installer at it via the API
  sudo bash ${SCRIPT_NAME} \\
    --fqdn depot.home.lab --ip 10.0.0.60 \\
    --vcf-installer-fqdn sddcm01.vcf.lab \\
    --vcf-installer-password 'VMware1!VMware1!' \\
    --configure-installer
EOF
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Run this script as root."
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --vcf-version) VCF_VERSION="${2:-}"; shift 2 ;;
      --fqdn) DEPOT_FQDN="${2:-}"; shift 2 ;;
      --ip) DEPOT_IP="${2:-}"; shift 2 ;;
      --depot-root) DEPOT_ROOT="${2:-}"; shift 2 ;;
      --depot-name) DEPOT_NAME="${2:-}"; shift 2 ;;
      --http-port) DEPOT_HTTP_PORT="${2:-}"; shift 2 ;;
      --enable-https) ENABLE_HTTPS="true"; shift 1 ;;
      --https-port) DEPOT_HTTPS_PORT="${2:-}"; shift 2 ;;
      --enable-auth) ENABLE_AUTH="true"; shift 1 ;;
      --user) DEPOT_USER="${2:-}"; shift 2 ;;
      --password) DEPOT_PASS="${2:-}"; shift 2 ;;
      --vcf-installer-fqdn) VCF_INSTALLER_FQDN="${2:-}"; shift 2 ;;
      --vcf-installer-user) VCF_INSTALLER_USER="${2:-}"; shift 2 ;;
      --vcf-installer-password) VCF_INSTALLER_PASSWORD="${2:-}"; shift 2 ;;
      --configure-installer) CONFIGURE_INSTALLER="true"; shift 1 ;;
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

  if [[ "${CONFIGURE_INSTALLER}" == "true" ]]; then
    [[ -n "${VCF_INSTALLER_FQDN}" ]] || die "--configure-installer requires --vcf-installer-fqdn"
    [[ -n "${VCF_INSTALLER_PASSWORD}" ]] || die "--configure-installer requires --vcf-installer-password"
  fi
}

# Final depot URL handed to VCF. VCF appends /PROD itself, so we only expose host:port.
depot_url() {
  if [[ "${ENABLE_HTTPS}" == "true" ]]; then
    echo "https://${DEPOT_FQDN}:${DEPOT_HTTPS_PORT}"
  else
    echo "http://${DEPOT_FQDN}:${DEPOT_HTTP_PORT}"
  fi
}

import_ca() {
  [[ "${IMPORT_CA}" == "true" ]] || return 0
  [[ "${ENABLE_HTTPS}" == "true" ]] || { warn "--import-ca ignored: HTTPS is not enabled"; return 0; }
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
      # httpd-tools (htpasswd) and openssl only needed when auth/https is enabled,
      # but they are tiny so we always install for simplicity.
      local packages_to_install="nginx httpd-tools openssl jq tar curl"
      if [[ -f /etc/redhat-release ]]; then
        packages_to_install+=" policycoreutils-python-utils"
      fi
      "${pkg_mgr}" install -y ${packages_to_install}
      ;;
    apt)
      apt-get update -y
      DEBIAN_FRONTEND=noninteractive apt-get install -y nginx apache2-utils openssl jq tar curl
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

  ln -sfn "${depot_data_root}" "${WEB_ROOT}/${DEPOT_NAME}"
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
  [[ "${ENABLE_HTTPS}" == "true" ]] || return 0
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
basicConstraints = critical, CA:TRUE
keyUsage = critical, digitalSignature, keyEncipherment, keyCertSign, cRLSign
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
  [[ "${ENABLE_AUTH}" == "true" ]] || { info "Basic auth disabled (VCF 9.1 HTTP no-auth mode)"; return 0; }
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

  # Remove default Nginx site configs to prevent HTTP 403 Forbidden when accessing via IP
  if [[ -f /etc/nginx/sites-enabled/default ]]; then
    info "Removing default Ubuntu Nginx site to prevent HTTP 403 conflicts"
    rm -f /etc/nginx/sites-enabled/default
  fi
  if [[ -f /etc/nginx/conf.d/default.conf ]]; then
    rm -f /etc/nginx/conf.d/default.conf
  fi

  # Build the listen / ssl / auth fragments based on the selected mode
  local listen_lines="    listen ${DEPOT_HTTP_PORT} default_server;"
  local ssl_lines=""
  if [[ "${ENABLE_HTTPS}" == "true" ]]; then
    listen_lines+=$'\n'"    listen ${DEPOT_HTTPS_PORT} ssl default_server;"
    ssl_lines=$(cat <<EOF

    ssl_certificate ${CERT_FILE};
    ssl_certificate_key ${KEY_FILE};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
EOF
)
  fi

  local auth_lines=""
  if [[ "${ENABLE_AUTH}" == "true" ]]; then
    auth_lines=$(cat <<EOF

    auth_basic "VCF9 Offline Depot";
    auth_basic_user_file ${AUTH_FILE};
EOF
)
  fi

  cat > "${NGINX_CONF}" <<EOF
server {
${listen_lines}
    server_name ${DEPOT_FQDN};
${ssl_lines}${auth_lines}

    root ${WEB_ROOT};
    autoindex on;
    client_max_body_size 0;

    # Serve the depot via the custom name
    location /${DEPOT_NAME}/ {
      alias ${DEPOT_ROOT}/${DEPOT_NAME}/;
      autoindex on;
    }

    # Serve the official depot structure at /PROD/ so VCF can use the host root
    location /PROD/ {
      alias ${DEPOT_ROOT}/${DEPOT_NAME}/PROD/;
      autoindex on;
    }
}
EOF

  nginx -t
  systemctl enable nginx
  systemctl restart nginx
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
    # Non-standard HTTP port (e.g. 8888) must be allowed for the http daemon
    if command -v semanage >/dev/null 2>&1; then
      semanage port -a -t http_port_t -p tcp "${DEPOT_HTTP_PORT}" 2>/dev/null \
        || semanage port -m -t http_port_t -p tcp "${DEPOT_HTTP_PORT}" 2>/dev/null \
        || warn "Could not register TCP/${DEPOT_HTTP_PORT} with SELinux http_port_t"
    fi
  fi
}

configure_firewall() {
  [[ "${OPEN_FIREWALL}" == "true" ]] || return 0
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    info "Opening firewall for TCP/${DEPOT_HTTP_PORT} (HTTP)"
    firewall-cmd --permanent --add-port="${DEPOT_HTTP_PORT}/tcp"
    if [[ "${ENABLE_HTTPS}" == "true" ]]; then
      info "Opening firewall for TCP/${DEPOT_HTTPS_PORT} (HTTPS)"
      firewall-cmd --permanent --add-port="${DEPOT_HTTPS_PORT}/tcp"
    fi
    firewall-cmd --reload
  else
    warn "firewalld not active; skip firewall configuration"
  fi
}

extract_download_tool() {
  [[ "${AUTO_EXTRACT_TOOL}" == "true" ]] || return 0
  [[ -n "${VCF_DOWNLOAD_TOOL_TGZ}" ]] || return 0
  [[ -f "${VCF_DOWNLOAD_TOOL_TGZ}" ]] || { warn "Tool tarball not found: ${VCF_DOWNLOAD_TOOL_TGZ} (skipping extract)"; return 0; }

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

# Generate helper scripts that point the VCF Installer / Fleet Depot Service
# at this offline depot via the API. Two flavours are produced:
#   - configure-vcf-installer-depot.sh  (bash + curl, runs on this depot host)
#   - configure-vcf-installer-depot.ps1 (PowerShell, run from a Windows admin box)
create_installer_config_helper() {
  local url
  url="$(depot_url)"
  local bash_helper="${DEPOT_ROOT}/configure-vcf-installer-depot.sh"
  local ps_helper="${DEPOT_ROOT}/configure-vcf-installer-depot.ps1"

  info "Creating VCF Installer API helper (bash): ${bash_helper}"
  cat > "${bash_helper}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
# ---------------------------------------------------------------------------
# Point the VCF 9.1 Installer (and the deployed Fleet Depot Service) at this
# HTTP offline depot. The VCF 9.1 Installer UI cannot do this - API only.
# ---------------------------------------------------------------------------
VCF_INSTALLER_FQDN="\${VCF_INSTALLER_FQDN:-${VCF_INSTALLER_FQDN}}"
VCF_INSTALLER_USER="\${VCF_INSTALLER_USER:-${VCF_INSTALLER_USER}}"
VCF_INSTALLER_PASSWORD="\${VCF_INSTALLER_PASSWORD:-${VCF_INSTALLER_PASSWORD}}"
DEPOT_URL="\${DEPOT_URL:-${url}}"

[[ -n "\${VCF_INSTALLER_FQDN}" ]] || { echo "Set VCF_INSTALLER_FQDN" >&2; exit 1; }
[[ -n "\${VCF_INSTALLER_PASSWORD}" ]] || { echo "Set VCF_INSTALLER_PASSWORD" >&2; exit 1; }

echo "[INFO] Requesting access token from \${VCF_INSTALLER_FQDN}"
ACCESS_TOKEN="\$(curl -sk -X POST "https://\${VCF_INSTALLER_FQDN}/v1/tokens" \\
  -H 'Content-Type: application/json' \\
  -d "{\"username\":\"\${VCF_INSTALLER_USER}\",\"password\":\"\${VCF_INSTALLER_PASSWORD}\"}" \\
  | jq -r '.accessToken')"

[[ -n "\${ACCESS_TOKEN}" && "\${ACCESS_TOKEN}" != "null" ]] || { echo "Failed to obtain access token" >&2; exit 1; }

echo "[INFO] Applying offline depot configuration: \${DEPOT_URL}"
curl -sk -X PUT "https://\${VCF_INSTALLER_FQDN}/v1/system/settings/depot" \\
  -H "Authorization: Bearer \${ACCESS_TOKEN}" \\
  -H 'Content-Type: application/json' \\
  -d "{\"depotConfiguration\":{\"isOfflineDepot\":true,\"url\":\"\${DEPOT_URL}\"}}"
echo
echo "[DONE] Offline depot configuration applied."
EOF
  chmod +x "${bash_helper}"

  info "Creating VCF Installer API helper (PowerShell): ${ps_helper}"
  cat > "${ps_helper}" <<EOF
# ---------------------------------------------------------------------------
# Point the VCF 9.1 Installer (and the deployed Fleet Depot Service) at this
# HTTP offline depot. The VCF 9.1 Installer UI cannot do this - API only.
# Ref: https://williamlam.com/2026/05/vcf-9-1-new-http-offline-depot-support-for-vcf-installer-fleet-depot-service.html
# ---------------------------------------------------------------------------
\$VCFInstallerFQDN = "${VCF_INSTALLER_FQDN}"
\$VCFInstallerRootPassword = "${VCF_INSTALLER_PASSWORD}"
\$VCFInstallerOfflineDepot = "${url}"

# DO NOT EDIT BEYOND HERE #
\$payload = @{
    username = "${VCF_INSTALLER_USER}"
    password = \$VCFInstallerRootPassword
}
\$body = \$payload | ConvertTo-Json
\$params = @{
    Uri                  = "https://\${VCFInstallerFQDN}/v1/tokens"
    Method               = 'POST'
    Headers              = @{ 'Content-Type' = 'application/json' }
    SkipCertificateCheck = \$true
    Body                 = \$body
}
\$requests = Invoke-WebRequest @params
if (\$requests.StatusCode -eq 200) {
    \$accessToken = (\$requests.Content | ConvertFrom-Json).accessToken
}

\$depotPayload = @{
    depotConfiguration = @{
        isOfflineDepot = \$true
        url            = \$VCFInstallerOfflineDepot
    }
}
\$depotBody = \$depotPayload | ConvertTo-Json
\$params = @{
    Uri                  = "https://\${VCFInstallerFQDN}/v1/system/settings/depot"
    Method               = 'PUT'
    Headers              = @{
        Authorization  = "Bearer \${accessToken}"
        'Content-Type' = 'application/json'
    }
    SkipCertificateCheck = \$true
    Body                 = \$depotBody
}
Invoke-WebRequest @params
EOF
}

run_download_if_requested() {
  [[ "${DOWNLOAD_BINARIES}" == "true" ]] || return 0
  [[ -n "${TOKEN_FILE}" || -n "${TOKEN_VALUE}" ]] || die "--download-binaries requires --token-file or TOKEN_VALUE"

  local helper="${DEPOT_ROOT}/download-vcf9-binaries.sh"
  [[ -x "${helper}" ]] || die "Helper script missing: ${helper}"

  info "Downloading VCF9 binaries into the depot structure"
  "${helper}"
}

configure_installer_if_requested() {
  [[ "${CONFIGURE_INSTALLER}" == "true" ]] || return 0
  local helper="${DEPOT_ROOT}/configure-vcf-installer-depot.sh"
  [[ -x "${helper}" ]] || die "Installer config helper missing: ${helper}"
  info "Applying offline depot configuration to VCF Installer ${VCF_INSTALLER_FQDN}"
  VCF_INSTALLER_FQDN="${VCF_INSTALLER_FQDN}" \
  VCF_INSTALLER_USER="${VCF_INSTALLER_USER}" \
  VCF_INSTALLER_PASSWORD="${VCF_INSTALLER_PASSWORD}" \
  DEPOT_URL="$(depot_url)" \
    "${helper}"
}

print_summary() {
  local url
  url="$(depot_url)"
  cat <<EOF

[DONE] VCF9 offline depot server (v${SCRIPT_VERSION}, target VCF ${VCF_VERSION}) is ready.

Mode:
  Protocol  : $([[ "${ENABLE_HTTPS}" == "true" ]] && echo "HTTP + HTTPS" || echo "HTTP only")
  Basic Auth: $([[ "${ENABLE_AUTH}" == "true" ]] && echo "enabled" || echo "disabled (VCF 9.1 native HTTP no-auth)")

Depot URL to use in VCF (host:port only - VCF appends /PROD):
  ${url}

EOF
  if [[ "${ENABLE_AUTH}" == "true" ]]; then
    cat <<EOF
Basic Auth:
  Username: ${DEPOT_USER}
  Password: ${DEPOT_PASS}

EOF
  fi
  if [[ "${ENABLE_HTTPS}" == "true" ]]; then
    cat <<EOF
Certificate:
  ${CERT_FILE}
  -> Import into the VCF Installer / SDDC Manager trust store before adding the depot.

EOF
  fi
  cat <<EOF
Helper scripts (under ${DEPOT_ROOT}):
  download-vcf9-binaries.sh            Download VCF binaries with vcf-download-tool
  configure-vcf-installer-depot.sh     Point the VCF Installer at this depot (bash/curl)
  configure-vcf-installer-depot.ps1    Point the VCF Installer at this depot (PowerShell)

Important (VCF 9.1):
  The VCF 9.1 Installer UI does NOT support an HTTP offline depot.
  You MUST apply the depot configuration via the VCF Installer API:

    sudo VCF_INSTALLER_FQDN=sddcm01.vcf.lab \\
         VCF_INSTALLER_PASSWORD='VMware1!VMware1!' \\
         ${DEPOT_ROOT}/configure-vcf-installer-depot.sh

  This configuration is automatically transferred to the deployed VCF Fleet
  Depot Service. If you previously used the VCF 9.0 workaround, re-apply it
  against the Fleet Depot Service after the Fleet is deployed.
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
  import_ca
  extract_download_tool
  create_helper_script
  create_installer_config_helper
  run_download_if_requested
  configure_installer_if_requested
  print_summary
}

main "$@"
