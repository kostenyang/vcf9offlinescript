#!/usr/bin/env bash
set -euo pipefail

# ===========================================================================
# change_depot_hostname_ip.sh — Change VCF Depot Server Hostname and/or IP
#
# Run on the depot server itself (as root) after initial setup.
#
# What this script does:
#   1. Changes the system hostname (hostnamectl)
#   2. Updates /etc/hosts
#   3. Changes the static IP via netplan (Ubuntu) or nmcli (RHEL)
#   4. Regenerates the TLS certificate with the new CN / SAN
#   5. Updates the nginx or Apache2 server_name
#   6. Reloads the web server
#   7. Prints instructions for re-importing the cert on VCF components
#
# Compatible with: create_vcf9_depot_server_v5.sh (and v4 variants)
# Run import_vcf9depot_ca.sh on VCF Installer / SDDC Manager / VCF OPS
# after this script completes.
# ===========================================================================

SCRIPT_NAME="$(basename "$0")"
SCRIPT_VERSION="1.0.0"

# ---------------------------------------------------------------------------
# Defaults — all optional, only changed values need to be supplied
# ---------------------------------------------------------------------------
NEW_FQDN=""        # e.g. vcf91-depot.lab
NEW_IP=""          # e.g. 10.0.1.80
NEW_GW=""          # e.g. 10.0.1.1  (leave empty to keep current)
NEW_PREFIX="24"    # subnet prefix, default 24

# Auto-detected current values
CUR_HOSTNAME=""
CUR_IP=""
CUR_IFACE=""

# Cert subject (re-used from current cert, override if needed)
CERT_COUNTRY="US"
CERT_STATE="California"
CERT_CITY="Palo Alto"
CERT_ORG="Lab"
CERT_OU="Cloud-Services"

REGEN_CERT="true"       # always regenerate cert when FQDN or IP changes
RESTART_WEBSERVER="true"

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
Usage: sudo bash ${SCRIPT_NAME} [options]

Changes the hostname and/or IP of a VCF 9 offline depot server,
regenerates the TLS certificate, and reloads the web server.

At least one of --fqdn or --ip is required.

Options:
  --fqdn NEW_FQDN        New fully qualified domain name
                         e.g. --fqdn vcf91-depot.lab
  --ip   NEW_IP          New static IPv4 address
                         e.g. --ip 10.0.1.80
  --gw   GATEWAY         New default gateway (optional, keep current if omitted)
  --prefix PREFIX        Subnet prefix length. Default: ${NEW_PREFIX}

Certificate subject (optional — only needed if you want to change org info):
  --country CODE         Default: ${CERT_COUNTRY}
  --state   STATE        Default: ${CERT_STATE}
  --city    CITY         Default: ${CERT_CITY}
  --org     ORG          Default: ${CERT_ORG}
  --ou      OU           Default: ${CERT_OU}

  --no-cert-regen        Skip certificate regeneration (not recommended)
  --no-restart           Skip web server restart

  --help                 Show this help

Examples:
  # Change both hostname and IP
  sudo bash ${SCRIPT_NAME} --fqdn vcf91-depot.lab --ip 10.0.1.80 --gw 10.0.1.1

  # Change hostname only (keep IP)
  sudo bash ${SCRIPT_NAME} --fqdn vcf91-depot.lab

  # Change IP only (keep hostname)
  sudo bash ${SCRIPT_NAME} --ip 10.0.1.80 --gw 10.0.1.1
EOF
}

# ---------------------------------------------------------------------------
require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Run as root (sudo)."
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --fqdn)          NEW_FQDN="${2:-}";     shift 2 ;;
      --ip)            NEW_IP="${2:-}";       shift 2 ;;
      --gw)            NEW_GW="${2:-}";       shift 2 ;;
      --prefix)        NEW_PREFIX="${2:-}";   shift 2 ;;
      --country)       CERT_COUNTRY="${2:-}"; shift 2 ;;
      --state)         CERT_STATE="${2:-}";   shift 2 ;;
      --city)          CERT_CITY="${2:-}";    shift 2 ;;
      --org)           CERT_ORG="${2:-}";     shift 2 ;;
      --ou)            CERT_OU="${2:-}";      shift 2 ;;
      --no-cert-regen) REGEN_CERT="false";    shift 1 ;;
      --no-restart)    RESTART_WEBSERVER="false"; shift 1 ;;
      --help|-h)       usage; exit 0 ;;
      *) die "Unknown argument: $1  (run with --help)" ;;
    esac
  done

  [[ -n "${NEW_FQDN}" || -n "${NEW_IP}" ]] \
    || die "Provide at least --fqdn or --ip (run with --help)"
}

# ---------------------------------------------------------------------------
detect_current() {
  CUR_HOSTNAME="$(hostname -f 2>/dev/null || hostname)"
  CUR_IFACE="$(ip route show default 2>/dev/null | awk '/default/ {print $5}' | head -1)"
  CUR_IP="$(ip addr show "${CUR_IFACE}" 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -1)"

  # Fill defaults for unchanged values
  [[ -z "${NEW_FQDN}" ]] && NEW_FQDN="${CUR_HOSTNAME}"
  [[ -z "${NEW_IP}" ]]   && NEW_IP="${CUR_IP}"

  info "Current hostname : ${CUR_HOSTNAME}"
  info "Current IP       : ${CUR_IP}  (interface: ${CUR_IFACE})"
  info "New hostname     : ${NEW_FQDN}"
  info "New IP           : ${NEW_IP}"
}

# ---------------------------------------------------------------------------
detect_web_server() {
  if systemctl is-active --quiet nginx 2>/dev/null; then
    echo "nginx"
  elif systemctl is-active --quiet apache2 2>/dev/null; then
    echo "apache2"
  elif systemctl is-active --quiet httpd 2>/dev/null; then
    echo "httpd"
  else
    echo "none"
  fi
}

detect_cert_dir() {
  local ws
  ws="$(detect_web_server)"
  case "${ws}" in
    nginx)          echo "/etc/nginx/vcf9-certs" ;;
    apache2|httpd)  echo "/etc/apache2/ssl" ;;
    *)
      # fall back: search for our cert
      find /etc -name "vcf9-depot.crt" 2>/dev/null | head -1 | xargs dirname 2>/dev/null || echo "/etc/ssl/vcf9"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Step 1 — Hostname
# ---------------------------------------------------------------------------
change_hostname() {
  if [[ "${NEW_FQDN}" == "${CUR_HOSTNAME}" ]]; then
    info "Hostname unchanged (${CUR_HOSTNAME}) — skipping"
    return 0
  fi

  local short_name="${NEW_FQDN%%.*}"
  info "Setting hostname to ${NEW_FQDN}"
  hostnamectl set-hostname "${NEW_FQDN}"

  # Update /etc/hosts — replace old FQDN and short name, add new ones
  # Remove old entries for the old hostname
  sed -i "/\b${CUR_HOSTNAME}\b/d" /etc/hosts
  sed -i "/\b${CUR_HOSTNAME%%.*}\b/d" /etc/hosts

  # Add new entry (use new IP if it's also changing, else current IP)
  local hosts_ip="${NEW_IP:-${CUR_IP}}"
  if ! grep -q "${hosts_ip}.*${NEW_FQDN}" /etc/hosts; then
    echo "${hosts_ip}    ${NEW_FQDN}    ${short_name}" >> /etc/hosts
  fi

  ok "Hostname set to ${NEW_FQDN}"
}

# ---------------------------------------------------------------------------
# Step 2 — IP address (netplan for Ubuntu, nmcli for RHEL)
# ---------------------------------------------------------------------------
change_ip() {
  if [[ "${NEW_IP}" == "${CUR_IP}" ]]; then
    info "IP unchanged (${CUR_IP}) — skipping network config"
    return 0
  fi

  info "Changing IP from ${CUR_IP} to ${NEW_IP}/${NEW_PREFIX}"

  # Detect network manager
  if command -v netplan >/dev/null 2>&1; then
    _change_ip_netplan
  elif command -v nmcli >/dev/null 2>&1; then
    _change_ip_nmcli
  else
    warn "No netplan or nmcli found."
    warn "Change IP manually in your network config, then reboot."
    warn "New IP to set: ${NEW_IP}/${NEW_PREFIX}  GW: ${NEW_GW:-<keep current>}"
  fi
}

_change_ip_netplan() {
  local netplan_dir="/etc/netplan"
  local cfg
  cfg="$(ls "${netplan_dir}"/*.yaml 2>/dev/null | head -1)"
  [[ -n "${cfg}" ]] || die "No netplan config found in ${netplan_dir}"

  info "Updating netplan config: ${cfg}"

  # Backup
  cp "${cfg}" "${cfg}.bak-$(date +%s)"

  # Detect current gateway from routing table if not provided
  if [[ -z "${NEW_GW}" ]]; then
    NEW_GW="$(ip route show default | awk '/default/ {print $3}' | head -1)"
    warn "No --gw supplied; keeping current gateway: ${NEW_GW}"
  fi

  # Write new netplan config for this interface
  cat > "${cfg}" <<EOF
network:
  version: 2
  ethernets:
    ${CUR_IFACE}:
      dhcp4: no
      addresses:
        - ${NEW_IP}/${NEW_PREFIX}
      routes:
        - to: default
          via: ${NEW_GW}
      nameservers:
        addresses: [${NEW_GW}, 8.8.8.8]
EOF

  netplan apply
  ok "Netplan applied — new IP: ${NEW_IP}/${NEW_PREFIX}"
  warn "SSH connection will drop if you are connected via the old IP."
  warn "Reconnect to ${NEW_IP} after this script completes."
}

_change_ip_nmcli() {
  local con
  con="$(nmcli -t -f NAME,DEVICE con show --active | grep ":${CUR_IFACE}$" | cut -d: -f1 | head -1)"
  [[ -n "${con}" ]] || die "Could not find active nmcli connection for ${CUR_IFACE}"

  if [[ -z "${NEW_GW}" ]]; then
    NEW_GW="$(ip route show default | awk '/default/ {print $3}' | head -1)"
    warn "No --gw supplied; keeping current gateway: ${NEW_GW}"
  fi

  info "Updating nmcli connection: ${con}"
  nmcli con mod "${con}" ipv4.method manual \
    ipv4.addresses "${NEW_IP}/${NEW_PREFIX}" \
    ipv4.gateway "${NEW_GW}"
  nmcli con up "${con}"
  ok "nmcli applied — new IP: ${NEW_IP}/${NEW_PREFIX}"
}

# ---------------------------------------------------------------------------
# Step 3 — Regenerate TLS certificate
# ---------------------------------------------------------------------------
regen_cert() {
  [[ "${REGEN_CERT}" == "true" ]] || { info "Skipping cert regeneration (--no-cert-regen)"; return 0; }

  local cert_dir
  cert_dir="$(detect_cert_dir)"
  mkdir -p "${cert_dir}"

  info "Regenerating TLS certificate"
  info "  CN  : ${NEW_FQDN}"
  info "  SAN : DNS:${NEW_FQDN}, IP:${NEW_IP}"

  local san_cnf
  san_cnf="$(mktemp)"
  cat > "${san_cnf}" <<EOF
[req]
default_bits       = 4096
prompt             = no
default_md         = sha256
x509_extensions    = v3_req
distinguished_name = dn

[dn]
C  = ${CERT_COUNTRY}
ST = ${CERT_STATE}
L  = ${CERT_CITY}
O  = ${CERT_ORG}
OU = ${CERT_OU}
CN = ${NEW_FQDN}

[v3_req]
subjectAltName = @alt_names
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth

[alt_names]
DNS.1 = ${NEW_FQDN}
IP.1  = ${NEW_IP}
EOF

  # Backup old cert
  [[ -f "${cert_dir}/vcf9-depot.crt" ]] && cp "${cert_dir}/vcf9-depot.crt" "${cert_dir}/vcf9-depot.crt.bak-$(date +%s)"
  [[ -f "${cert_dir}/vcf9-depot.key" ]] && cp "${cert_dir}/vcf9-depot.key" "${cert_dir}/vcf9-depot.key.bak-$(date +%s)"

  openssl req -x509 -nodes -days 825 \
    -newkey rsa:4096 \
    -keyout "${cert_dir}/vcf9-depot.key" \
    -out    "${cert_dir}/vcf9-depot.crt" \
    -config "${san_cnf}"

  chmod 600 "${cert_dir}/vcf9-depot.key"
  chmod 644 "${cert_dir}/vcf9-depot.crt"
  chown root:root "${cert_dir}/vcf9-depot.key" "${cert_dir}/vcf9-depot.crt"
  rm -f "${san_cnf}"

  ok "New certificate: ${cert_dir}/vcf9-depot.crt"
}

# ---------------------------------------------------------------------------
# Step 4 — Update web server config
# ---------------------------------------------------------------------------
update_webserver_config() {
  local ws
  ws="$(detect_web_server)"
  info "Web server: ${ws}"

  case "${ws}" in
    nginx)
      local conf
      conf="$(grep -rl "vcf9-depot\|vcf.*depot\|offline.*depot" /etc/nginx/conf.d/ 2>/dev/null | head -1)"
      [[ -n "${conf}" ]] || conf="/etc/nginx/conf.d/vcf9-depot.conf"

      if [[ -f "${conf}" ]]; then
        info "Updating nginx server_name in ${conf}"
        cp "${conf}" "${conf}.bak-$(date +%s)"
        sed -i "s/server_name .*/server_name ${NEW_FQDN};/" "${conf}"
        ok "nginx server_name updated"
      else
        warn "nginx config not found at ${conf} — update server_name manually"
      fi

      if [[ "${RESTART_WEBSERVER}" == "true" ]]; then
        nginx -t && systemctl reload nginx && ok "nginx reloaded"
      fi
      ;;

    apache2)
      local conf="/etc/apache2/sites-available/default-ssl.conf"
      if [[ -f "${conf}" ]]; then
        info "Updating Apache2 ServerName in ${conf}"
        cp "${conf}" "${conf}.bak-$(date +%s)"
        sed -i "s/ServerName .*/ServerName ${NEW_FQDN}/" "${conf}"
        ok "Apache2 ServerName updated"
      fi

      if [[ "${RESTART_WEBSERVER}" == "true" ]]; then
        apache2ctl configtest && systemctl reload apache2 && ok "apache2 reloaded"
      fi
      ;;

    httpd)
      local conf="/etc/httpd/conf.d/vcf9-depot-ssl.conf"
      if [[ -f "${conf}" ]]; then
        info "Updating httpd ServerName in ${conf}"
        cp "${conf}" "${conf}.bak-$(date +%s)"
        sed -i "s/ServerName .*/ServerName ${NEW_FQDN}/" "${conf}"
        ok "httpd ServerName updated"
      fi

      if [[ "${RESTART_WEBSERVER}" == "true" ]]; then
        apachectl configtest && systemctl reload httpd && ok "httpd reloaded"
      fi
      ;;

    none)
      warn "No active web server found — skipping config update"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Step 5 — Update download helper script
# ---------------------------------------------------------------------------
update_helper_script() {
  local helper="/opt/vcf-depot/download-vcf9-binaries.sh"
  [[ -f "${helper}" ]] || return 0
  info "Download helper exists at ${helper} — no depot URL stored there, no update needed"
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print_summary() {
  local cert_dir
  cert_dir="$(detect_cert_dir)"
  local ws
  ws="$(detect_web_server)"

  cat <<EOF

=======================================================================
 change_depot_hostname_ip.sh v${SCRIPT_VERSION} — DONE
=======================================================================

  Hostname   : ${NEW_FQDN}
  IP address : ${NEW_IP}/${NEW_PREFIX}${NEW_GW:+  GW: ${NEW_GW}}
  Certificate: ${cert_dir}/vcf9-depot.crt
  Web server : ${ws}

=======================================================================
 NEXT STEPS — Re-import the new certificate on VCF components
=======================================================================

The TLS certificate has been regenerated with the new hostname/IP.
You MUST re-import it on every machine that connects to this depot,
otherwise they will get a certificate error.

Copy the new cert off this server:
  scp root@${NEW_IP}:${cert_dir}/vcf9-depot.crt /tmp/vcf9-depot-new.crt

Then on each VCF component, run import_vcf9depot_ca.sh:

  # VCF Installer
  sudo bash import_vcf9depot_ca.sh \\
    --url-insecure https://${NEW_FQDN} \\
    --vcf-installer

  # SDDC Manager
  sudo bash import_vcf9depot_ca.sh \\
    --url-insecure https://${NEW_FQDN} \\
    --sddc-manager

  # VCF OPS
  sudo bash import_vcf9depot_ca.sh \\
    --url-insecure https://${NEW_FQDN} \\
    --vcf-ops

Also update the Depot Settings in VCF Installer / SDDC Manager UI:
  URL: https://${NEW_FQDN}

EOF

  if [[ "${NEW_IP}" != "${CUR_IP}" ]]; then
    cat <<EOF
NOTE: The IP address changed from ${CUR_IP} to ${NEW_IP}.
  - Your current SSH session may have dropped.
  - Reconnect to: ssh root@${NEW_IP}
  - Update DNS: ${NEW_FQDN} -> ${NEW_IP}
EOF
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  require_root
  parse_args "$@"
  detect_current

  info "${SCRIPT_NAME} v${SCRIPT_VERSION}"

  change_hostname
  change_ip
  regen_cert
  update_webserver_config
  update_helper_script
  print_summary
}

main "$@"
