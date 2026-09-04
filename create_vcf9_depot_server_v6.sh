#!/usr/bin/env bash
set -euo pipefail

# ===========================================================================
# create_vcf9_depot_server_v6.sh — VCF 9.1 Offline Depot (unified)
#
# Single script supporting both nginx and Apache2/httpd web servers.
# Select with:  --web-server nginx   (default)
#               --web-server apache
#
# What this script does:
#   1. Installs the chosen web server + supporting packages
#      - Automatically adds default-jre-headless when --import-ca is set
#   2. (Optional) Formats and mounts a data disk to /var/www/html
#      - Pass --data-disk /dev/sdb for a fresh VM with a separate data disk
#   3. Creates the VCF depot directory tree under DEPOT_ROOT
#   4. Generates a self-signed TLS certificate with SAN (DNS + IP)
#   5. Configures basic authentication (htpasswd)
#   6. Configures the web server (HTTPS + basic auth)
#      - nginx:   writes /etc/nginx/conf.d/vcf9-depot.conf
#      - Apache2: writes default-ssl.conf with Alias /PROD/ to avoid 403
#      - httpd:   writes /etc/httpd/conf.d/vcf9-depot-ssl.conf (RHEL)
#   7. Configures the firewall
#      - Detects firewalld (RHEL) vs ufw (Ubuntu) vs neither
#   8. (Optional) Imports the depot cert into system + Java truststores
#      - Calls import_vcf9depot_ca.sh from the same directory
#   9. Extracts vcf-download-tool and generates a software depot ID
#  10. (Optional) Downloads VCF 9.1 binaries via vcf-download-tool
#  11. Generates a re-runnable download helper under DEPOT_ROOT
#
# Tested on:  Ubuntu 24.04 LTS, RHEL 9 / Rocky Linux 9
# VCF version: 9.1.0.0
#
# Reference:
#   https://vstellar.com/2026/05/vcf-9-1-home-lab-series-part-4-vcf-offline-depo/
#
# Compatible with:
#   import_vcf9depot_ca.sh — import depot CA into system + Java truststores
# ===========================================================================

SCRIPT_NAME="$(basename "$0")"
SCRIPT_VERSION="6.1.0"

# ---------------------------------------------------------------------------
# Configuration defaults
# ---------------------------------------------------------------------------
VCF_VERSION="9.1.0.0"
WEB_SERVER="nginx"                # nginx | apache

DEPOT_ROOT="/opt/vcf-depot"
DEPOT_NAME="vcf9"
WEB_ROOT="/var/www/html"

# v6: 不再硬編碼預設值。
# 🔴 v5 給了預設 "vcf91-depot.home.lab",導致 `--fqdn is required` 這個檢查
#    永遠不會觸發 —— 忘了帶 --fqdn 不會報錯,而是靜默套用別人的 lab 名稱,
#    憑證 CN / nginx server_name 全都錯。v6 預設留空,改成:
#    空值 -> 自動抓 OS 的 FQDN -> 抓不到(或沒有 domain)才報錯。
DEPOT_FQDN=""
DEPOT_IP=""
DEPOT_PORT="443"
DEPOT_HTTP_PORT="80"              # nginx only: HTTP -> HTTPS redirect port

DEPOT_USER="vcfdepot"
DEPOT_PASS="VMware1!VMware1!"

# --- Certificate ---
# nginx:  self-signed directly (CN only; SAN via openssl config)
# Apache: generates CSR first, then self-signs (can swap the cert later)
CERT_COUNTRY="US"
CERT_STATE="California"
CERT_CITY="Palo Alto"
CERT_ORG="Lab"
CERT_OU="Cloud-Services"
# Bring your own cert/key (skips generation):
EXISTING_CERT=""
EXISTING_KEY=""

# --- Data disk (optional) ---
# Set to a block device (e.g. /dev/sdb) to format ext4 and mount as WEB_ROOT.
# Leave empty to skip. Use --skip-disk-setup if the disk is already mounted.
DATA_DISK=""
SKIP_DISK_SETUP="false"

# --- Download tool ---
# VCF 9.1 uses activation-code; VCF 9.0 used token-file. Both are supported.
ACTIVATION_CODE_FILE=""
TOKEN_FILE=""
TOKEN_VALUE=""
DOWNLOAD_TYPE="INSTALL"           # INSTALL | UPGRADE | ALL

VCF_DOWNLOAD_TOOL_TGZ=""
AUTO_EXTRACT_TOOL="true"
DOWNLOAD_BINARIES="false"

# --- Misc ---
OPEN_FIREWALL="true"
IMPORT_CA="false"
CA_URL=""
REPAIR_ONLY="false"       # --repair: 只修既有 depot 權限,不重建

# Internal — set by detect_web_user()
WEB_USER=""

# ---------------------------------------------------------------------------
# Colour helpers
# ---------------------------------------------------------------------------
green()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$*"; }
red()    { printf '\033[0;31m%s\033[0m\n' "$*" >&2; }
info()   { green   "[INFO] $*"; }
warn()   { yellow  "[WARN] $*"; }
die()    { red     "[ERROR] $*"; exit 1; }

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
Usage: sudo bash ${SCRIPT_NAME} --fqdn depot.example.lab --ip 10.0.0.80 [options]

Sets up a VCF 9.1 offline depot (HTTPS + basic auth).
Supports nginx (default) and Apache2/httpd.

Required (v6: 可省略,會自動從 OS 偵測):
  --fqdn FQDN                  FQDN used by VCF. Omit -> auto-detect via `hostname -f`
  --ip   IP                    IPv4 for cert SAN. Omit -> auto-detect via `hostname -I`

Web server:
  --web-server nginx|apache    Web server to use. Default: ${WEB_SERVER}

Depot options:
  --vcf-version VERSION        VCF version string. Default: ${VCF_VERSION}
  --depot-root PATH            Depot data root. Default: ${DEPOT_ROOT}
  --depot-name NAME            Sub-path name. Default: ${DEPOT_NAME}
  --port PORT                  HTTPS listen port. Default: ${DEPOT_PORT}
  --http-port PORT             HTTP redirect port (nginx only). Default: ${DEPOT_HTTP_PORT}
  --user USER                  Basic auth username. Default: ${DEPOT_USER}
  --password PASS              Basic auth password. Default: ${DEPOT_PASS}

Certificate options:
  --country CODE               Cert subject country. Default: ${CERT_COUNTRY}
  --state   STATE              Cert subject state.   Default: ${CERT_STATE}
  --city    CITY               Cert subject city.    Default: ${CERT_CITY}
  --org     ORG                Cert subject org.     Default: ${CERT_ORG}
  --ou      OU                 Cert subject OU.      Default: ${CERT_OU}
  --existing-cert PATH         Use an existing PEM cert (skips generation)
  --existing-key  PATH         Use an existing PEM key  (skips generation)

Data disk options:
  --data-disk DEVICE           Block device to format (ext4) and mount as web root
                               Example: --data-disk /dev/sdb
                               Recommended for fresh VMs (article uses 500 GB+)
  --skip-disk-setup            Skip format/mount (disk already prepared)

Download tool options:
  --activation-code PATH       activation-code.txt from Broadcom (VCF 9.1)
  --token-file PATH            Download token file (VCF 9.0 legacy, still works)
  --download-tool-tgz PATH     Path to vcf-download-tool-*.tar.gz
  --download-binaries          Run the download tool after setup
  --download-type TYPE         INSTALL | UPGRADE | ALL. Default: ${DOWNLOAD_TYPE}
  --skip-tool-extract          Do not extract the tool tarball

CA / import options:
  --import-ca                  Import depot cert into system + Java truststores
                               (calls import_vcf9depot_ca.sh in the same dir;
                               also installs JRE on Ubuntu when not present)
  --ca-url URL                 Fetch CA cert from a URL instead of local cert

Misc:
  --skip-firewall              Do not configure the firewall
  --repair                     Only fix permissions on an existing depot
                               (owner=web user, a+rX, parent traversal),
                               then exit. For a depot returning 403.
  --help                       Show this help

Examples:
  # Minimal nginx setup (prompts for nothing, uses defaults)
  sudo bash ${SCRIPT_NAME} --fqdn vcf91-depot.lab --ip 10.0.0.80

  # Apache on a fresh Ubuntu VM with a 500 GB second disk
  sudo bash ${SCRIPT_NAME} \\
    --fqdn vcf91-depot.lab --ip 10.0.0.80 \\
    --web-server apache \\
    --data-disk /dev/sdb \\
    --import-ca

  # Full unattended setup — nginx, download VCF 9.1 binaries
  sudo bash ${SCRIPT_NAME} \\
    --fqdn vcf91-depot.lab --ip 10.0.0.80 \\
    --web-server nginx \\
    --data-disk /dev/sdb \\
    --activation-code /root/activation-code.txt \\
    --download-tool-tgz /root/vcf-download-tool-9.1.0.0.tar.gz \\
    --download-binaries \\
    --import-ca
EOF
}

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------
require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Run this script as root (sudo)."
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --web-server)         WEB_SERVER="${2:-}";             shift 2 ;;
      --vcf-version)        VCF_VERSION="${2:-}";            shift 2 ;;
      --fqdn)               DEPOT_FQDN="${2:-}";             shift 2 ;;
      --ip)                 DEPOT_IP="${2:-}";               shift 2 ;;
      --depot-root)         DEPOT_ROOT="${2:-}";             shift 2 ;;
      --depot-name)         DEPOT_NAME="${2:-}";             shift 2 ;;
      --port)               DEPOT_PORT="${2:-}";             shift 2 ;;
      --http-port)          DEPOT_HTTP_PORT="${2:-}";        shift 2 ;;
      --user)               DEPOT_USER="${2:-}";             shift 2 ;;
      --password)           DEPOT_PASS="${2:-}";             shift 2 ;;
      --country)            CERT_COUNTRY="${2:-}";           shift 2 ;;
      --state)              CERT_STATE="${2:-}";             shift 2 ;;
      --city)               CERT_CITY="${2:-}";              shift 2 ;;
      --org)                CERT_ORG="${2:-}";               shift 2 ;;
      --ou)                 CERT_OU="${2:-}";                shift 2 ;;
      --existing-cert)      EXISTING_CERT="${2:-}";          shift 2 ;;
      --existing-key)       EXISTING_KEY="${2:-}";           shift 2 ;;
      --data-disk)          DATA_DISK="${2:-}";              shift 2 ;;
      --skip-disk-setup)    SKIP_DISK_SETUP="true";          shift 1 ;;
      --activation-code)    ACTIVATION_CODE_FILE="${2:-}";   shift 2 ;;
      --token-file)         TOKEN_FILE="${2:-}";             shift 2 ;;
      --download-tool-tgz)  VCF_DOWNLOAD_TOOL_TGZ="${2:-}"; shift 2 ;;
      --download-binaries)  DOWNLOAD_BINARIES="true";        shift 1 ;;
      --download-type)      DOWNLOAD_TYPE="${2:-}";          shift 2 ;;
      --skip-tool-extract)  AUTO_EXTRACT_TOOL="false";       shift 1 ;;
      --import-ca)          IMPORT_CA="true";                shift 1 ;;
      --ca-url)             CA_URL="${2:-}";                 shift 2 ;;
      --skip-firewall)      OPEN_FIREWALL="false";           shift 1 ;;
      --help|-h)            usage; exit 0 ;;
      --repair)             REPAIR_ONLY="true";              shift 1 ;;
      *) die "Unknown argument: $1  (run with --help)" ;;
    esac
  done

  # --repair 只修權限,不需要 FQDN/IP/憑證等驗證 — 提前結束參數檢查。
  if [[ "${REPAIR_ONLY}" == "true" ]]; then
    return 0
  fi

  # --- v6: --fqdn / --ip 沒給就從 OS 抓 ---------------------------------
  # 🔴 `hostname -f` 在沒有設定 search domain 的機器上只會回 short name,
  #    所以必須檢查有沒有 "." —— 只有真的是 FQDN 才採用。
  if [[ -z "${DEPOT_FQDN}" ]]; then
    local _f
    _f="$(hostname -f 2>/dev/null || true)"
    [[ "${_f}" == *.* ]] || _f=""
    if [[ -n "${_f}" ]]; then
      DEPOT_FQDN="${_f}"
      info "--fqdn not given — using OS FQDN: ${DEPOT_FQDN}"
    else
      die "--fqdn is required.
  OS reports hostname '$(hostname 2>/dev/null)', which is not a FQDN (no domain part).
  Either pass it explicitly:
      --fqdn depot.example.lab
  or set a proper FQDN on this host first:
      hostnamectl set-hostname depot.example.lab"
    fi
  fi

  if [[ -z "${DEPOT_IP}" ]]; then
    local _ip
    _ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    if [[ -n "${_ip}" ]]; then
      DEPOT_IP="${_ip}"
      info "--ip not given — using primary IP: ${DEPOT_IP}"
    else
      die "--ip is required (could not auto-detect a primary IPv4 address)"
    fi
  fi

  # Validate web server choice
  case "${WEB_SERVER}" in
    nginx|apache) ;;
    *) die "--web-server must be 'nginx' or 'apache' (got: ${WEB_SERVER})" ;;
  esac

  # Validate existing cert pair
  if [[ -n "${EXISTING_CERT}" || -n "${EXISTING_KEY}" ]]; then
    [[ -n "${EXISTING_CERT}" && -n "${EXISTING_KEY}" ]] \
      || die "--existing-cert and --existing-key must both be supplied together"
    [[ -f "${EXISTING_CERT}" ]] || die "Certificate not found: ${EXISTING_CERT}"
    [[ -f "${EXISTING_KEY}"  ]] || die "Key not found: ${EXISTING_KEY}"
  fi

  # Validate download prerequisites
  if [[ "${DOWNLOAD_BINARIES}" == "true" ]]; then
    [[ -n "${ACTIVATION_CODE_FILE}" || -n "${TOKEN_FILE}" || -n "${TOKEN_VALUE}" ]] \
      || die "--download-binaries requires --activation-code or --token-file"
    [[ -z "${ACTIVATION_CODE_FILE}" || -f "${ACTIVATION_CODE_FILE}" ]] \
      || die "Activation code file not found: ${ACTIVATION_CODE_FILE}"
  fi
}

# ---------------------------------------------------------------------------
# OS / package manager detection
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
    dnf|yum)
      WEB_USER="$( [[ "${WEB_SERVER}" == "apache" ]] && echo "apache" || echo "nginx" )"
      ;;
    apt)
      WEB_USER="www-data"
      ;;
  esac
  info "Web user: ${WEB_USER}"
}

# ---------------------------------------------------------------------------
# Step 1 — Install packages
# ---------------------------------------------------------------------------
install_packages() {
  local pkg_mgr
  pkg_mgr="$(detect_pkg_mgr)"
  info "Installing packages via ${pkg_mgr} (web server: ${WEB_SERVER})"

  case "${pkg_mgr}" in
    dnf|yum)
      local pkgs="openssl jq tar curl"
      [[ "${WEB_SERVER}" == "nginx" ]]  && pkgs+=" nginx httpd-tools"
      [[ "${WEB_SERVER}" == "apache" ]] && pkgs+=" httpd mod_ssl httpd-tools"
      [[ -f /etc/redhat-release ]]      && pkgs+=" policycoreutils-python-utils"
      # keytool lives in the JRE — only install when needed
      [[ "${IMPORT_CA}" == "true" ]]    && pkgs+=" java-11-openjdk-headless"
      "${pkg_mgr}" install -y ${pkgs}
      ;;

    apt)
      local pkgs="openssl apache2-utils jq tar curl unzip ca-certificates"
      [[ "${WEB_SERVER}" == "nginx" ]]  && pkgs+=" nginx"
      [[ "${WEB_SERVER}" == "apache" ]] && pkgs+=" apache2"
      # default-jre-headless provides keytool for Java truststore import.
      [[ "${IMPORT_CA}" == "true" ]]    && pkgs+=" default-jre-headless"

      # Which requested packages are NOT yet installed?
      local missing=""
      for p in ${pkgs}; do
        dpkg -s "${p}" >/dev/null 2>&1 || missing+=" ${p}"
      done

      if [[ -z "${missing// /}" ]]; then
        info "All required packages already installed — skipping apt (air-gapped OK)"
      else
        info "Packages to install:${missing}"
        # apt needs internet OR a local apt mirror. On air-gapped Ubuntu this
        # fails — install the packages offline first, then re-run this script.
        if apt-get update -y >/dev/null 2>&1 \
           && DEBIAN_FRONTEND=noninteractive apt-get install -y ${missing}; then
          info "Installed:${missing}"
        else
          die "apt could not install:${missing}
  No internet / no apt source (air-gapped?). Install the packages OFFLINE first,
  then re-run this script:
    sudo bash ubuntu_offline_packages.sh --install --bundle ubuntu-nginx-offline-<rel>-amd64.tar.gz
  Pre-built bundles (20.04/22.04/24.04):
    https://github.com/kostenyang/vcf9offlinescript/releases"
        fi
      fi
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Step 2 — (Optional) data disk setup
# ---------------------------------------------------------------------------
# Use on a fresh Ubuntu / RHEL VM where /var/www/html should live on a
# separate disk. Pass --data-disk /dev/sdb (article recommends 500 GB+).
# Idempotent: skips if the mount point is already in use.
setup_data_disk() {
  if [[ "${SKIP_DISK_SETUP}" == "true" ]]; then
    info "Data disk setup skipped (--skip-disk-setup)"
    return 0
  fi
  [[ -n "${DATA_DISK}" ]] || return 0   # no disk specified — silent skip

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
    info "Adding ${DATA_DISK} to /etc/fstab (persistent mount)"
    echo "${DATA_DISK} ${WEB_ROOT} ext4 defaults 1 1" >> /etc/fstab
  fi

  mount -a
  systemctl daemon-reload
  info "Data disk ready: $(df -h "${WEB_ROOT}" | tail -1)"
}

# ---------------------------------------------------------------------------
# Step 3 — VCF depot directory tree
# ---------------------------------------------------------------------------
create_depot_tree() {
  local depot_data_root="${DEPOT_ROOT}/${DEPOT_NAME}"
  info "Creating depot directory tree at ${depot_data_root}"

  # Ensure web root exists (package install normally creates it, but be safe)
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

  # Apache uses an Alias directive (no symlink needed).
  # nginx uses an alias directive in the location block (also no symlink needed,
  # but a convenience symlink under WEB_ROOT helps direct access via browser).
  ln -sfn "${depot_data_root}/PROD" "${WEB_ROOT}/PROD" 2>/dev/null || true

  fix_depot_permissions
}

# ---------------------------------------------------------------------------
# Permissions — 可獨立呼叫(--repair),也在建立 depot 後呼叫。
#
# 🔴 v5/v6-early 用 0500 目錄 / 0400 檔案的「鎖死」模型,在真實環境很脆弱:
#   1. ${DEPOT_ROOT} 若是自訂掛載點(例如 /userap),root 擁有、others 沒有 x,
#      web user 穿不過去 -> 底下再完美也回 403。
#   2. 事後用 root 跑 download tool 補檔,新檔是 root:root 644,
#      web user 讀不到 -> 又 403。每次補料都要重跑 chmod,維運地獄。
#
# v6 改用 a+rX 模型(目錄 755 / 檔案 644,屬 web user):
#   - 目錄可穿越+可列;檔案可讀。這正是 download tool 寫檔的自然權限。
#   - 補料後重跑本函式(或 --repair)即可,冪等、不怕重下。
#   - depot 走 HTTPS + basic auth 控管存取,檔案在磁碟上 world-readable
#     不是威脅模型(內容就是 VCF binaries)。
# ---------------------------------------------------------------------------
fix_depot_permissions() {
  local depot_data_root="${DEPOT_ROOT}/${DEPOT_NAME}"
  [[ -d "${depot_data_root}" ]] || die "Depot dir not found: ${depot_data_root}"

  info "Fixing permissions on ${depot_data_root} (owner=${WEB_USER}, mode=a+rX)"
  chown -R "${WEB_USER}:${WEB_USER}" "${depot_data_root}"
  chmod -R a+rX "${depot_data_root}"

  # 父目錄鏈補「穿越」權限(o+x),讓 web user 進得了自訂的 DEPOT_ROOT。
  # 只加 x,不開放讀取/列目錄,對 /userap 等既有用途安全。
  local _p="${depot_data_root}"
  while [[ "${_p}" != "/" && -n "${_p}" ]]; do
    chmod o+x "${_p}" 2>/dev/null || true
    _p="$(dirname "${_p}")"
  done
  info "Traversal (o+x) ensured on parent chain up to /"

  # 冒煙測試:用 web user 身分真的讀得到 catalog 嗎(有的話)
  local _cat="${depot_data_root}/PROD/metadata/productVersionCatalog/v1/productVersionCatalog.json"
  if [[ -f "${_cat}" ]]; then
    if sudo -u "${WEB_USER}" test -r "${_cat}" && sudo -u "${WEB_USER}" head -c1 "${_cat}" >/dev/null 2>&1; then
      info "Smoke test OK — ${WEB_USER} can read the catalog"
    else
      warn "Smoke test FAILED — ${WEB_USER} still cannot read ${_cat}"
      warn "Check the parent chain manually:  namei -l ${_cat}"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Step 4 — TLS certificate
# ---------------------------------------------------------------------------
_cert_dir() {
  case "${WEB_SERVER}" in
    nginx)  echo "/etc/nginx/vcf9-certs" ;;
    apache) echo "/etc/apache2/ssl" ;;      # Ubuntu
  esac
}

create_certificate() {
  local cert_dir
  cert_dir="$(_cert_dir)"
  mkdir -p "${cert_dir}"

  if [[ -n "${EXISTING_CERT}" ]]; then
    info "Using existing certificate: ${EXISTING_CERT}"
    cp "${EXISTING_CERT}" "${cert_dir}/vcf9-depot.crt"
    cp "${EXISTING_KEY}"  "${cert_dir}/vcf9-depot.key"
  else
    info "Generating TLS certificate: CN=${DEPOT_FQDN}, SAN=DNS:${DEPOT_FQDN}+IP:${DEPOT_IP}"

    local san_entries="DNS.1 = ${DEPOT_FQDN}"
    [[ -n "${DEPOT_IP}" ]] && san_entries+=$'\nIP.1 = '"${DEPOT_IP}"

    # nginx: single openssl req -x509 (direct self-sign, no separate CSR step)
    # Apache: generate CSR first so it can be submitted to a real CA if needed
    local san_cnf
    san_cnf="$(mktemp)"

    if [[ "${WEB_SERVER}" == "nginx" ]]; then
      cat > "${san_cnf}" <<EOF
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
${san_entries}
EOF
      openssl req -x509 -nodes -days 825 \
        -newkey rsa:4096 \
        -keyout "${cert_dir}/vcf9-depot.key" \
        -out    "${cert_dir}/vcf9-depot.crt" \
        -config "${san_cnf}"

    else
      # Apache: CSR + self-sign (mirrors the article workflow)
      local subj="/C=${CERT_COUNTRY}/ST=${CERT_STATE}/L=${CERT_CITY}/O=${CERT_ORG}/OU=${CERT_OU}/CN=${DEPOT_FQDN}"
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
basicConstraints = critical, CA:TRUE
keyUsage = critical, digitalSignature, keyEncipherment, keyCertSign, cRLSign
extendedKeyUsage = serverAuth

[alt_names]
${san_entries}
EOF
      openssl req -new -newkey rsa:2048 -nodes \
        -keyout "${cert_dir}/vcf9-depot.key" \
        -out    "${cert_dir}/vcf9-depot.csr" \
        -subj   "${subj}"

      openssl x509 -req -days 825 -sha256 \
        -in      "${cert_dir}/vcf9-depot.csr" \
        -signkey "${cert_dir}/vcf9-depot.key" \
        -out     "${cert_dir}/vcf9-depot.crt" \
        -extensions v3_req \
        -extfile "${san_cnf}"

      # Verify modulus match
      local cert_mod key_mod
      cert_mod="$(openssl x509 -noout -modulus -in "${cert_dir}/vcf9-depot.crt" | md5sum)"
      key_mod="$(openssl rsa  -noout -modulus -in "${cert_dir}/vcf9-depot.key"  | md5sum)"
      [[ "${cert_mod}" == "${key_mod}" ]] \
        || die "Cert/key modulus mismatch — something went wrong during signing."
      info "Certificate/key modulus match verified."
    fi

    rm -f "${san_cnf}"
  fi

  chmod 600 "${cert_dir}/vcf9-depot.key"
  chmod 644 "${cert_dir}/vcf9-depot.crt"
  chown root:root "${cert_dir}/vcf9-depot.key" "${cert_dir}/vcf9-depot.crt"
  info "Certificate: ${cert_dir}/vcf9-depot.crt"
}

# ---------------------------------------------------------------------------
# Step 5 — Basic authentication
# ---------------------------------------------------------------------------
_htpasswd_file() {
  case "${WEB_SERVER}" in
    nginx)  echo "/etc/nginx/.htpasswd-vcf9" ;;
    apache) echo "/etc/apache2/.htpasswd-vcf9" ;;
  esac
}

create_auth() {
  local auth_file
  auth_file="$(_htpasswd_file)"
  info "Creating basic auth file: ${auth_file}"
  mkdir -p "$(dirname "${auth_file}")"
  htpasswd -cb "${auth_file}" "${DEPOT_USER}" "${DEPOT_PASS}"
  chown root:"${WEB_USER}" "${auth_file}"
  chmod 0640 "${auth_file}"
}

# ---------------------------------------------------------------------------
# Step 6 — Web server configuration
# ---------------------------------------------------------------------------
configure_nginx() {
  local cert_dir auth_file nginx_conf
  cert_dir="$(_cert_dir)"
  auth_file="$(_htpasswd_file)"
  nginx_conf="/etc/nginx/conf.d/vcf9-depot.conf"

  info "Configuring nginx"
  # Remove Ubuntu default site to avoid port conflicts
  rm -f /etc/nginx/sites-enabled/default /etc/nginx/conf.d/default.conf 2>/dev/null || true

  cat > "${nginx_conf}" <<EOF
# VCF 9.1 Offline Depot — nginx (HTTPS + basic auth)
# Generated by ${SCRIPT_NAME} v${SCRIPT_VERSION}
server {
    listen ${DEPOT_PORT} ssl default_server;
    server_name ${DEPOT_FQDN};

    ssl_certificate     ${cert_dir}/vcf9-depot.crt;
    ssl_certificate_key ${cert_dir}/vcf9-depot.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;

    auth_basic "VCF9 Offline Depot";
    auth_basic_user_file ${auth_file};

    root ${WEB_ROOT};
    autoindex on;
    client_max_body_size 0;

    # Serve VCF depot from DEPOT_ROOT (outside WEB_ROOT) via alias
    location /PROD/ {
        alias ${DEPOT_ROOT}/${DEPOT_NAME}/PROD/;
        autoindex on;
    }
}

# HTTP -> HTTPS redirect
server {
    listen ${DEPOT_HTTP_PORT};
    server_name ${DEPOT_FQDN};
    # 🔴 這個 heredoc 是 <<EOF(會展開),所以 nginx 自己的變數一定要跳脫成 \$xxx,
    #    否則 set -u 會以 "unbound variable" 中止。\$request_uri 是 nginx 的變數。
    #    v6 順便把 \$host 換成固定 FQDN:少一個要跳脫的變數,也避免用 IP 直連時
    #    被導到錯誤的 Host。
    return 301 https://${DEPOT_FQDN}:${DEPOT_PORT}\$request_uri;
}
EOF

  nginx -t
  systemctl enable nginx >/dev/null 2>&1 || true; systemctl reload nginx 2>/dev/null || systemctl restart nginx
}

configure_apache() {
  local cert_dir auth_file pkg_mgr
  cert_dir="$(_cert_dir)"
  auth_file="$(_htpasswd_file)"
  pkg_mgr="$(detect_pkg_mgr)"

  info "Configuring Apache2/httpd"

  if [[ "${pkg_mgr}" == "apt" ]]; then
    # ---- Ubuntu / Debian ----
    a2enmod ssl headers
    a2ensite default-ssl
    # Disable plain-HTTP default site (port 80 would otherwise show "It works!")
    a2dissite 000-default 2>/dev/null || true

    cat > "/etc/apache2/sites-available/default-ssl.conf" <<EOF
# VCF 9.1 Offline Depot — Apache2 (HTTPS + basic auth)
# Generated by ${SCRIPT_NAME} v${SCRIPT_VERSION}
<IfModule mod_ssl.c>
  <VirtualHost _default_:${DEPOT_PORT}>
    ServerName ${DEPOT_FQDN}
    DocumentRoot ${WEB_ROOT}

    SSLEngine on
    SSLCertificateFile    ${cert_dir}/vcf9-depot.crt
    SSLCertificateKeyFile ${cert_dir}/vcf9-depot.key

    SSLProtocol           all -SSLv3 -TLSv1 -TLSv1.1
    SSLHonorCipherOrder   off
    Header always set Strict-Transport-Security "max-age=63072000"

    # Depot data lives outside DocumentRoot. Use Alias so Apache can serve it
    # without relying on FollowSymLinks across directory boundaries (avoids 403).
    Alias /PROD/ ${DEPOT_ROOT}/${DEPOT_NAME}/PROD/
    <Directory ${DEPOT_ROOT}/${DEPOT_NAME}/PROD/>
      Options Indexes FollowSymLinks
      AllowOverride None
      AuthType Basic
      AuthName "VCF Depot"
      AuthUserFile ${auth_file}
      Require valid-user
    </Directory>

    <Directory ${WEB_ROOT}>
      Options Indexes FollowSymLinks
      AllowOverride None
      AuthType Basic
      AuthName "VCF Depot"
      AuthUserFile ${auth_file}
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

  else
    # ---- RHEL / CentOS / Rocky / AlmaLinux — httpd ----
    # Move cert dir to a standard httpd location for RHEL
    local rhel_cert_dir="/etc/pki/tls/certs"
    local rhel_key_dir="/etc/pki/tls/private"
    mkdir -p "${rhel_cert_dir}" "${rhel_key_dir}"
    cp "${cert_dir}/vcf9-depot.crt" "${rhel_cert_dir}/vcf9-depot.crt"
    cp "${cert_dir}/vcf9-depot.key" "${rhel_key_dir}/vcf9-depot.key"
    chmod 644 "${rhel_cert_dir}/vcf9-depot.crt"
    chmod 600 "${rhel_key_dir}/vcf9-depot.key"
    # Update path vars so the htpasswd file reference stays valid
    local rhel_auth_file="/etc/httpd/.htpasswd-vcf9"
    cp "${auth_file}" "${rhel_auth_file}"
    chown root:apache "${rhel_auth_file}"
    chmod 0640 "${rhel_auth_file}"

    cat > "/etc/httpd/conf.d/vcf9-depot-ssl.conf" <<EOF
# VCF 9.1 Offline Depot — httpd (HTTPS + basic auth)
# Generated by ${SCRIPT_NAME} v${SCRIPT_VERSION}
Listen ${DEPOT_PORT} https

<VirtualHost _default_:${DEPOT_PORT}>
  ServerName ${DEPOT_FQDN}
  DocumentRoot ${WEB_ROOT}

  SSLEngine on
  SSLCertificateFile  ${rhel_cert_dir}/vcf9-depot.crt
  SSLCertificateKeyFile ${rhel_key_dir}/vcf9-depot.key
  SSLProtocol         all -SSLv3 -TLSv1 -TLSv1.1

  Alias /PROD/ ${DEPOT_ROOT}/${DEPOT_NAME}/PROD/
  <Directory ${DEPOT_ROOT}/${DEPOT_NAME}/PROD/>
    Options Indexes FollowSymLinks
    AllowOverride None
    AuthType Basic
    AuthName "VCF Depot"
    AuthUserFile ${rhel_auth_file}
    Require valid-user
  </Directory>

  ErrorLog  /var/log/httpd/vcf91-depot-error.log
  CustomLog /var/log/httpd/vcf91-depot-access.log combined
</VirtualHost>
EOF

    apachectl configtest
    systemctl enable httpd
    systemctl restart httpd
  fi
}

configure_webserver() {
  case "${WEB_SERVER}" in
    nginx)  configure_nginx  ;;
    apache) configure_apache ;;
  esac
}

# ---------------------------------------------------------------------------
# Step 7 — SELinux (RHEL only)
# ---------------------------------------------------------------------------
configure_selinux() {
  [[ -f /etc/redhat-release ]] || return 0
  command -v getenforce >/dev/null 2>&1 || return 0
  [[ "$(getenforce)" == "Enforcing" ]] || return 0

  info "SELinux Enforcing — applying httpd_sys_content_t to depot path"
  if command -v semanage >/dev/null 2>&1; then
    semanage fcontext -a -t httpd_sys_content_t "${DEPOT_ROOT}/${DEPOT_NAME}(/.*)?" 2>/dev/null || true
    restorecon -Rv "${DEPOT_ROOT}/${DEPOT_NAME}"
    semanage port -a -t http_port_t -p tcp "${DEPOT_PORT}" 2>/dev/null \
      || semanage port -m -t http_port_t -p tcp "${DEPOT_PORT}" 2>/dev/null || true
  else
    warn "semanage not found; skip SELinux context. Install policycoreutils-python-utils."
  fi
}

# ---------------------------------------------------------------------------
# Step 8 — Firewall
# ---------------------------------------------------------------------------
configure_firewall() {
  [[ "${OPEN_FIREWALL}" == "true" ]] || return 0

  local ports="${DEPOT_PORT}/tcp"
  # nginx also needs the HTTP redirect port
  [[ "${WEB_SERVER}" == "nginx" ]] && ports="${DEPOT_PORT}/tcp ${DEPOT_HTTP_PORT}/tcp"

  # firewalld — RHEL / CentOS / Rocky / AlmaLinux
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
    info "firewalld: opening ${ports}"
    for p in ${ports}; do firewall-cmd --permanent --add-port="${p}"; done
    firewall-cmd --reload

  # ufw — Ubuntu / Debian (default on Ubuntu 24.04)
  elif command -v ufw >/dev/null 2>&1; then
    if ufw status 2>/dev/null | grep -q "^Status: active"; then
      info "ufw: allowing ${ports}"
      for p in ${ports}; do ufw allow "${p}"; done
    else
      warn "ufw is installed but NOT active — firewall rules NOT applied."
      warn "To apply manually after enabling ufw:"
      for p in ${ports}; do warn "  sudo ufw allow ${p}"; done
    fi

  else
    warn "No firewall manager found (firewalld / ufw)."
    warn "Open these ports manually if your firewall is active: ${ports}"
  fi
}

# ---------------------------------------------------------------------------
# Step 9 — CA / cert import
# ---------------------------------------------------------------------------
import_ca() {
  [[ "${IMPORT_CA}" == "true" ]] || return 0
  local cert_dir
  cert_dir="$(_cert_dir)"
  info "Importing depot CA into system + Java truststores"
  local importer
  importer="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/import_vcf9depot_ca.sh"
  if [[ -x "${importer}" ]]; then
    if [[ -n "${CA_URL}" ]]; then
      "${importer}" --url-insecure "${CA_URL}"
    else
      "${importer}" --cert "${cert_dir}/vcf9-depot.crt"
    fi
  else
    warn "import_vcf9depot_ca.sh not found alongside this script."
    warn "Run manually: sudo bash import_vcf9depot_ca.sh --cert ${cert_dir}/vcf9-depot.crt"
  fi
}

# ---------------------------------------------------------------------------
# Step 10 — vcf-download-tool
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

generate_depot_id() {
  local tool_bin
  tool_bin="$(find_download_tool_bin || true)"
  [[ -n "${tool_bin}" && -x "${tool_bin}" ]] || return 0
  info "Generating software depot ID"
  "${tool_bin}" configuration generate --software-depot-id || true
}

# ---------------------------------------------------------------------------
# Step 11 — Download helper script
# ---------------------------------------------------------------------------
create_helper_script() {
  local helper="${DEPOT_ROOT}/download-vcf9-binaries.sh"
  local tool_bin
  tool_bin="$(find_download_tool_bin || true)"

  info "Creating download helper: ${helper}"
  cat > "${helper}" <<HELPER
#!/usr/bin/env bash
set -euo pipefail
# Auto-generated by ${SCRIPT_NAME} v${SCRIPT_VERSION}
# Re-run this script any time to download or re-download VCF binaries.

VCF_VERSION="${VCF_VERSION}"
DEPOT_STORE="${DEPOT_ROOT}/${DEPOT_NAME}"
ACTIVATION_CODE_FILE="${ACTIVATION_CODE_FILE}"
TOKEN_FILE="${TOKEN_FILE}"
TOKEN_VALUE="${TOKEN_VALUE}"
DOWNLOAD_TYPE="${DOWNLOAD_TYPE}"
TOOL_BIN="${tool_bin}"

[[ -x "\${TOOL_BIN}" ]] || { echo "[ERROR] vcf-download-tool not found: \${TOOL_BIN}" >&2; exit 1; }

# Determine credential argument (activation-code preferred; token-file fallback)
if [[ -n "\${ACTIVATION_CODE_FILE}" && -f "\${ACTIVATION_CODE_FILE}" ]]; then
  CRED_ARGS="--depot-download-activation-code-file \${ACTIVATION_CODE_FILE}"
elif [[ -n "\${TOKEN_FILE}" && -f "\${TOKEN_FILE}" ]]; then
  CRED_ARGS="--depot-download-token-file \${TOKEN_FILE}"
elif [[ -n "\${TOKEN_VALUE}" ]]; then
  TOKEN_FILE="/tmp/vcf-dl-token-$$.txt"
  printf '%s\n' "\${TOKEN_VALUE}" > "\${TOKEN_FILE}"
  CRED_ARGS="--depot-download-token-file \${TOKEN_FILE}"
else
  echo "[ERROR] No credential found. Set ACTIVATION_CODE_FILE or TOKEN_FILE." >&2
  exit 1
fi

"\${TOOL_BIN}" binaries download \${CRED_ARGS} \\
  --vcf-version   "\${VCF_VERSION}" \\
  --automated-install \\
  --depot-store   "\${DEPOT_STORE}" \\
  --type          "\${DOWNLOAD_TYPE}"
HELPER
  chmod +x "${helper}"
}

run_download_if_requested() {
  [[ "${DOWNLOAD_BINARIES}" == "true" ]] || return 0
  local helper="${DEPOT_ROOT}/download-vcf9-binaries.sh"
  [[ -x "${helper}" ]] || die "Download helper missing: ${helper}"
  info "Downloading VCF ${VCF_VERSION} ${DOWNLOAD_TYPE} binaries"
  "${helper}"
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print_summary() {
  local cert_dir
  cert_dir="$(_cert_dir)"
  local depot_url="https://${DEPOT_FQDN}:${DEPOT_PORT}"

  cat <<EOF

=======================================================================
 VCF 9.1 Offline Depot — DONE   (${SCRIPT_NAME} v${SCRIPT_VERSION})
=======================================================================

  Web server : ${WEB_SERVER}
  Depot URL  : ${depot_url}
  Certificate: ${cert_dir}/vcf9-depot.crt
  Auth user  : ${DEPOT_USER}
  Auth pass  : ${DEPOT_PASS}
  Depot root : ${DEPOT_ROOT}/${DEPOT_NAME}
  Download   : ${DEPOT_ROOT}/download-vcf9-binaries.sh

Next steps:
  1. Copy the cert to the machine running VCF Installer and import it:
       sudo bash import_vcf9depot_ca.sh --cert ${cert_dir}/vcf9-depot.crt
     OR fetch directly from this server (run on VCF Installer host):
       sudo bash import_vcf9depot_ca.sh --url-insecure ${depot_url}

  2. In VCF Installer -> Administration -> Depot Settings:
       URL      : ${depot_url}
       Username : ${DEPOT_USER}
       Password : ${DEPOT_PASS}

  NOTE: "Invalid credentials" in VCF Installer when creds are correct?
        That misleading error means the depot CERTIFICATE has NOT been
        imported into the Java truststore. Import the cert and retry.

EOF
  if [[ "${WEB_SERVER}" == "apache" ]] && [[ -f "${cert_dir}/vcf9-depot.csr" ]]; then
    cat <<EOF
  TIP (Apache only): ${cert_dir}/vcf9-depot.csr is a real CSR.
  Submit it to your internal CA to get a properly signed certificate:
    1. Send ${cert_dir}/vcf9-depot.csr to your CA
    2. Replace ${cert_dir}/vcf9-depot.crt with the signed cert
    3. sudo systemctl restart apache2
EOF
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  require_root
  parse_args "$@"

  info "VCF 9.1 Offline Depot — ${SCRIPT_NAME} v${SCRIPT_VERSION}"

  # --repair: 只修既有 depot 的權限/擁有者/父目錄穿越,不碰其他。
  # 現場救援用(例如換了 --depot-root 到 /userap 後 nginx 回 403)。
  if [[ "${REPAIR_ONLY}" == "true" ]]; then
    info "REPAIR mode — only fixing permissions on ${DEPOT_ROOT}/${DEPOT_NAME}"
    detect_web_user
    fix_depot_permissions
    configure_selinux 2>/dev/null || true   # RHEL: 重套 fcontext
    info "Repair done. Reload web server if needed:  systemctl reload nginx (or httpd/apache2)"
    exit 0
  fi

  info "Web server  : ${WEB_SERVER}"
  info "FQDN        : ${DEPOT_FQDN}"
  info "VCF version : ${VCF_VERSION}"

  install_packages        # 1. apt/yum install (+ JRE if --import-ca)
  setup_data_disk         # 2. format + mount data disk (if --data-disk)
  detect_web_user         # 3. set WEB_USER based on OS + web server
  create_depot_tree       # 4. mkdir /opt/vcf-depot/vcf9/PROD/...
  create_certificate      # 5. openssl cert + key
  create_auth             # 6. htpasswd
  configure_webserver     # 7. nginx.conf or apache2 default-ssl.conf
  configure_selinux       # 8. RHEL only: SELinux fcontext
  configure_firewall      # 9. firewalld (RHEL) or ufw (Ubuntu) or warn
  import_ca               # 10. system + Java truststore (if --import-ca)
  extract_download_tool   # 11. tar xz vcf-download-tool
  generate_depot_id       # 12. vcf-download-tool configuration generate
  create_helper_script    # 13. write download-vcf9-binaries.sh
  run_download_if_requested  # 14. vcf-download-tool binaries download (if --download-binaries)
  print_summary
}

main "$@"
