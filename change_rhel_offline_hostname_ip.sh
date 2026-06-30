#!/usr/bin/env bash
set -euo pipefail

# ===========================================================================
# change_rhel_offline_hostname_ip.sh — Change hostname/IP of a RHEL offline server
#
# For a RHEL/Rocky/AlmaLinux host set up with setup_rhel_offline_all.sh
# (DNF repo :80 + VCF depot :443/:8888). Changes hostname and/or IP and
# updates EVERYTHING that references them:
#   1. hostname (hostnamectl) + /etc/hosts
#   2. static IP via nmcli
#   3. regenerates the depot TLS cert (new CN + SAN)
#   4. nginx server_name in ALL conf.d/*.conf that mention the old values
#   5. baseurl/IP in the generated client .repo files
#   6. reloads nginx
#
# Auto-detects current hostname/IP. Supply only what changes.
#
# Usage:
#   sudo bash change_rhel_offline_hostname_ip.sh --fqdn new.lab --ip 10.0.0.80 --gw 10.0.0.1
#   sudo bash change_rhel_offline_hostname_ip.sh --fqdn new.lab            # hostname only
#   sudo bash change_rhel_offline_hostname_ip.sh --ip 10.0.0.80 --gw ...   # IP only
# ===========================================================================

SCRIPT_NAME="$(basename "$0")"
SCRIPT_VERSION="1.0.0"

NEW_FQDN=""
NEW_IP=""
NEW_GW=""
NEW_PREFIX="23"                 # lab is /23
CERT_DIR="/etc/nginx/vcf9-certs"
REPO_HTML_DIR="/usr/share/nginx/html"
REGEN_CERT="true"
RELOAD="true"

CUR_HOSTNAME=""; CUR_SHORT=""; CUR_IP=""; CUR_IFACE=""; CUR_CON=""

green()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$*"; }
red()    { printf '\033[0;31m%s\033[0m\n' "$*" >&2; }
info()   { green   "[INFO] $*"; }
warn()   { yellow  "[WARN] $*"; }
die()    { red     "[ERROR] $*"; exit 1; }
ok()     { green   "[ OK ] $*"; }

usage() {
  cat <<EOF
Usage: sudo bash ${SCRIPT_NAME} [--fqdn FQDN] [--ip IP] [options]

Changes hostname and/or IP of a RHEL offline server and updates the depot
cert, nginx configs, and client .repo files accordingly.

At least one of --fqdn / --ip is required.

  --fqdn FQDN        New FQDN
  --ip   IP          New static IPv4 address
  --gw   GW          New gateway (kept if omitted)
  --prefix N         Subnet prefix length. Default: ${NEW_PREFIX}
  --no-cert-regen    Skip TLS cert regeneration
  --no-reload        Skip nginx reload
  --help             Show help

Example:
  sudo bash ${SCRIPT_NAME} --fqdn rhel-repo2.lab --ip 10.0.0.80 --gw 10.0.0.1
EOF
}

require_root() { [[ "${EUID}" -eq 0 ]] || die "Run as root."; }

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --fqdn) NEW_FQDN="${2:-}"; shift 2 ;;
      --ip)   NEW_IP="${2:-}";   shift 2 ;;
      --gw)   NEW_GW="${2:-}";   shift 2 ;;
      --prefix) NEW_PREFIX="${2:-}"; shift 2 ;;
      --no-cert-regen) REGEN_CERT="false"; shift 1 ;;
      --no-reload) RELOAD="false"; shift 1 ;;
      --help|-h) usage; exit 0 ;;
      *) die "Unknown argument: $1" ;;
    esac
  done
  [[ -n "${NEW_FQDN}" || -n "${NEW_IP}" ]] || die "Provide --fqdn and/or --ip"
  command -v nmcli >/dev/null 2>&1 || die "nmcli not found (this script targets RHEL/NetworkManager)"
}

detect_current() {
  CUR_HOSTNAME="$(hostname -f 2>/dev/null || hostname)"
  CUR_SHORT="${CUR_HOSTNAME%%.*}"
  CUR_IFACE="$(ip route show default 2>/dev/null | awk '/default/{print $5; exit}')"
  CUR_IP="$(ip -4 addr show "${CUR_IFACE}" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)"
  CUR_CON="$(nmcli -t -f NAME,DEVICE con show --active | awk -F: -v d="${CUR_IFACE}" '$2==d{print $1; exit}')"
  [[ -z "${NEW_FQDN}" ]] && NEW_FQDN="${CUR_HOSTNAME}"
  [[ -z "${NEW_IP}" ]]   && NEW_IP="${CUR_IP}"
  info "Current: ${CUR_HOSTNAME} / ${CUR_IP} (iface ${CUR_IFACE}, con ${CUR_CON})"
  info "New    : ${NEW_FQDN} / ${NEW_IP}"
}

change_hostname() {
  [[ "${NEW_FQDN}" != "${CUR_HOSTNAME}" ]] || { info "Hostname unchanged"; return 0; }
  local short="${NEW_FQDN%%.*}"
  info "Setting hostname -> ${NEW_FQDN}"
  hostnamectl set-hostname "${NEW_FQDN}"
  # /etc/hosts: drop old, add new
  sed -i "/\b${CUR_HOSTNAME}\b/d;/\b${CUR_SHORT}\b/d" /etc/hosts 2>/dev/null || true
  echo "${NEW_IP}    ${NEW_FQDN}    ${short}" >> /etc/hosts
  ok "Hostname set"
}

change_ip() {
  [[ "${NEW_IP}" != "${CUR_IP}" ]] || { info "IP unchanged"; return 0; }
  [[ -n "${CUR_CON}" ]] || die "Could not find nmcli connection for ${CUR_IFACE}"
  [[ -z "${NEW_GW}" ]] && NEW_GW="$(ip route show default | awk '/default/{print $3; exit}')" && warn "Keeping gateway ${NEW_GW}"
  info "Changing IP ${CUR_IP} -> ${NEW_IP}/${NEW_PREFIX} (con ${CUR_CON})"
  nmcli con mod "${CUR_CON}" ipv4.method manual ipv4.addresses "${NEW_IP}/${NEW_PREFIX}" ipv4.gateway "${NEW_GW}"
  warn "Applying new IP — SSH on the OLD ip will drop. Reconnect to ${NEW_IP}."
  nmcli con up "${CUR_CON}" >/dev/null 2>&1 || true
  ok "IP changed (reconnect to ${NEW_IP})"
}

regen_cert() {
  [[ "${REGEN_CERT}" == "true" ]] || { info "Skip cert regen"; return 0; }
  [[ -f "${CERT_DIR}/vcf9-depot.crt" ]] || { warn "No depot cert at ${CERT_DIR} — skip"; return 0; }
  info "Regenerating depot cert: CN=${NEW_FQDN}, SAN IP=${NEW_IP}"
  local cfg; cfg="$(mktemp)"
  cat > "${cfg}" <<EOF
[req]
default_bits=4096
prompt=no
default_md=sha256
x509_extensions=v3_req
distinguished_name=dn
[dn]
CN=${NEW_FQDN}
[v3_req]
subjectAltName=@alt_names
basicConstraints=critical,CA:TRUE
keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign,cRLSign
extendedKeyUsage=serverAuth
[alt_names]
DNS.1=${NEW_FQDN}
IP.1=${NEW_IP}
EOF
  cp "${CERT_DIR}/vcf9-depot.crt" "${CERT_DIR}/vcf9-depot.crt.bak-$(date +%s)" 2>/dev/null || true
  openssl req -x509 -nodes -days 825 -newkey rsa:4096 \
    -keyout "${CERT_DIR}/vcf9-depot.key" -out "${CERT_DIR}/vcf9-depot.crt" -config "${cfg}"
  chmod 600 "${CERT_DIR}/vcf9-depot.key"; chmod 644 "${CERT_DIR}/vcf9-depot.crt"
  rm -f "${cfg}"
  ok "Cert regenerated"
}

update_configs() {
  info "Updating nginx configs + client .repo files"
  local changed=0
  # nginx confs
  for f in /etc/nginx/conf.d/*.conf; do
    [[ -f "${f}" ]] || continue
    if grep -q "${CUR_HOSTNAME}\|${CUR_SHORT}\|${CUR_IP}" "${f}" 2>/dev/null; then
      sed -i "s/${CUR_HOSTNAME}/${NEW_FQDN}/g; s/\b${CUR_SHORT}\b/${NEW_FQDN%%.*}/g; s/${CUR_IP}/${NEW_IP}/g" "${f}"
      echo "  updated ${f}"; changed=1
    fi
  done
  # client .repo files (baseurl uses IP)
  for f in "${REPO_HTML_DIR}"/*.repo /etc/yum.repos.d/rhel-offline.repo; do
    [[ -f "${f}" ]] || continue
    if grep -q "${CUR_IP}\|${CUR_HOSTNAME}" "${f}" 2>/dev/null; then
      sed -i "s/${CUR_IP}/${NEW_IP}/g; s/${CUR_HOSTNAME}/${NEW_FQDN}/g" "${f}"
      echo "  updated ${f}"; changed=1
    fi
  done
  [[ "${changed}" == "1" ]] && ok "Configs updated" || warn "No configs referenced old values"
}

reload_nginx() {
  [[ "${RELOAD}" == "true" ]] || { info "Skip nginx reload"; return 0; }
  command -v nginx >/dev/null 2>&1 || return 0
  nginx -t && systemctl reload nginx && ok "nginx reloaded" || warn "nginx reload failed — check config"
}

print_summary() {
  cat <<EOF

=======================================================================
 RHEL offline server hostname/IP change — DONE   v${SCRIPT_VERSION}
=======================================================================
  Hostname : ${CUR_HOSTNAME} -> ${NEW_FQDN}
  IP       : ${CUR_IP} -> ${NEW_IP}/${NEW_PREFIX}${NEW_GW:+  GW ${NEW_GW}}
  Cert     : $([[ "${REGEN_CERT}" == "true" ]] && echo regenerated || echo unchanged)

EOF
  if [[ "${NEW_IP}" != "${CUR_IP}" ]]; then
    cat <<EOF
NOTE: IP changed. Reconnect:  ssh root@${NEW_IP}
  Update DNS: ${NEW_FQDN} -> ${NEW_IP}
EOF
  fi
  cat <<EOF
If a VCF Installer / other client trusts the OLD depot cert, re-import the
new one (cert was regenerated):
  sudo bash import_vcf9depot_ca.sh --url-insecure https://${NEW_FQDN} --vcf-installer
EOF
}

main() {
  require_root
  parse_args "$@"
  detect_current
  info "${SCRIPT_NAME} v${SCRIPT_VERSION}"
  change_hostname
  regen_cert
  update_configs
  reload_nginx
  change_ip      # last — drops SSH if IP changes
  print_summary
}

main "$@"
