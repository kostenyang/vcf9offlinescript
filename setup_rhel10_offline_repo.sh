#!/usr/bin/env bash
set -euo pipefail

# ===========================================================================
# setup_rhel10_offline_repo.sh — RHEL 10 Offline DNF/YUM Repository
#
# Creates a local HTTP repository server from a RHEL 10 DVD ISO.
# Serves both BaseOS and AppStream repos that RHEL 10 clients can use
# without an active Red Hat subscription or internet access.
#
# Tested on: Ubuntu 24.04 / RHEL 9 (as repo server OS)
# Target clients: RHEL 10.x, CentOS Stream 10, Rocky Linux 10
#
# Two methods to expose ISO content:
#   mount (default) — loop-mounts the ISO (read-only, no extra disk space)
#   copy            — copies ISO content to web root (needs ~11 GB extra)
#
# Usage:
#   sudo bash setup_rhel10_offline_repo.sh \
#     --iso /data/rhel-10.2-x86_64-dvd.iso \
#     --fqdn rhel10-repo.home.lab \
#     --ip 10.0.0.63
#
# Client setup (generated automatically at /tmp/rhel10-offline.repo):
#   sudo cp /tmp/rhel10-offline.repo /etc/yum.repos.d/
#   sudo dnf clean all && sudo dnf repolist
# ===========================================================================

SCRIPT_NAME="$(basename "$0")"
SCRIPT_VERSION="1.0.0"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
ISO_PATH=""
FQDN="rhel10-repo.home.lab"
IP=""
REPO_NAME="rhel10"              # URL path: http://server/rhel10/
METHOD="mount"                  # mount | copy
MOUNT_POINT="/mnt/rhel10-iso"
REPO_ROOT="/opt/rhel10-repo"    # used only for copy method
WEB_ROOT="/var/www/html"
HTTP_PORT="80"

ENABLE_HTTPS="false"
HTTPS_PORT="443"
ENABLE_AUTH="false"
REPO_USER="repouser"
REPO_PASS="VMware1!"

GPG_CHECK="1"                   # 1=enabled, 0=disabled for client .repo

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
Usage: sudo bash ${SCRIPT_NAME} --iso /path/to/rhel-10.x-x86_64-dvd.iso [options]

Sets up a local RHEL 10 offline DNF/YUM repository served over HTTP.

Required:
  --iso PATH           Path to the RHEL 10 DVD ISO file

Server options:
  --fqdn FQDN          Repo server FQDN. Default: ${FQDN}
  --ip   IP            Repo server IP (used for direct IP access)
  --repo-name NAME     URL path name. Default: ${REPO_NAME}
                       Repo URL: http://FQDN/${REPO_NAME}/
  --port PORT          HTTP port. Default: ${HTTP_PORT}

ISO exposure method:
  --method mount       Loop-mount the ISO (default, saves disk space)
  --method copy        Copy ISO contents to disk (~11 GB required)
  --mount-point PATH   ISO mount point. Default: ${MOUNT_POINT}
  --repo-root   PATH   Copy destination.  Default: ${REPO_ROOT}

HTTPS + auth (optional, for secure internal repos):
  --enable-https       Also serve via HTTPS (self-signed cert)
  --https-port PORT    HTTPS port. Default: ${HTTPS_PORT}
  --enable-auth        Enable basic authentication
  --user USER          Auth username. Default: ${REPO_USER}
  --password PASS      Auth password. Default: ${REPO_PASS}

GPG:
  --no-gpgcheck        Disable GPG check in generated .repo file
                       (not recommended; RHEL 10 ISO has signed packages)

  --help               Show this help

Examples:
  # Minimal — mount ISO, HTTP only
  sudo bash ${SCRIPT_NAME} \\
    --iso /data/rhel-10.2-x86_64-dvd.iso \\
    --fqdn rhel10-repo.home.lab \\
    --ip 10.0.0.63

  # Copy mode (ISO can be removed afterward)
  sudo bash ${SCRIPT_NAME} \\
    --iso /data/rhel-10.2-x86_64-dvd.iso \\
    --fqdn rhel10-repo.home.lab \\
    --ip 10.0.0.63 \\
    --method copy

  # HTTPS + basic auth
  sudo bash ${SCRIPT_NAME} \\
    --iso /data/rhel-10.2-x86_64-dvd.iso \\
    --fqdn rhel10-repo.home.lab \\
    --ip 10.0.0.63 \\
    --enable-https \\
    --enable-auth \\
    --password 'MyP@ssw0rd'
EOF
}

# ---------------------------------------------------------------------------
require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Run as root (sudo)."
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --iso)           ISO_PATH="${2:-}";       shift 2 ;;
      --fqdn)          FQDN="${2:-}";           shift 2 ;;
      --ip)            IP="${2:-}";             shift 2 ;;
      --repo-name)     REPO_NAME="${2:-}";      shift 2 ;;
      --port)          HTTP_PORT="${2:-}";      shift 2 ;;
      --method)        METHOD="${2:-}";         shift 2 ;;
      --mount-point)   MOUNT_POINT="${2:-}";   shift 2 ;;
      --repo-root)     REPO_ROOT="${2:-}";      shift 2 ;;
      --enable-https)  ENABLE_HTTPS="true";     shift 1 ;;
      --https-port)    HTTPS_PORT="${2:-}";     shift 2 ;;
      --enable-auth)   ENABLE_AUTH="true";      shift 1 ;;
      --user)          REPO_USER="${2:-}";      shift 2 ;;
      --password)      REPO_PASS="${2:-}";      shift 2 ;;
      --no-gpgcheck)   GPG_CHECK="0";           shift 1 ;;
      --help|-h)       usage; exit 0 ;;
      *) die "Unknown argument: $1  (run with --help)" ;;
    esac
  done

  [[ -n "${ISO_PATH}" ]] || die "--iso is required"
  [[ -f "${ISO_PATH}" ]] || die "ISO file not found: ${ISO_PATH}"

  case "${METHOD}" in
    mount|copy) ;;
    *) die "--method must be 'mount' or 'copy'" ;;
  esac
}

# ---------------------------------------------------------------------------
detect_pkg_mgr() {
  if   command -v dnf     >/dev/null 2>&1; then echo "dnf"
  elif command -v yum     >/dev/null 2>&1; then echo "yum"
  elif command -v apt-get >/dev/null 2>&1; then echo "apt"
  else die "Unsupported OS: no dnf / yum / apt-get found"
  fi
}

detect_web_user() {
  case "$(detect_pkg_mgr)" in
    dnf|yum) echo "nginx" ;;
    apt)     echo "www-data" ;;
  esac
}

# ---------------------------------------------------------------------------
# Step 1 — Install packages
# ---------------------------------------------------------------------------
install_packages() {
  local pkg_mgr
  pkg_mgr="$(detect_pkg_mgr)"
  info "Installing packages via ${pkg_mgr}"

  case "${pkg_mgr}" in
    dnf|yum)
      local pkgs="nginx"
      [[ "${ENABLE_AUTH}" == "true" ]]  && pkgs+=" httpd-tools"
      [[ "${ENABLE_HTTPS}" == "true" ]] && pkgs+=" openssl"
      "${pkg_mgr}" install -y ${pkgs}
      ;;
    apt)
      apt-get update -y
      local pkgs="nginx"
      [[ "${ENABLE_AUTH}" == "true" ]]  && pkgs+=" apache2-utils"
      [[ "${ENABLE_HTTPS}" == "true" ]] && pkgs+=" openssl"
      DEBIAN_FRONTEND=noninteractive apt-get install -y ${pkgs}
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Step 2 — Expose ISO content
# ---------------------------------------------------------------------------
expose_iso() {
  if [[ "${METHOD}" == "mount" ]]; then
    _mount_iso
  else
    _copy_iso
  fi
}

_mount_iso() {
  info "Mounting ISO: ${ISO_PATH} -> ${MOUNT_POINT}"
  mkdir -p "${MOUNT_POINT}"

  # Check if already mounted
  if mount | grep -q " on ${MOUNT_POINT} "; then
    warn "${MOUNT_POINT} is already mounted — skipping"
    return 0
  fi

  mount -o loop,ro "${ISO_PATH}" "${MOUNT_POINT}"

  # Persist mount in fstab (survives reboot)
  if ! grep -q "${ISO_PATH}" /etc/fstab; then
    info "Adding ISO mount to /etc/fstab"
    echo "${ISO_PATH} ${MOUNT_POINT} iso9660 loop,ro,nofail 0 0" >> /etc/fstab
  fi

  ok "ISO mounted at ${MOUNT_POINT}"
  _validate_iso_structure "${MOUNT_POINT}"
}

_copy_iso() {
  info "Copying ISO contents to ${REPO_ROOT} (this may take a few minutes)"
  mkdir -p "${REPO_ROOT}"

  # Temp mount to copy from
  local tmp_mount
  tmp_mount="$(mktemp -d)"
  mount -o loop,ro "${ISO_PATH}" "${tmp_mount}"

  _validate_iso_structure "${tmp_mount}"

  # Rsync preserves hard links and handles partial copies
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --info=progress2 "${tmp_mount}/" "${REPO_ROOT}/"
  else
    cp -r "${tmp_mount}/." "${REPO_ROOT}/"
  fi

  umount "${tmp_mount}"
  rmdir  "${tmp_mount}"

  ok "ISO contents copied to ${REPO_ROOT}"
}

_validate_iso_structure() {
  local base="$1"
  local ok=true

  info "Validating ISO structure at ${base}"
  for dir in BaseOS AppStream; do
    if [[ -d "${base}/${dir}" && -d "${base}/${dir}/repodata" ]]; then
      local pkg_count
      pkg_count="$(find "${base}/${dir}/Packages" -name '*.rpm' 2>/dev/null | wc -l)"
      ok "  ${dir}: repodata present, ${pkg_count} packages"
    else
      warn "  ${dir}: missing or no repodata — ISO may not be a full RHEL 10 DVD"
      ok=false
    fi
  done

  [[ "${ok}" == "true" ]] \
    || warn "ISO structure validation had warnings. Continuing anyway."
}

# ---------------------------------------------------------------------------
# Step 3 — Nginx configuration
# ---------------------------------------------------------------------------
configure_nginx() {
  local web_user
  web_user="$(detect_web_user)"
  local pkg_mgr
  pkg_mgr="$(detect_pkg_mgr)"

  # Path to repo content
  local content_path
  [[ "${METHOD}" == "mount" ]] && content_path="${MOUNT_POINT}" || content_path="${REPO_ROOT}"

  # Create web root symlink for clean URL
  mkdir -p "${WEB_ROOT}"
  ln -sfn "${content_path}" "${WEB_ROOT}/${REPO_NAME}"

  # Remove Ubuntu default site to avoid conflicts
  if [[ "${pkg_mgr}" == "apt" ]]; then
    rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
  fi
  rm -f /etc/nginx/conf.d/default.conf 2>/dev/null || true

  local nginx_conf="/etc/nginx/conf.d/rhel10-repo.conf"
  info "Writing nginx config: ${nginx_conf}"

  # Build optional HTTPS server block
  local https_block=""
  if [[ "${ENABLE_HTTPS}" == "true" ]]; then
    _generate_cert
    https_block="
server {
    listen ${HTTPS_PORT} ssl;
    server_name ${FQDN};

    ssl_certificate     /etc/nginx/rhel10-repo-certs/repo.crt;
    ssl_certificate_key /etc/nginx/rhel10-repo-certs/repo.key;
    ssl_protocols       TLSv1.2 TLSv1.3;

    $(_auth_block)

    location /${REPO_NAME}/ {
        alias ${content_path}/;
        autoindex on;
    }
}"
  fi

  cat > "${nginx_conf}" <<EOF
# RHEL 10 Offline DNF Repository — nginx
# Generated by ${SCRIPT_NAME} v${SCRIPT_VERSION}
server {
    listen ${HTTP_PORT} default_server;
    server_name ${FQDN}${IP:+ ${IP}};

    $(_auth_block)

    location /${REPO_NAME}/ {
        alias ${content_path}/;
        autoindex on;
        autoindex_exact_size off;
        autoindex_localtime on;
    }

    # Convenience: redirect root to repo
    location = / {
        return 302 /${REPO_NAME}/;
    }
}
${https_block}
EOF

  nginx -t
  systemctl enable --now nginx
  ok "nginx configured and started"
}

_auth_block() {
  if [[ "${ENABLE_AUTH}" == "true" ]]; then
    local auth_file="/etc/nginx/.htpasswd-rhel10"
    htpasswd -cb "${auth_file}" "${REPO_USER}" "${REPO_PASS}" >/dev/null 2>&1
    chmod 640 "${auth_file}"
    local web_user
    web_user="$(detect_web_user)"
    chown root:"${web_user}" "${auth_file}"
    printf 'auth_basic "RHEL 10 Repo";\n    auth_basic_user_file %s;' "${auth_file}"
  fi
}

_generate_cert() {
  local cert_dir="/etc/nginx/rhel10-repo-certs"
  mkdir -p "${cert_dir}"
  [[ -f "${cert_dir}/repo.crt" ]] && { info "Cert already exists, reusing"; return 0; }

  info "Generating self-signed TLS certificate"
  local san_ip="${IP:-127.0.0.1}"
  openssl req -x509 -nodes -days 825 -newkey rsa:2048 \
    -keyout "${cert_dir}/repo.key" \
    -out    "${cert_dir}/repo.crt" \
    -subj "/CN=${FQDN}" \
    -addext "subjectAltName=DNS:${FQDN},IP:${san_ip}" 2>/dev/null
  chmod 600 "${cert_dir}/repo.key"
  chmod 644 "${cert_dir}/repo.crt"
  ok "Certificate: ${cert_dir}/repo.crt"
}

# ---------------------------------------------------------------------------
# Step 4 — Firewall
# ---------------------------------------------------------------------------
configure_firewall() {
  local ports="${HTTP_PORT}/tcp"
  [[ "${ENABLE_HTTPS}" == "true" ]] && ports+=" ${HTTPS_PORT}/tcp"

  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
    info "firewalld: opening ${ports}"
    for p in ${ports}; do firewall-cmd --permanent --add-port="${p}"; done
    firewall-cmd --reload

  elif command -v ufw >/dev/null 2>&1; then
    if ufw status 2>/dev/null | grep -q "^Status: active"; then
      info "ufw: allowing ${ports}"
      for p in ${ports}; do ufw allow "${p}"; done
    else
      warn "ufw inactive — open ${ports} manually if needed"
    fi

  else
    warn "No active firewall found — open port ${HTTP_PORT} manually if needed"
  fi
}

# ---------------------------------------------------------------------------
# Step 5 — Generate .repo file for RHEL 10 clients
# ---------------------------------------------------------------------------
generate_repo_file() {
  local base_url="http://${FQDN}:${HTTP_PORT}/${REPO_NAME}"
  [[ "${HTTP_PORT}" == "80" ]] && base_url="http://${FQDN}/${REPO_NAME}"

  # HTTPS preferred if enabled
  if [[ "${ENABLE_HTTPS}" == "true" ]]; then
    base_url="https://${FQDN}:${HTTPS_PORT}/${REPO_NAME}"
    [[ "${HTTPS_PORT}" == "443" ]] && base_url="https://${FQDN}/${REPO_NAME}"
  fi

  local auth_prefix=""
  if [[ "${ENABLE_AUTH}" == "true" ]]; then
    auth_prefix="${REPO_USER}:${REPO_PASS}@"
    base_url="${base_url//:\/\//://}"
    # Insert credentials: http://user:pass@host/path
    local proto="${base_url%%://*}"
    local rest="${base_url#*://}"
    base_url="${proto}://${auth_prefix}${rest}"
  fi

  local repo_file="/tmp/rhel10-offline.repo"
  info "Generating client .repo file: ${repo_file}"

  cat > "${repo_file}" <<EOF
# RHEL 10 Offline Repository
# Server: ${FQDN} (${IP:-auto})
# Generated by ${SCRIPT_NAME} v${SCRIPT_VERSION}
#
# Installation:
#   1. Copy this file to the RHEL 10 client:
#        sudo cp rhel10-offline.repo /etc/yum.repos.d/
#   2. Disable Red Hat subscription repos (if no active subscription):
#        sudo dnf config-manager --disable rhel-10-*  2>/dev/null || true
#   3. Verify:
#        sudo dnf clean all && sudo dnf repolist

[rhel10-baseos]
name=RHEL 10 BaseOS (Offline)
baseurl=${base_url}/BaseOS
enabled=1
gpgcheck=${GPG_CHECK}
gpgkey=${base_url}/RPM-GPG-KEY-redhat-release
sslverify=0

[rhel10-appstream]
name=RHEL 10 AppStream (Offline)
baseurl=${base_url}/AppStream
enabled=1
gpgcheck=${GPG_CHECK}
gpgkey=${base_url}/RPM-GPG-KEY-redhat-release
sslverify=0
EOF

  ok "Client repo file generated: ${repo_file}"

  # Also save a copy alongside the script
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  cp "${repo_file}" "${script_dir}/rhel10-offline.repo" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print_summary() {
  local content_path
  [[ "${METHOD}" == "mount" ]] && content_path="${MOUNT_POINT}" || content_path="${REPO_ROOT}"
  local base_url="http://${FQDN}/${REPO_NAME}"
  [[ "${HTTP_PORT}" != "80" ]] && base_url="http://${FQDN}:${HTTP_PORT}/${REPO_NAME}"

  cat <<EOF

=======================================================================
 RHEL 10 Offline Repo — DONE   (${SCRIPT_NAME} v${SCRIPT_VERSION})
=======================================================================

  Method      : ${METHOD}  (${content_path})
  BaseOS URL  : ${base_url}/BaseOS
  AppStream   : ${base_url}/AppStream
  Repo file   : /tmp/rhel10-offline.repo

=======================================================================
 RHEL 10 CLIENT SETUP
=======================================================================

1. Transfer the .repo file to each RHEL 10 client:
     scp /tmp/rhel10-offline.repo root@<client-ip>:/etc/yum.repos.d/

2. On each client, disable subscription repos (if no RH subscription):
     sudo dnf config-manager --disable rhel-10-* 2>/dev/null || true

3. Test it:
     sudo dnf clean all
     sudo dnf repolist
     sudo dnf install -y vim curl   # quick install test

=======================================================================
 ISO INFORMATION
=======================================================================

  ISO path    : ${ISO_PATH}
  Mount point : ${MOUNT_POINT}
  ISO size    : $(du -sh "${ISO_PATH}" 2>/dev/null | cut -f1)

EOF
  if [[ "${METHOD}" == "mount" ]]; then
    cat <<EOF
NOTE (mount method):
  The ISO must remain at ${ISO_PATH} and the mount at ${MOUNT_POINT}
  is added to /etc/fstab so it survives reboots.
  To stop serving: umount ${MOUNT_POINT}

EOF
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  require_root
  parse_args "$@"

  info "${SCRIPT_NAME} v${SCRIPT_VERSION}"
  info "ISO    : ${ISO_PATH}"
  info "Method : ${METHOD}"
  info "FQDN   : ${FQDN}"

  install_packages
  expose_iso
  configure_nginx
  configure_firewall
  generate_repo_file
  print_summary
}

main "$@"
