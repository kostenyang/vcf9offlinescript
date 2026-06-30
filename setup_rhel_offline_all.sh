#!/usr/bin/env bash
set -euo pipefail

# ===========================================================================
# setup_rhel_offline_all.sh — RHEL All-in-One Offline Server
#
# Sets up BOTH on a single RHEL/Rocky/AlmaLinux host with one nginx:
#   1. RHEL DNF/YUM offline repo  (HTTP,  port 80)  — from the install DVD/ISO
#   2. VCF 9.x offline depot      (HTTPS, port 443) — for VCF Installer
#
# Self-bootstrapping: mounts the DVD, builds a temporary local DNF repo,
# installs nginx/openssl/httpd-tools FROM the DVD (no internet needed),
# then configures both services.
#
# Works on RHEL 9.x and RHEL 10.x (auto-detects DVD label / version).
#
# Source of OS packages (pick one):
#   --cdrom /dev/sr0          attached install DVD (default)
#   --iso /path/to/rhel.iso   an ISO file on disk
#
# Usage:
#   sudo bash setup_rhel_offline_all.sh \
#     --fqdn rhel-repo.home.lab --ip 10.0.0.72
#
# After it runs:
#   - DNF repo : http://<ip>/rhel/   + client file at /<ip>/rhel-offline.repo
#   - VCF depot: https://<ip>/PROD/  (user/pass below)
# ===========================================================================

SCRIPT_NAME="$(basename "$0")"
SCRIPT_VERSION="1.0.0"

# --- OS package source ---
CDROM_DEV="/dev/sr0"
ISO_PATH=""
ISO_MOUNT="/mnt/rhel-dvd"

# --- identity ---
FQDN="rhel-offline.home.lab"
IP=""

# --- DNF repo (HTTP :80) ---
ENABLE_REPO="true"
REPO_HTTP_PORT="80"
REPO_URL_PATH="rhel"            # http://<ip>/rhel/

# --- VCF depot (HTTPS :443) ---
ENABLE_DEPOT="true"
DEPOT_PORT="443"
DEPOT_ROOT="/opt/vcf-depot"
DEPOT_NAME="vcf9"
DEPOT_USER="vcfdepot"
DEPOT_PASS="VMware1!VMware1!"
CERT_DIR="/etc/nginx/vcf9-certs"
AUTH_FILE="/etc/nginx/.htpasswd-vcf9"

GPG_CHECK="1"
OPEN_FIREWALL="true"
WEB_USER="nginx"

# ---------------------------------------------------------------------------
green()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$*"; }
red()    { printf '\033[0;31m%s\033[0m\n' "$*" >&2; }
info()   { green   "[INFO] $*"; }
warn()   { yellow  "[WARN] $*"; }
die()    { red     "[ERROR] $*"; exit 1; }
ok()     { green   "[ OK ] $*"; }

usage() {
  cat <<EOF
Usage: sudo bash ${SCRIPT_NAME} --fqdn FQDN --ip IP [options]

All-in-one RHEL offline server: DNF repo (:80) + VCF depot (:443) on one nginx.

Required:
  --fqdn FQDN              Server FQDN (cert SAN + nginx server_name)
  --ip   IP                Server IPv4 address

OS package source:
  --cdrom DEV              Install DVD device. Default: ${CDROM_DEV}
  --iso PATH               Use an ISO file instead of the CD-ROM

DNF repo options:
  --no-repo                Do NOT set up the DNF offline repo
  --repo-port PORT         HTTP port for the repo. Default: ${REPO_HTTP_PORT}
  --repo-path NAME         URL path. Default: ${REPO_URL_PATH}

VCF depot options:
  --no-depot               Do NOT set up the VCF depot
  --depot-port PORT        HTTPS port. Default: ${DEPOT_PORT}
  --depot-user USER        Basic auth user. Default: ${DEPOT_USER}
  --depot-pass PASS        Basic auth pass. Default: ${DEPOT_PASS}
  --depot-root PATH        Depot data root. Default: ${DEPOT_ROOT}

Misc:
  --no-gpgcheck            Disable gpgcheck in generated client .repo
  --skip-firewall          Do not open firewall ports
  --help                   Show this help

Examples:
  # Both repo + depot (default)
  sudo bash ${SCRIPT_NAME} --fqdn rhel-repo.home.lab --ip 10.0.0.72

  # Only DNF repo
  sudo bash ${SCRIPT_NAME} --fqdn rhel-repo.home.lab --ip 10.0.0.72 --no-depot

  # Only VCF depot
  sudo bash ${SCRIPT_NAME} --fqdn vcf-depot.home.lab --ip 10.0.0.72 --no-repo
EOF
}

require_root() { [[ "${EUID}" -eq 0 ]] || die "Run as root (sudo)."; }

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --fqdn)          FQDN="${2:-}";        shift 2 ;;
      --ip)            IP="${2:-}";          shift 2 ;;
      --cdrom)         CDROM_DEV="${2:-}";   shift 2 ;;
      --iso)           ISO_PATH="${2:-}";    shift 2 ;;
      --no-repo)       ENABLE_REPO="false";  shift 1 ;;
      --repo-port)     REPO_HTTP_PORT="${2:-}"; shift 2 ;;
      --repo-path)     REPO_URL_PATH="${2:-}";  shift 2 ;;
      --no-depot)      ENABLE_DEPOT="false"; shift 1 ;;
      --depot-port)    DEPOT_PORT="${2:-}";  shift 2 ;;
      --depot-user)    DEPOT_USER="${2:-}";  shift 2 ;;
      --depot-pass)    DEPOT_PASS="${2:-}";  shift 2 ;;
      --depot-root)    DEPOT_ROOT="${2:-}";  shift 2 ;;
      --no-gpgcheck)   GPG_CHECK="0";        shift 1 ;;
      --skip-firewall) OPEN_FIREWALL="false"; shift 1 ;;
      --help|-h)       usage; exit 0 ;;
      *) die "Unknown argument: $1 (run with --help)" ;;
    esac
  done
  [[ -n "${FQDN}" ]] || die "--fqdn is required"
  [[ -n "${IP}" ]]   || die "--ip is required"
  command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1 \
    || die "This script targets RHEL/Rocky/AlmaLinux (no dnf/yum found)."
}

# ---------------------------------------------------------------------------
# Step 1 — Mount the OS media (DVD or ISO)
# ---------------------------------------------------------------------------
mount_media() {
  info "Mounting OS media to ${ISO_MOUNT}"
  mkdir -p "${ISO_MOUNT}"

  if mountpoint -q "${ISO_MOUNT}"; then
    ok "${ISO_MOUNT} already mounted"
    return 0
  fi

  local src opts
  if [[ -n "${ISO_PATH}" ]]; then
    [[ -f "${ISO_PATH}" ]] || die "ISO not found: ${ISO_PATH}"
    src="${ISO_PATH}"; opts="loop,ro"
    grep -q "${ISO_PATH}" /etc/fstab || echo "${ISO_PATH} ${ISO_MOUNT} iso9660 loop,ro,nofail 0 0" >> /etc/fstab
  else
    [[ -b "${CDROM_DEV}" ]] || die "CD-ROM not found: ${CDROM_DEV} (use --iso instead)"
    src="${CDROM_DEV}"; opts="ro"
    grep -q "${CDROM_DEV}" /etc/fstab || echo "${CDROM_DEV} ${ISO_MOUNT} iso9660 ro,nofail 0 0" >> /etc/fstab
  fi

  mount -o "${opts}" "${src}" "${ISO_MOUNT}"
  [[ -d "${ISO_MOUNT}/BaseOS" && -d "${ISO_MOUNT}/AppStream" ]] \
    || die "Media missing BaseOS/AppStream — not a full RHEL DVD"
  local ver; ver="$(grep -oP 'VERSION_ID="\K[^"]+' /etc/os-release 2>/dev/null || echo '?')"
  ok "Mounted RHEL ${ver} media ($(ls "${ISO_MOUNT}/BaseOS/Packages" | wc -l) BaseOS + $(ls "${ISO_MOUNT}/AppStream/Packages" | wc -l) AppStream pkgs)"
}

# ---------------------------------------------------------------------------
# Step 2 — Bootstrap local repo + install packages from the DVD
# ---------------------------------------------------------------------------
install_packages() {
  info "Bootstrapping local DNF repo from media and installing packages"
  cat > /etc/yum.repos.d/rhel-dvd-bootstrap.repo <<EOF
[dvd-baseos]
name=RHEL DVD BaseOS (bootstrap)
baseurl=file://${ISO_MOUNT}/BaseOS
enabled=1
gpgcheck=0
[dvd-appstream]
name=RHEL DVD AppStream (bootstrap)
baseurl=file://${ISO_MOUNT}/AppStream
enabled=1
gpgcheck=0
EOF
  local pkgs="nginx openssl httpd-tools"
  [[ -f /etc/redhat-release ]] && pkgs+=" policycoreutils-python-utils"
  dnf install -y --disablerepo='*' --enablerepo='dvd-baseos,dvd-appstream' ${pkgs} \
    || die "Failed to install ${pkgs} from DVD"
  ok "Installed: ${pkgs}"
}

# ---------------------------------------------------------------------------
# Step 3 — DNF offline repo (port 80)
# ---------------------------------------------------------------------------
configure_repo() {
  [[ "${ENABLE_REPO}" == "true" ]] || { info "DNF repo disabled (--no-repo)"; return 0; }
  info "Configuring DNF offline repo on port ${REPO_HTTP_PORT}"

  cat > /etc/nginx/conf.d/rhel-repo.conf <<EOF
# RHEL DNF Offline Repo (HTTP) — generated by ${SCRIPT_NAME} v${SCRIPT_VERSION}
server {
    listen ${REPO_HTTP_PORT} default_server;
    server_name ${FQDN} ${IP};
    location /${REPO_URL_PATH}/ {
        alias ${ISO_MOUNT}/;
        autoindex on;
        autoindex_exact_size off;
    }
    location = /${REPO_URL_PATH}-offline.repo { root /usr/share/nginx/html; }
    location = / { return 302 /${REPO_URL_PATH}/; }
}
EOF

  # client .repo (downloadable + applied locally)
  local base="http://${IP}/${REPO_URL_PATH}"
  [[ "${REPO_HTTP_PORT}" != "80" ]] && base="http://${IP}:${REPO_HTTP_PORT}/${REPO_URL_PATH}"
  cat > /usr/share/nginx/html/${REPO_URL_PATH}-offline.repo <<EOF
# RHEL Offline Repository — server ${FQDN} (${IP})
# Install on clients:
#   curl -o /etc/yum.repos.d/rhel-offline.repo ${base%/*}/${REPO_URL_PATH}-offline.repo
#   dnf clean all && dnf repolist
[rhel-baseos]
name=RHEL BaseOS (Offline)
baseurl=${base}/BaseOS
enabled=1
gpgcheck=${GPG_CHECK}
gpgkey=${base}/RPM-GPG-KEY-redhat-release
[rhel-appstream]
name=RHEL AppStream (Offline)
baseurl=${base}/AppStream
enabled=1
gpgcheck=${GPG_CHECK}
gpgkey=${base}/RPM-GPG-KEY-redhat-release
EOF

  # also point THIS server at the offline repo (replace bootstrap)
  rm -f /etc/yum.repos.d/rhel-dvd-bootstrap.repo
  cp /usr/share/nginx/html/${REPO_URL_PATH}-offline.repo /etc/yum.repos.d/rhel-offline.repo
  ok "DNF repo ready: ${base}/{BaseOS,AppStream}"
}

# ---------------------------------------------------------------------------
# Step 4 — VCF depot (port 443, HTTPS + auth)
# ---------------------------------------------------------------------------
configure_depot() {
  [[ "${ENABLE_DEPOT}" == "true" ]] || { info "VCF depot disabled (--no-depot)"; return 0; }
  info "Configuring VCF depot on HTTPS port ${DEPOT_PORT}"

  # depot tree
  local root="${DEPOT_ROOT}/${DEPOT_NAME}"
  mkdir -p "${root}"/PROD/COMP/{ESX_HOST,NSX_T_MANAGER,SDDC_MANAGER_VCF/Compatibility,VCENTER,VCF_OPS_CLOUD_PROXY,VRA,VROPS,VRSLCM,VIDB}
  mkdir -p "${root}"/PROD/metadata/{manifest/v1,productVersionCatalog/v1}
  mkdir -p "${root}"/PROD/vsan/hcl
  chown -R "${WEB_USER}:${WEB_USER}" "${root}"

  # cert
  mkdir -p "${CERT_DIR}"
  local cfg; cfg="$(mktemp)"
  cat > "${cfg}" <<EOF
[req]
default_bits=4096
prompt=no
default_md=sha256
x509_extensions=v3_req
distinguished_name=dn
[dn]
CN=${FQDN}
[v3_req]
subjectAltName=@alt_names
basicConstraints=critical,CA:TRUE
keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign,cRLSign
extendedKeyUsage=serverAuth
[alt_names]
DNS.1=${FQDN}
IP.1=${IP}
EOF
  openssl req -x509 -nodes -days 825 -newkey rsa:4096 \
    -keyout "${CERT_DIR}/vcf9-depot.key" -out "${CERT_DIR}/vcf9-depot.crt" -config "${cfg}"
  rm -f "${cfg}"
  chmod 600 "${CERT_DIR}/vcf9-depot.key"; chmod 644 "${CERT_DIR}/vcf9-depot.crt"

  # auth
  htpasswd -bc "${AUTH_FILE}" "${DEPOT_USER}" "${DEPOT_PASS}" 2>/dev/null
  chmod 640 "${AUTH_FILE}"; chown root:"${WEB_USER}" "${AUTH_FILE}"

  # nginx HTTPS server block (does not touch port 80)
  cat > /etc/nginx/conf.d/vcf9-depot.conf <<EOF
# VCF Depot (HTTPS + auth) — generated by ${SCRIPT_NAME} v${SCRIPT_VERSION}
server {
    listen ${DEPOT_PORT} ssl;
    server_name ${FQDN} ${IP};
    ssl_certificate     ${CERT_DIR}/vcf9-depot.crt;
    ssl_certificate_key ${CERT_DIR}/vcf9-depot.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    auth_basic           "VCF9 Offline Depot";
    auth_basic_user_file ${AUTH_FILE};
    client_max_body_size 0;
    location /PROD/ {
        alias ${root}/PROD/;
        autoindex on;
    }
}
EOF
  ok "VCF depot ready: https://${FQDN}:${DEPOT_PORT}/PROD/ (${DEPOT_USER})"
}

# ---------------------------------------------------------------------------
# Step 5 — SELinux + firewall + start nginx
# ---------------------------------------------------------------------------
configure_selinux() {
  command -v getenforce >/dev/null 2>&1 || return 0
  [[ "$(getenforce)" == "Enforcing" ]] || { info "SELinux not enforcing — skip"; return 0; }
  if command -v semanage >/dev/null 2>&1; then
    info "Applying SELinux contexts"
    [[ "${ENABLE_DEPOT}" == "true" ]] && {
      semanage fcontext -a -t httpd_sys_content_t "${DEPOT_ROOT}/${DEPOT_NAME}(/.*)?" 2>/dev/null || true
      restorecon -Rv "${DEPOT_ROOT}/${DEPOT_NAME}" >/dev/null 2>&1 || true
      semanage port -a -t http_port_t -p tcp "${DEPOT_PORT}" 2>/dev/null || true
    }
    setsebool -P httpd_read_user_content 1 2>/dev/null || true
  else
    warn "semanage missing — if you hit 403/500, install policycoreutils-python-utils"
  fi
}

configure_firewall() {
  [[ "${OPEN_FIREWALL}" == "true" ]] || return 0
  command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null || {
    warn "firewalld not active — open ports manually if needed"; return 0; }
  [[ "${ENABLE_REPO}"  == "true" ]] && firewall-cmd --permanent --add-port="${REPO_HTTP_PORT}/tcp" >/dev/null
  [[ "${ENABLE_DEPOT}" == "true" ]] && firewall-cmd --permanent --add-port="${DEPOT_PORT}/tcp" >/dev/null
  firewall-cmd --reload >/dev/null
  ok "Firewall ports opened"
}

start_nginx() {
  nginx -t
  systemctl enable nginx >/dev/null 2>&1 || true
  systemctl restart nginx
  ok "nginx running"
}

# ---------------------------------------------------------------------------
verify() {
  info "Verifying..."
  if [[ "${ENABLE_REPO}" == "true" ]]; then
    local p="${REPO_HTTP_PORT}"; local u="http://${IP}"; [[ "$p" != "80" ]] && u="http://${IP}:${p}"
    curl -s -o /dev/null -w "  DNF repo  : HTTP %{http_code}\n" "${u}/${REPO_URL_PATH}/BaseOS/repodata/repomd.xml"
  fi
  if [[ "${ENABLE_DEPOT}" == "true" ]]; then
    curl -sk -u "${DEPOT_USER}:${DEPOT_PASS}" -o /dev/null -w "  VCF depot : HTTP %{http_code} (auth)\n" "https://${IP}:${DEPOT_PORT}/PROD/"
    curl -sk -o /dev/null -w "  VCF depot : HTTP %{http_code} (no-auth, expect 401)\n" "https://${IP}:${DEPOT_PORT}/PROD/"
  fi
}

print_summary() {
  local repo_url="http://${FQDN}"; [[ "${REPO_HTTP_PORT}" != "80" ]] && repo_url="http://${FQDN}:${REPO_HTTP_PORT}"
  local depot_url="https://${FQDN}"; [[ "${DEPOT_PORT}" != "443" ]] && depot_url="https://${FQDN}:${DEPOT_PORT}"
  cat <<EOF

=======================================================================
 RHEL All-in-One Offline Server — DONE   v${SCRIPT_VERSION}
=======================================================================
EOF
  [[ "${ENABLE_REPO}" == "true" ]] && cat <<EOF
  DNF repo   : ${repo_url}/${REPO_URL_PATH}/
  Client repo: ${repo_url}/${REPO_URL_PATH}-offline.repo
    On clients:
      curl -o /etc/yum.repos.d/rhel-offline.repo ${repo_url}/${REPO_URL_PATH}-offline.repo
      dnf clean all && dnf repolist
EOF
  [[ "${ENABLE_DEPOT}" == "true" ]] && cat <<EOF
  VCF depot  : ${depot_url}/PROD/
  Depot auth : ${DEPOT_USER} / ${DEPOT_PASS}
  Depot cert : ${CERT_DIR}/vcf9-depot.crt
    In VCF Installer -> Depot Settings: URL ${depot_url}
    (import the cert first with import_vcf9depot_ca.sh)
EOF
  echo "======================================================================="
}

main() {
  require_root
  parse_args "$@"
  info "RHEL All-in-One Offline Server — v${SCRIPT_VERSION}"
  mount_media
  install_packages
  configure_repo
  configure_depot
  configure_selinux
  configure_firewall
  start_nginx
  verify
  print_summary
}

main "$@"
