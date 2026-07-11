#!/usr/bin/env bash
set -euo pipefail

# ===========================================================================
# import_vcf9depot_ca.sh — Import VCF 9 Offline Depot CA Certificate
#
# Imports a self-signed depot certificate into:
#   1. The OS system trust store
#      - Ubuntu / Debian  : update-ca-certificates
#      - RHEL / Rocky     : update-ca-trust
#      - Photon OS        : c_rehash  (VCF Installer / OPS / SDDC Mgr run here)
#   2. ALL discovered Java cacerts keystores
#      - Generic JVM locations (/usr/lib/jvm, /usr/java, ...)
#      - VMware / Broadcom bundled JREs (/opt/vmware, /usr/lib/vmware*)
#      - VCF Installer bundled JRE
#      - VCF OPS (Aria Operations) bundled JRE
#      - SDDC Manager bundled JRE
#   3. (Optional) Restart VCF component services after import
#      - --vcf-installer : restart VCF Installer service
#      - --vcf-ops       : restart Aria Operations (VCF OPS) services
#      - --sddc-manager  : restart SDDC Manager services
#
# Run as root on the TARGET machine (VCF Installer appliance, SDDC Manager,
# VCF OPS appliance, or any host that needs to reach the offline depot).
#
# Compatible with: create_vcf9_depot_server_v5.sh  (and v4 variants)
# ===========================================================================

SCRIPT_NAME="$(basename "$0")"
SCRIPT_VERSION="2.0.0"
TMP_CERT=""
ALIAS_NAME="vcf9depot-ca"

# --- component flags ---
IMPORT_VCF_INSTALLER="false"
IMPORT_VCF_OPS="false"
IMPORT_SDDC_MANAGER="false"
RESTART_SERVICES="true"       # set false with --no-restart

# ---------------------------------------------------------------------------
# Colour helpers
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
Usage:
  ${SCRIPT_NAME} --cert   /path/to/depot.crt
  ${SCRIPT_NAME} --url    https://vcf91-depot.lab/depot.crt
  ${SCRIPT_NAME} --url-insecure https://vcf91-depot.lab

Run as root on the machine that needs to trust the depot certificate.
Common targets: VCF Installer appliance, SDDC Manager, VCF OPS appliance.

Certificate source (one required):
  --cert PATH          Path to a local PEM certificate file
  --url  URL           Fetch cert via HTTPS (TLS verified)
  --url-insecure URL   Fetch server cert via openssl s_client (no TLS verify)
                       Useful when the depot itself is the only self-signed source

VCF component options (add targeted JRE paths + service restart):
  --vcf-installer      Include VCF Installer bundled JRE paths
  --vcf-ops            Include VCF OPS (Aria Operations) bundled JRE paths
  --sddc-manager       Include SDDC Manager bundled JRE paths
  --all-components     Short for --vcf-installer --vcf-ops --sddc-manager

Service restart:
  --no-restart         Skip service restarts after import (default: restart)

Alias:
  --alias NAME         keytool alias name. Default: ${ALIAS_NAME}

Examples:
  # Run on VCF Installer appliance — import cert + restart installer service
  sudo bash ${SCRIPT_NAME} --cert /tmp/vcf9-depot.crt --vcf-installer

  # Run on SDDC Manager — fetch cert from depot server directly
  sudo bash ${SCRIPT_NAME} --url-insecure https://vcf91-depot.lab --sddc-manager

  # Run on VCF OPS appliance
  sudo bash ${SCRIPT_NAME} --cert /tmp/vcf9-depot.crt --vcf-ops

  # Import everywhere, restart nothing (for testing)
  sudo bash ${SCRIPT_NAME} --cert /tmp/vcf9-depot.crt --all-components --no-restart
EOF
}

# ---------------------------------------------------------------------------
require_root() { [[ "${EUID}" -eq 0 ]] || die "Run as root (sudo)."; }

parse_args() {
  [[ $# -ge 1 ]] || { usage; exit 1; }

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cert)           shift; TMP_CERT="$1";                        shift ;;
      --url)            shift
                        TMP_CERT="/tmp/${ALIAS_NAME}.crt"
                        fetch_cert_from_url "$1" "${TMP_CERT}" || exit 2
                        shift ;;
      --url-insecure)   shift
                        TMP_CERT="/tmp/${ALIAS_NAME}.crt"
                        fetch_cert_insecure_from_url "$1" "${TMP_CERT}" || exit 2
                        shift ;;
      --vcf-installer)  IMPORT_VCF_INSTALLER="true";                 shift ;;
      --vcf-ops)        IMPORT_VCF_OPS="true";                       shift ;;
      --sddc-manager)   IMPORT_SDDC_MANAGER="true";                  shift ;;
      --all-components) IMPORT_VCF_INSTALLER="true"
                        IMPORT_VCF_OPS="true"
                        IMPORT_SDDC_MANAGER="true";                  shift ;;
      --no-restart)     RESTART_SERVICES="false";                    shift ;;
      --alias)          shift; ALIAS_NAME="$1";                      shift ;;
      --help|-h)        usage; exit 0 ;;
      *) die "Unknown argument: $1  (run with --help)" ;;
    esac
  done

  [[ -n "${TMP_CERT}" ]] || { usage; die "Provide --cert, --url, or --url-insecure"; }
  [[ -f "${TMP_CERT}" ]] || die "Certificate file not found: ${TMP_CERT}"
}

# ---------------------------------------------------------------------------
# Certificate acquisition
# ---------------------------------------------------------------------------
fetch_cert_from_url() {
  local url="$1" out="$2"
  command -v curl >/dev/null 2>&1 || die "curl is required to fetch the certificate"
  info "Fetching certificate from ${url}"
  curl -fsSL "${url}" -o "${out}"
}

fetch_cert_insecure_from_url() {
  local url="$1" out="$2"
  local hostport host port
  hostport="$(echo "${url}" | sed -E 's#https?://##' | cut -d'/' -f1)"
  host="$(echo "${hostport}" | cut -d: -f1)"
  port="$(echo "${hostport}" | cut -s -d: -f2)"
  port="${port:-443}"

  command -v openssl >/dev/null 2>&1 || die "openssl is required to fetch the certificate"
  info "Fetching server certificate from ${host}:${port} (TLS not verified)"
  openssl s_client -connect "${host}:${port}" -servername "${host}" \
    </dev/null 2>/dev/null \
    | sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' > "${out}"

  [[ -s "${out}" ]] || die "Failed to retrieve certificate from ${host}:${port}"
}

# ---------------------------------------------------------------------------
# Detect OS
# ---------------------------------------------------------------------------
detect_distro() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    echo "${ID:-unknown}"
  else
    uname -s | tr '[:upper:]' '[:lower:]'
  fi
}

# ---------------------------------------------------------------------------
# Step 1 — OS system trust store
# ---------------------------------------------------------------------------
install_ca_system() {
  local certfile="$1"
  local distro
  distro="$(detect_distro)"
  info "System trust store: distro=${distro}"

  case "${distro}" in
    ubuntu|debian)
      mkdir -p /usr/local/share/ca-certificates
      cp "${certfile}" "/usr/local/share/ca-certificates/${ALIAS_NAME}.crt"
      update-ca-certificates
      ok "System trust store updated (update-ca-certificates)"
      ;;

    rhel|centos|fedora|rocky|almalinux|ol)
      mkdir -p /etc/pki/ca-trust/source/anchors
      cp "${certfile}" "/etc/pki/ca-trust/source/anchors/${ALIAS_NAME}.crt"
      update-ca-trust extract
      ok "System trust store updated (update-ca-trust)"
      ;;

    # Photon OS — used by VCF Installer, SDDC Manager, VCF OPS appliances
    photon)
      local pem_dir="/etc/ssl/certs"
      mkdir -p "${pem_dir}"
      cp "${certfile}" "${pem_dir}/${ALIAS_NAME}.pem"
      if command -v c_rehash >/dev/null 2>&1; then
        c_rehash "${pem_dir}" >/dev/null
        ok "System trust store updated (c_rehash)"
      elif command -v rehash_ca_certificates.sh >/dev/null 2>&1; then
        # VCF Installer / SDDC Manager Photon images ship rehash_ca_certificates.sh
        # instead of c_rehash. Without this, the system (OpenSSL) trust store is NOT
        # updated and lcm.service reports a misleading "invalid username or password"
        # when connecting to an HTTPS offline depot with a self-signed cert.
        rehash_ca_certificates.sh >/dev/null 2>&1
        ok "System trust store updated (rehash_ca_certificates.sh)"
      else
        warn "Neither c_rehash nor rehash_ca_certificates.sh found on Photon OS; cert only copied to ${pem_dir}/${ALIAS_NAME}.pem"
      fi
      # Photon OS 4.0+ also supports update-ca-trust
      if command -v update-ca-trust >/dev/null 2>&1; then
        mkdir -p /etc/pki/ca-trust/source/anchors
        cp "${certfile}" "/etc/pki/ca-trust/source/anchors/${ALIAS_NAME}.crt"
        update-ca-trust extract
        ok "Photon OS update-ca-trust also applied"
      fi
      ;;

    sles|suse|opensuse*)
      mkdir -p /etc/pki/trust/anchors
      cp "${certfile}" "/etc/pki/trust/anchors/${ALIAS_NAME}.crt"
      update-ca-certificates
      ok "System trust store updated (SUSE update-ca-certificates)"
      ;;

    *)
      warn "Unknown distro (${distro}); attempting generic system CA install"
      if command -v update-ca-certificates >/dev/null 2>&1; then
        mkdir -p /usr/local/share/ca-certificates
        cp "${certfile}" "/usr/local/share/ca-certificates/${ALIAS_NAME}.crt"
        update-ca-certificates
      elif command -v update-ca-trust >/dev/null 2>&1; then
        mkdir -p /etc/pki/ca-trust/source/anchors
        cp "${certfile}" "/etc/pki/ca-trust/source/anchors/${ALIAS_NAME}.crt"
        update-ca-trust extract
      else
        warn "No CA update command found; skip system trust store update."
      fi
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Step 2 — Java cacerts discovery
# ---------------------------------------------------------------------------
find_java_cacerts() {
  # Base search directories — generic JVM locations
  local search_dirs=(
    "/etc/ssl/certs/java"           # Debian/Ubuntu system Java
    "/usr/lib/jvm"                  # OpenJDK on most Linux distros
    "/usr/java"                     # Oracle JDK legacy
    "/usr/local/lib/jvm"
  )

  # VMware / Broadcom product directories (all VCF components run here)
  # We search broadly so new product versions are found automatically.
  local vmware_roots=(
    "/opt/vmware"
    "/usr/lib/vmware"
    "/usr/lib/vmware-vcops"         # Aria Operations (VCF OPS)
    "/usr/lib/vmware-vum-server"    # VUM / SDDC Manager update components
    "/usr/lib/vmware-updatemgr"
    "/opt/vmware/vcf"               # VCF components (Installer, SDDC Mgr, ...)
  )

  # VCF Installer specific (component-gated to avoid slow scans on non-installer hosts)
  local vcf_installer_paths=(
    "/opt/vmware/vcf/installer/jre/lib/security/cacerts"
    "/opt/vmware/vcf/lcm/jre/lib/security/cacerts"
    "/opt/vmware/vcf/installer/embedded/jre/lib/security/cacerts"
  )

  # VCF OPS / Aria Operations specific
  local vcf_ops_paths=(
    "/usr/lib/vmware-vcops/java/jre/lib/security/cacerts"
    "/usr/lib/vmware-vcops/jre/lib/security/cacerts"
    "/opt/vmware/vcops/jre/lib/security/cacerts"
    "/usr/lib/vmware-vcops/java/lib/security/cacerts"
  )

  # SDDC Manager specific
  local sddc_manager_paths=(
    "/opt/vmware/vcf/sddc-manager/jre/lib/security/cacerts"
    "/opt/vmware/sddc-manager/jre/lib/security/cacerts"
    "/opt/vmware/vcf/sddc-manager-ui/jre/lib/security/cacerts"
  )

  local found=()

  # --- Add well-known single-file paths (component-gated) ---
  local explicit_paths=()
  [[ "${IMPORT_VCF_INSTALLER}" == "true" ]] && explicit_paths+=("${vcf_installer_paths[@]}")
  [[ "${IMPORT_VCF_OPS}"       == "true" ]] && explicit_paths+=("${vcf_ops_paths[@]}")
  [[ "${IMPORT_SDDC_MANAGER}"  == "true" ]] && explicit_paths+=("${sddc_manager_paths[@]}")

  for p in "${explicit_paths[@]}"; do
    if [[ -f "${p}" ]]; then
      found+=("${p}")
    fi
  done

  # --- Broad directory scan ---
  local all_dirs=("${search_dirs[@]}")
  # Always scan generic JVM dirs.
  # Add VMware dirs when any component flag is set (avoids slow scans otherwise).
  if [[ "${IMPORT_VCF_INSTALLER}" == "true" || \
        "${IMPORT_VCF_OPS}"       == "true" || \
        "${IMPORT_SDDC_MANAGER}"  == "true" ]]; then
    all_dirs+=("${vmware_roots[@]}")
  fi

  for d in "${all_dirs[@]}"; do
    [[ -d "${d}" ]] || continue
    while IFS= read -r f; do
      found+=("${f}")
    done < <(find "${d}" -type f -name "cacerts" 2>/dev/null)
  done

  # Deduplicate and emit
  printf '%s\n' "${found[@]:-}" | sort -u | grep -v '^$' || true
}

# ---------------------------------------------------------------------------
# Step 3 — Import into each Java cacerts
# ---------------------------------------------------------------------------
import_into_cacerts() {
  local certfile="$1"
  local keytool
  keytool="$(command -v keytool 2>/dev/null || true)"

  if [[ -z "${keytool}" ]]; then
    warn "keytool not found — skipping Java keystore import."
    warn "Install a JRE (e.g. sudo apt install default-jre-headless) and re-run."
    return 0
  fi

  local -a cacerts
  mapfile -t cacerts < <(find_java_cacerts)

  if [[ ${#cacerts[@]} -eq 0 ]]; then
    warn "No Java cacerts files found — skipping Java keystore import."
    return 0
  fi

  info "Found ${#cacerts[@]} Java keystore(s) to update"
  local ok_count=0 fail_count=0

  for cacertpath in "${cacerts[@]}"; do
    [[ -f "${cacertpath}" ]] || continue
    info "Processing: ${cacertpath}"

    # Backup before modifying
    cp -a "${cacertpath}" "${cacertpath}.bak-$(date +%s)" 2>/dev/null || true

    # Try default 'changeit' password first (covers 99% of cases)
    if "${keytool}" -list -keystore "${cacertpath}" -storepass changeit >/dev/null 2>&1; then
      "${keytool}" -delete \
        -alias "${ALIAS_NAME}" \
        -keystore "${cacertpath}" \
        -storepass changeit \
        -noprompt >/dev/null 2>&1 || true

      if "${keytool}" -importcert -trustcacerts \
          -alias "${ALIAS_NAME}" \
          -file  "${certfile}" \
          -keystore "${cacertpath}" \
          -storepass changeit \
          -noprompt; then
        ok "Imported → ${cacertpath}"
        (( ok_count++ )) || true
      else
        warn "Import failed: ${cacertpath}"
        (( fail_count++ )) || true
      fi
    else
      warn "Default password 'changeit' rejected for ${cacertpath}; skipping."
      warn "Run manually: keytool -importcert -alias ${ALIAS_NAME} -file ${certfile} -keystore ${cacertpath}"
      (( fail_count++ )) || true
    fi
  done

  info "Java keystore import: ${ok_count} succeeded, ${fail_count} skipped/failed"
}

# ---------------------------------------------------------------------------
# Step 4 — Restart VCF component services
# ---------------------------------------------------------------------------
restart_service() {
  local svc="$1"
  if systemctl is-active --quiet "${svc}" 2>/dev/null; then
    info "Restarting ${svc}"
    systemctl restart "${svc}" && ok "${svc} restarted" || warn "Failed to restart ${svc}"
  elif systemctl list-unit-files --quiet "${svc}.service" 2>/dev/null | grep -q "${svc}"; then
    info "${svc} is not currently running — starting it"
    systemctl start "${svc}" && ok "${svc} started" || warn "Failed to start ${svc}"
  else
    warn "Service ${svc} not found on this host — skipping"
  fi
}

restart_vcf_services() {
  [[ "${RESTART_SERVICES}" == "true" ]] || { info "Service restart skipped (--no-restart)"; return 0; }

  # VCF Installer services
  if [[ "${IMPORT_VCF_INSTALLER}" == "true" ]]; then
    info "Restarting VCF Installer services"
    for svc in vcf-installer vcf-installer-ui; do
      restart_service "${svc}"
    done
  fi

  # VCF OPS / Aria Operations services
  if [[ "${IMPORT_VCF_OPS}" == "true" ]]; then
    info "Restarting VCF OPS (Aria Operations) services"
    for svc in vmware-vcops-suite-api vmware-vcops-watchdog vmware-vcops-cluster; do
      restart_service "${svc}"
    done
  fi

  # SDDC Manager services
  if [[ "${IMPORT_SDDC_MANAGER}" == "true" ]]; then
    info "Restarting SDDC Manager services"
    for svc in vcf-sddc-manager-ui vcf-sddc-manager sddc-manager-ui; do
      restart_service "${svc}"
    done
  fi
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print_summary() {
  local vcf_flags=""
  [[ "${IMPORT_VCF_INSTALLER}" == "true" ]] && vcf_flags+=" vcf-installer"
  [[ "${IMPORT_VCF_OPS}"       == "true" ]] && vcf_flags+=" vcf-ops"
  [[ "${IMPORT_SDDC_MANAGER}"  == "true" ]] && vcf_flags+=" sddc-manager"
  [[ -z "${vcf_flags}" ]] && vcf_flags=" (generic JVM scan only)"

  cat <<EOF

=======================================================================
 import_vcf9depot_ca.sh v${SCRIPT_VERSION} — DONE
=======================================================================
  Certificate : ${TMP_CERT}
  Alias       : ${ALIAS_NAME}
  Components  :${vcf_flags}
  Restart     : ${RESTART_SERVICES}

If VCF Installer still shows "invalid credentials" after this import:
  1. Verify the alias was imported:
       keytool -list -cacerts -storepass changeit | grep -i ${ALIAS_NAME}
  2. Re-run with the correct component flag:
       sudo bash ${SCRIPT_NAME} --cert <cert> --vcf-installer
  3. Restart the VCF Installer service manually:
       sudo systemctl restart vcf-installer
EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  require_root
  parse_args "$@"

  info "${SCRIPT_NAME} v${SCRIPT_VERSION}"
  info "Certificate: ${TMP_CERT}"

  install_ca_system     "${TMP_CERT}"   # OS system trust store
  import_into_cacerts   "${TMP_CERT}"   # all discovered Java cacerts
  restart_vcf_services                  # restart services if requested
  print_summary
}

main "$@"
