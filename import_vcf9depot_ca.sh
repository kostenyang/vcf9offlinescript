#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
TMP_CERT=""
ALIAS_NAME="vcf9depot-ca"

usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} --cert /path/to/ca.crt
       ${SCRIPT_NAME} --url https://vcf9depotserver.home.lab:443/path/to/ca.crt
       ${SCRIPT_NAME} --url-insecure https://vcf9depotserver.home.lab:443/ignored-path

This script imports a CA certificate into the system trust store and into
any discovered Java "cacerts" keystores (attempts common JVM locations).
Run as root on the target machine (e.g., SDDC Manager or VCF appliance).

Options:
  --url           Fetch cert via HTTPS (uses curl and verifies TLS).
  --url-insecure  Fetch cert from a server with a self-signed cert using
                  openssl s_client (no TLS verification).
EOF
}

require_root() { [[ ${EUID} -eq 0 ]] || { echo "Run as root" >&2; exit 1; } }

fetch_cert_from_url() {
  local url="$1" out="$2"
  command -v curl >/dev/null 2>&1 || { echo "curl required to fetch certificate" >&2; return 1; }
  curl -fsSL "$url" -o "$out"
}

# Fetch server certificate using openssl s_client (useful for self-signed)
fetch_cert_insecure_from_url() {
  local url="$1" out="$2"
  # Strip protocol and path to get host:port
  local hostport host port
  hostport=$(echo "$url" | sed -E 's#https?://##' | cut -d'/' -f1)
  host=$(echo "$hostport" | cut -d: -f1)
  port=$(echo "$hostport" | cut -s -d: -f2)
  port=${port:-443}
  command -v openssl >/dev/null 2>&1 || { echo "openssl required to fetch certificate" >&2; return 1; }
  echo "Fetching certificate from ${host}:${port} (insecure)"
  openssl s_client -connect "${host}:${port}" -servername "${host}" </dev/null 2>/dev/null \
    | sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' > "$out"
  # basic validation
  if [ ! -s "$out" ]; then
    echo "Failed to retrieve certificate from ${host}:${port}" >&2
    return 2
  fi
}

detect_distro() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    echo "$ID"
  else
    uname -s
  fi
}

install_ca_system() {
  local certfile="$1"
  local id
  id=$(detect_distro)
  case "$id" in
    ubuntu|debian)
      mkdir -p /usr/local/share/ca-certificates
      cp "$certfile" "/usr/local/share/ca-certificates/${ALIAS_NAME}.crt"
      update-ca-certificates
      ;;
    rhel|centos|fedora|rocky|almalinux)
      mkdir -p /etc/pki/ca-trust/source/anchors
      cp "$certfile" "/etc/pki/ca-trust/source/anchors/${ALIAS_NAME}.crt"
      update-ca-trust extract
      ;;
    sles|suse)
      mkdir -p /etc/pki/trust/anchors
      cp "$certfile" "/etc/pki/trust/anchors/${ALIAS_NAME}.crt"
      update-ca-certificates
      ;;
    *)
      echo "Unknown distro ($id). Attempting generic install: copy to /usr/local/share/ca-certificates and run update-ca-certificates if available." >&2
      cp "$certfile" "/usr/local/share/ca-certificates/${ALIAS_NAME}.crt" || true
      command -v update-ca-certificates >/dev/null 2>&1 && update-ca-certificates || true
      command -v update-ca-trust >/dev/null 2>&1 && update-ca-trust extract || true
      ;;
  esac
}

find_java_cacerts() {
  # Look for common cacerts locations
  local paths=( "/etc/ssl/certs/java/cacerts" "/usr/lib/jvm" "/usr/java" "/usr/lib/jvm/*/lib/security/cacerts" )
  local found=()
  for p in "${paths[@]}"; do
    for f in $(ls -d ${p} 2>/dev/null || true); do
      if [ -d "$f" ]; then
        # search inside
        while IFS= read -r file; do
          found+=("$file")
        done < <(find "$f" -type f -name cacerts 2>/dev/null || true)
      elif [ -f "$p" ] && [ "$(basename "$p")" = "cacerts" ]; then
        found+=("$p")
      fi
    done
  done
  # unique
  printf "%s\n" "${found[@]}" | sort -u
}

import_into_cacerts() {
  local certfile="$1"
  local cacertpath
  local keytool
  keytool=$(command -v keytool || true)
  if [ -z "$keytool" ]; then
    echo "keytool not found; skipping Java cacerts import" >&2
    return 0
  fi

  mapfile -t cacerts < <(find_java_cacerts)
  if [ ${#cacerts[@]} -eq 0 ]; then
    echo "No Java cacerts found; skipping Java keystore import" >&2
    return 0
  fi

  for cacertpath in "${cacerts[@]}"; do
    echo "Processing Java keystore: ${cacertpath}"
    cp -a "${cacertpath}" "${cacertpath}.bak-$(date +%s)" || true
    # try default password first
    if "$keytool" -list -keystore "${cacertpath}" -storepass changeit >/dev/null 2>&1; then
      echo "Using default password 'changeit' for ${cacertpath}"
      # delete existing alias if present
      "$keytool" -delete -alias "${ALIAS_NAME}" -keystore "${cacertpath}" -storepass changeit >/dev/null 2>&1 || true
      "$keytool" -importcert -trustcacerts -alias "${ALIAS_NAME}" -file "${certfile}" -keystore "${cacertpath}" -storepass changeit -noprompt
    else
      echo "Could not use default password for ${cacertpath}; attempting interactive import. If this fails, import manually with keytool." >&2
      "$keytool" -importcert -trustcacerts -alias "${ALIAS_NAME}" -file "${certfile}" -keystore "${cacertpath}" || true
    fi
  done
}

main() {
  require_root
  if [ $# -lt 2 ]; then
    usage; exit 1
  fi

  case "$1" in
    --cert) shift; TMP_CERT="$1"; ;;
    --url) shift; TMP_CERT="/tmp/${ALIAS_NAME}.crt"; fetch_cert_from_url "$1" "$TMP_CERT" || exit 2; ;;
    --url-insecure) shift; TMP_CERT="/tmp/${ALIAS_NAME}.crt"; fetch_cert_insecure_from_url "$1" "$TMP_CERT" || exit 2; ;;
    *) usage; exit 1 ;;
  esac

  if [ ! -f "$TMP_CERT" ]; then
    echo "Certificate file not found: $TMP_CERT" >&2; exit 1
  fi

  install_ca_system "$TMP_CERT"
  import_into_cacerts "$TMP_CERT"

  echo "Import complete."
  echo "System CA store and discovered Java cacerts (if any) updated."
}

main "$@"
