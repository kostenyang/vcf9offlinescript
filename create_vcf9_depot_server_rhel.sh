#!/usr/bin/env bash
set -euo pipefail

# ===========================================================================
# create_vcf9_depot_server_rhel.sh — VCF 9.x Offline Depot for RHEL (nginx)
#
# RHEL / Rocky / AlmaLinux focused VCF offline depot.
# HTTPS + Basic Auth, served by nginx on a configurable port (default 443).
#
# DESIGNED TO COEXIST with other web services on the same host:
#   - Listens ONLY on the HTTPS port (default 443) — does NOT grab port 80
#   - No HTTP->HTTPS redirect server block (so an existing HTTP service,
#     e.g. a RHEL DNF/YUM offline repo on port 80, keeps working)
#   - Uses its own conf.d/vcf9-depot.conf, leaves other nginx configs alone
#
# This is the script actually used to add a VCF depot onto a RHEL 10 box
# that was already serving a DNF offline repo on port 80.
#
# Tested on: RHEL 10.2 (also works on RHEL 9.x / Rocky / AlmaLinux)
#
# Prereqs installed automatically (from whatever repos are enabled):
#   nginx, openssl, httpd-tools (htpasswd)
#   On an air-gapped box, enable a local DNF repo first (see
#   setup_rhel10_offline_repo.sh).
#
# Compatible with: import_vcf9depot_ca.sh
# ===========================================================================

SCRIPT_NAME="$(basename "$0")"
SCRIPT_VERSION="1.0.0"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
VCF_VERSION="9.1.0"
DEPOT_ROOT="/opt/vcf-depot"
DEPOT_NAME="vcf9"
DEPOT_FQDN="vcf9depot.home.lab"
DEPOT_IP=""
DEPOT_PORT="443"                  # HTTPS port (does NOT touch port 80)

DEPOT_USER="vcfdepot"
DEPOT_PASS="VMware1!VMware1!"

CERT_DIR="/etc/nginx/vcf9-certs"
AUTH_FILE="/etc/nginx/.htpasswd-vcf9"
NGINX_CONF="/etc/nginx/conf.d/vcf9-depot.conf"

# Optional: bring your own cert/key
EXISTING_CERT=""
EXISTING_KEY=""

# Download tool (optional)
TOKEN_FILE=""
TOKEN_VALUE=""
ACTIVATION_CODE_FILE=""
DOWNLOAD_TYPE="INSTALL"           # INSTALL | UPGRADE | ALL
VCF_DOWNLOAD_TOOL_TGZ=""
AUTO_EXTRACT_TOOL="true"
DOWNLOAD_BINARIES="false"

# Behaviour
OPEN_FIREWALL="true"
IMPORT_CA="false"
CA_URL=""

WEB_USER="nginx"

# ---------------------------------------------------------------------------
green()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$*"; }
red()    { printf '\033[0;31m%s\033[0m\n' "$*" >&2; }
info()   { green   "[INFO] $*"; }
warn()   { yellow  "[WARN] $*"; }
die()    { red     "[ERROR] $*"; exit 1; }
ok()     { green   "[ OK ] $*"; }

# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
Usage: sudo bash ${SCRIPT_NAME} --fqdn depot.example.lab --ip 10.0.0.61 [options]

VCF 9.x offline depot for RHEL/Rocky/AlmaLinux (nginx, HTTPS + basic auth).
Coexists with other web services — listens only on the HTTPS port, never
grabs port 80, so an existing HTTP service (e.g. a DNF repo) keeps working.

Required:
  --fqdn FQDN              FQDN used by VCF to access the depot
  --ip   IP                IPv4 address (used in cert SAN)

Depot options:
  --vcf-version VERSION    VCF version to download. Default: ${VCF_VERSION}
  --depot-root PATH        Depot data root. Default: ${DEPOT_ROOT}
  --depot-name NAME        Sub-path name. Default: ${DEPOT_NAME}
  --port PORT              HTTPS listen port. Default: ${DEPOT_PORT}
  --user USER              Basic auth username. Default: ${DEPOT_USER}
  --password PASS          Basic auth password. Default: ${DEPOT_PASS}

Certificate options:
  --existing-cert PATH     Use an existing PEM cert (skip generation)
  --existing-key  PATH     Use an existing PEM key  (skip generation)

Download tool options:
  --activation-code PATH   activation-code.txt from Broadcom (VCF 9.1)
  --token-file PATH        Download token file (legacy)
  --download-tool-tgz PATH Path to vcf-download-tool-*.tar.gz
  --download-binaries      Run vcf-download-tool after setup
  --download-type TYPE     INSTALL | UPGRADE | ALL. Default: ${DOWNLOAD_TYPE}
  --skip-tool-extract      Do not extract the tool tarball

CA / firewall:
  --import-ca              Import depot cert into system + Java truststores
  --ca-url URL             Fetch CA from URL instead of local cert
  --skip-firewall          Do not open the firewall port

  --help                   Show this help

Examples:
  # Add a VCF depot on a RHEL box that already runs a DNF repo on port 80
  sudo bash ${SCRIPT_NAME} --fqdn vcf9depot.home.lab --ip 10.0.0.61

  # Full: build depot + download binaries + import cert
  sudo bash ${SCRIPT_NAME} \\
    --fqdn vcf9depot.home.lab --ip 10.0.0.61 \\
    --token-file /root/token.txt \\
    --download-tool-tgz /root/vcf-download-tool-9.1.0.0.tar.gz \\
    --download-binaries --import-ca
EOF
}

# ---------------------------------------------------------------------------
require_root() { [[ "${EUID}" -eq 0 ]] || die "Run as root (sudo)."; }

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --vcf-version)        VCF_VERSION="${2:-}";          shift 2 ;;
      --fqdn)               DEPOT_FQDN="${2:-}";           shift 2 ;;
      --ip)                 DEPOT_IP="${2:-}";             shift 2 ;;
      --depot-root)         DEPOT_ROOT="${2:-}";           shift 2 ;;
      --depot-name)         DEPOT_NAME="${2:-}";           shift 2 ;;
      --port)               DEPOT_PORT="${2:-}";           shift 2 ;;
      --user)               DEPOT_USER="${2:-}";           shift 2 ;;
      --password)           DEPOT_PASS="${2:-}";           shift 2 ;;
      --existing-cert)      EXISTING_CERT="${2:-}";        shift 2 ;;
      --existing-key)       EXISTING_KEY="${2:-}";         shift 2 ;;
      --activation-code)    ACTIVATION_CODE_FILE="${2:-}"; shift 2 ;;
      --token-file)         TOKEN_FILE="${2:-}";           shift 2 ;;
      --download-tool-tgz)  VCF_DOWNLOAD_TOOL_TGZ="${2:-}"; shift 2 ;;
      --download-binaries)  DOWNLOAD_BINARIES="true";      shift 1 ;;
      --download-type)      DOWNLOAD_TYPE="${2:-}";        shift 2 ;;
      --skip-tool-extract)  AUTO_EXTRACT_TOOL="false";     shift 1 ;;
      --import-ca)          IMPORT_CA="true";              shift 1 ;;
      --ca-url)             CA_URL="${2:-}";               shift 2 ;;
      --skip-firewall)      OPEN_FIREWALL="false";         shift 1 ;;
      --help|-h)            usage; exit 0 ;;
      *) die "Unknown argument: $1  (run with --help)" ;;
    esac
  done

  [[ -n "${DEPOT_FQDN}" ]] || die "--fqdn is required"
  [[ -n "${DEPOT_IP}" ]]   || die "--ip is required"

  if [[ -n "${EXISTING_CERT}" || -n "${EXISTING_KEY}" ]]; then
    [[ -n "${EXISTING_CERT}" && -n "${EXISTING_KEY}" ]] \
      || die "--existing-cert and --existing-key must both be supplied"
    [[ -f "${EXISTING_CERT}" ]] || die "Certificate not found: ${EXISTING_CERT}"
    [[ -f "${EXISTING_KEY}"  ]] || die "Key not found: ${EXISTING_KEY}"
  fi

  if [[ "${DOWNLOAD_BINARIES}" == "true" ]]; then
    [[ -n "${ACTIVATION_CODE_FILE}" || -n "${TOKEN_FILE}" || -n "${TOKEN_VALUE}" ]] \
      || die "--download-binaries requires --activation-code or --token-file"
  fi
}

# ---------------------------------------------------------------------------
detect_pkg_mgr() {
  if   command -v dnf >/dev/null 2>&1; then echo "dnf"
  elif command -v yum >/dev/null 2>&1; then echo "yum"
  else die "This script targets RHEL/Rocky/AlmaLinux (no dnf/yum found). For Ubuntu use create_vcf9_depot_server_v5.sh."
  fi
}

# ---------------------------------------------------------------------------
install_packages() {
  local pm; pm="$(detect_pkg_mgr)"
  info "Installing packages via ${pm}"
  local pkgs="nginx openssl httpd-tools"
  [[ -f /etc/redhat-release ]] && pkgs+=" policycoreutils-python-utils"
  [[ "${IMPORT_CA}" == "true" ]] && pkgs+=" java-21-openjdk-headless"
  "${pm}" install -y ${pkgs} \
    || die "Package install failed. On an air-gapped host, enable a local DNF repo first (setup_rhel10_offline_repo.sh)."
  ok "Packages installed"
}

# ---------------------------------------------------------------------------
create_depot_tree() {
  local root="${DEPOT_ROOT}/${DEPOT_NAME}"
  info "Creating depot tree at ${root}"
  mkdir -p "${root}"/PROD/COMP/{ESX_HOST,NSX_T_MANAGER,SDDC_MANAGER_VCF/Compatibility,VCENTER,VCF_OPS_CLOUD_PROXY,VRA,VROPS,VRSLCM,VIDB}
  mkdir -p "${root}"/PROD/metadata/{manifest/v1,productVersionCatalog/v1}
  mkdir -p "${root}"/PROD/vsan/hcl
  chown -R "${WEB_USER}:${WEB_USER}" "${root}"
  ok "Depot tree ready"
}

# ---------------------------------------------------------------------------
create_certificate() {
  mkdir -p "${CERT_DIR}"
  if [[ -n "${EXISTING_CERT}" ]]; then
    info "Using existing certificate"
    cp "${EXISTING_CERT}" "${CERT_DIR}/vcf9-depot.crt"
    cp "${EXISTING_KEY}"  "${CERT_DIR}/vcf9-depot.key"
  else
    info "Generating self-signed cert: CN=${DEPOT_FQDN}, SAN IP=${DEPOT_IP}"
    local cfg; cfg="$(mktemp)"
    cat > "${cfg}" <<EOF
[req]
default_bits=4096
prompt=no
default_md=sha256
x509_extensions=v3_req
distinguished_name=dn
[dn]
CN=${DEPOT_FQDN}
[v3_req]
subjectAltName=@alt_names
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
[alt_names]
DNS.1=${DEPOT_FQDN}
IP.1=${DEPOT_IP}
EOF
    openssl req -x509 -nodes -days 825 -newkey rsa:4096 \
      -keyout "${CERT_DIR}/vcf9-depot.key" \
      -out    "${CERT_DIR}/vcf9-depot.crt" \
      -config "${cfg}"
    rm -f "${cfg}"
  fi
  chmod 600 "${CERT_DIR}/vcf9-depot.key"
  chmod 644 "${CERT_DIR}/vcf9-depot.crt"
  ok "Certificate: ${CERT_DIR}/vcf9-depot.crt"
}

# ---------------------------------------------------------------------------
create_auth() {
  info "Creating basic auth (${DEPOT_USER})"
  htpasswd -bc "${AUTH_FILE}" "${DEPOT_USER}" "${DEPOT_PASS}" 2>/dev/null
  chmod 640 "${AUTH_FILE}"
  chown root:"${WEB_USER}" "${AUTH_FILE}"
  ok "Auth file: ${AUTH_FILE}"
}

# ---------------------------------------------------------------------------
configure_nginx() {
  info "Writing nginx config (HTTPS ${DEPOT_PORT} only — coexist-safe)"
  cat > "${NGINX_CONF}" <<EOF
# VCF 9.x Offline Depot — RHEL/nginx (HTTPS + basic auth)
# Generated by ${SCRIPT_NAME} v${SCRIPT_VERSION}
# Listens ONLY on ${DEPOT_PORT} so it coexists with other services on port 80.
server {
    listen ${DEPOT_PORT} ssl;
    server_name ${DEPOT_FQDN} ${DEPOT_IP};

    ssl_certificate     ${CERT_DIR}/vcf9-depot.crt;
    ssl_certificate_key ${CERT_DIR}/vcf9-depot.key;
    ssl_protocols       TLSv1.2 TLSv1.3;

    auth_basic           "VCF9 Offline Depot";
    auth_basic_user_file ${AUTH_FILE};

    client_max_body_size 0;
    location /PROD/ {
        alias ${DEPOT_ROOT}/${DEPOT_NAME}/PROD/;
        autoindex on;
    }
}
EOF
  nginx -t
  systemctl enable nginx >/dev/null 2>&1 || true
  systemctl reload nginx 2>/dev/null || systemctl restart nginx
  ok "nginx configured (port ${DEPOT_PORT})"
}

# ---------------------------------------------------------------------------
configure_selinux() {
  [[ -f /etc/redhat-release ]] || return 0
  command -v getenforce >/dev/null 2>&1 || return 0
  [[ "$(getenforce)" == "Enforcing" ]] || { info "SELinux not enforcing — skip"; return 0; }
  info "SELinux enforcing — applying contexts"
  if command -v semanage >/dev/null 2>&1; then
    semanage fcontext -a -t httpd_sys_content_t "${DEPOT_ROOT}/${DEPOT_NAME}(/.*)?" 2>/dev/null || true
    restorecon -Rv "${DEPOT_ROOT}/${DEPOT_NAME}" >/dev/null 2>&1 || true
    semanage port -a -t http_port_t -p tcp "${DEPOT_PORT}" 2>/dev/null \
      || semanage port -m -t http_port_t -p tcp "${DEPOT_PORT}" 2>/dev/null || true
    setsebool -P httpd_can_network_connect 1 2>/dev/null || true
    ok "SELinux contexts applied"
  else
    warn "semanage not found — install policycoreutils-python-utils if you hit 403/500"
  fi
}

# ---------------------------------------------------------------------------
configure_firewall() {
  [[ "${OPEN_FIREWALL}" == "true" ]] || return 0
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
    info "firewalld: opening ${DEPOT_PORT}/tcp"
    firewall-cmd --permanent --add-port="${DEPOT_PORT}/tcp" >/dev/null
    firewall-cmd --reload >/dev/null
    ok "Firewall opened"
  else
    warn "firewalld not active — open ${DEPOT_PORT}/tcp manually if needed"
  fi
}

# ---------------------------------------------------------------------------
import_ca() {
  [[ "${IMPORT_CA}" == "true" ]] || return 0
  local importer; importer="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/import_vcf9depot_ca.sh"
  if [[ -x "${importer}" ]]; then
    info "Importing depot CA via import_vcf9depot_ca.sh"
    [[ -n "${CA_URL}" ]] && "${importer}" --url-insecure "${CA_URL}" \
                        || "${importer}" --cert "${CERT_DIR}/vcf9-depot.crt"
  else
    warn "import_vcf9depot_ca.sh not alongside; run manually: sudo bash import_vcf9depot_ca.sh --cert ${CERT_DIR}/vcf9-depot.crt"
  fi
}

# ---------------------------------------------------------------------------
extract_download_tool() {
  [[ "${AUTO_EXTRACT_TOOL}" == "true" ]] || return 0
  [[ -n "${VCF_DOWNLOAD_TOOL_TGZ}" && -f "${VCF_DOWNLOAD_TOOL_TGZ}" ]] || return 0
  info "Extracting vcf-download-tool"
  mkdir -p "${DEPOT_ROOT}/tools"
  tar -xzf "${VCF_DOWNLOAD_TOOL_TGZ}" -C "${DEPOT_ROOT}/tools"
}

find_tool_bin() { find "${DEPOT_ROOT}/tools" -type f -name vcf-download-tool 2>/dev/null | head -1; }

create_helper_script() {
  local helper="${DEPOT_ROOT}/download-vcf9-binaries.sh"
  local bin; bin="$(find_tool_bin || true)"
  info "Writing download helper: ${helper}"
  cat > "${helper}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
VCF_VERSION="${VCF_VERSION}"
DEPOT_STORE="${DEPOT_ROOT}/${DEPOT_NAME}"
ACTIVATION_CODE_FILE="${ACTIVATION_CODE_FILE}"
TOKEN_FILE="${TOKEN_FILE}"
TOKEN_VALUE="${TOKEN_VALUE}"
DOWNLOAD_TYPE="${DOWNLOAD_TYPE}"
TOOL_BIN="${bin}"
[[ -x "\${TOOL_BIN}" ]] || { echo "vcf-download-tool not found: \${TOOL_BIN}" >&2; exit 1; }
if [[ -n "\${ACTIVATION_CODE_FILE}" && -f "\${ACTIVATION_CODE_FILE}" ]]; then
  CRED="--depot-download-activation-code-file \${ACTIVATION_CODE_FILE}"
elif [[ -n "\${TOKEN_FILE}" && -f "\${TOKEN_FILE}" ]]; then
  CRED="--depot-download-token-file \${TOKEN_FILE}"
elif [[ -n "\${TOKEN_VALUE}" ]]; then
  echo "\${TOKEN_VALUE}" > /tmp/vcf-dl-token.txt
  CRED="--depot-download-token-file /tmp/vcf-dl-token.txt"
else echo "No credential configured" >&2; exit 1; fi
"\${TOOL_BIN}" binaries download \${CRED} \\
  --vcf-version "\${VCF_VERSION}" --automated-install \\
  --depot-store "\${DEPOT_STORE}" --type "\${DOWNLOAD_TYPE}"
EOF
  chmod +x "${helper}"
}

run_download_if_requested() {
  [[ "${DOWNLOAD_BINARIES}" == "true" ]] || return 0
  info "Downloading VCF ${VCF_VERSION} ${DOWNLOAD_TYPE} binaries"
  "${DEPOT_ROOT}/download-vcf9-binaries.sh"
}

# ---------------------------------------------------------------------------
print_summary() {
  local url="https://${DEPOT_FQDN}:${DEPOT_PORT}"
  [[ "${DEPOT_PORT}" == "443" ]] && url="https://${DEPOT_FQDN}"
  cat <<EOF

=======================================================================
 VCF 9.x Offline Depot (RHEL) — DONE   v${SCRIPT_VERSION}
=======================================================================
  Depot URL  : ${url}
  Certificate: ${CERT_DIR}/vcf9-depot.crt
  Auth       : ${DEPOT_USER} / ${DEPOT_PASS}
  Depot root : ${DEPOT_ROOT}/${DEPOT_NAME}
  Listen     : HTTPS ${DEPOT_PORT} only (port 80 untouched)

Coexistence: this depot only listens on ${DEPOT_PORT}. Any existing service
on port 80 (e.g. a DNF offline repo) is unaffected.

In VCF Installer -> Depot Settings:
  URL: ${url}    User: ${DEPOT_USER}    Pass: ${DEPOT_PASS}

NOTE: import the depot cert into VCF Installer first, or you'll get a
misleading "invalid credentials" error:
  sudo bash import_vcf9depot_ca.sh --url-insecure ${url} --vcf-installer
EOF
}

# ---------------------------------------------------------------------------
main() {
  require_root
  parse_args "$@"
  info "VCF 9.x Offline Depot for RHEL — v${SCRIPT_VERSION}"
  install_packages
  create_depot_tree
  create_certificate
  create_auth
  configure_nginx
  configure_selinux
  configure_firewall
  import_ca
  extract_download_tool
  create_helper_script
  run_download_if_requested
  print_summary
}

main "$@"
