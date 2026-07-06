#!/usr/bin/env bash
set -euo pipefail

# ===========================================================================
# ubuntu_offline_packages.sh — Offline .deb bundle build + install for Ubuntu
#
# Ubuntu has no install-DVD repo like RHEL, so to bring up an offline VCF
# depot / repo server on an AIR-GAPPED Ubuntu box you must pre-download the
# packages elsewhere and carry them in. This script does both ends:
#
#   --build   : run on an INTERNET-CONNECTED Ubuntu (SAME release as target)
#               downloads the FULL dependency closure of the requested
#               packages as .deb files and tars them into a bundle.
#
#   --install : run on the AIR-GAPPED Ubuntu
#               extracts the bundle and installs every .deb with dpkg
#               (no internet needed).
#
# IMPORTANT: build on the SAME Ubuntu release + architecture as the target
#            (e.g. build on Ubuntu 24.04 amd64 for a 24.04 amd64 target).
#
# Default packages = what an nginx-based VCF depot / RHEL-style repo server
# needs: nginx apache2-utils openssl. Override with --packages.
#
# Usage:
#   # on the internet box:
#   sudo bash ubuntu_offline_packages.sh --build \
#     --packages "nginx apache2-utils openssl" \
#     --output /root/ubuntu-nginx-offline.tar.gz
#
#   # carry the tar.gz to the air-gapped box, then:
#   sudo bash ubuntu_offline_packages.sh --install \
#     --bundle /root/ubuntu-nginx-offline.tar.gz
# ===========================================================================

SCRIPT_NAME="$(basename "$0")"
SCRIPT_VERSION="1.0.0"

MODE=""
PACKAGES="nginx apache2-utils openssl"
OUTPUT="/root/ubuntu-offline-packages.tar.gz"
BUNDLE=""

green()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$*"; }
red()    { printf '\033[0;31m%s\033[0m\n' "$*" >&2; }
info()   { green   "[INFO] $*"; }
warn()   { yellow  "[WARN] $*"; }
die()    { red     "[ERROR] $*"; exit 1; }
ok()     { green   "[ OK ] $*"; }

usage() {
  cat <<EOF
Usage:
  sudo bash ${SCRIPT_NAME} --build   [--packages "..."] [--output FILE]
  sudo bash ${SCRIPT_NAME} --install [--bundle FILE]

Modes:
  --build              Download the full .deb dependency closure + tar it.
                       Run on an INTERNET-connected Ubuntu (same release as target).
  --install            Extract the bundle + dpkg-install offline.
                       Run on the AIR-GAPPED Ubuntu.

Options:
  --packages "P1 P2"   Packages to bundle. Default: "${PACKAGES}"
  --output FILE        Output tarball (build). Default: ${OUTPUT}
  --bundle FILE        Input tarball (install).
  --help               Show this help

Notes:
  * Build on the SAME Ubuntu release + arch as the target box.
  * Default packages suit an nginx VCF depot / repo server.
EOF
}

require_root() { [[ "${EUID}" -eq 0 ]] || die "Run as root (sudo)."; }

require_ubuntu() {
  [[ -f /etc/os-release ]] || die "Not Ubuntu"
  . /etc/os-release
  [[ "${ID:-}" == "ubuntu" || "${ID_LIKE:-}" == *debian* ]] \
    || die "This script targets Ubuntu/Debian (found ID=${ID:-?}). For RHEL use setup_rhel_offline_all.sh."
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --build)     MODE="build";      shift 1 ;;
      --install)   MODE="install";    shift 1 ;;
      --packages)  PACKAGES="${2:-}"; shift 2 ;;
      --output)    OUTPUT="${2:-}";   shift 2 ;;
      --bundle)    BUNDLE="${2:-}";   shift 2 ;;
      --help|-h)   usage; exit 0 ;;
      *) die "Unknown argument: $1 (run with --help)" ;;
    esac
  done
  [[ -n "${MODE}" ]] || die "Specify --build or --install"
}

# ---------------------------------------------------------------------------
# BUILD — download full dependency closure as .deb, then tar
# ---------------------------------------------------------------------------
do_build() {
  local rel arch
  . /etc/os-release; rel="${VERSION_ID}"
  arch="$(dpkg --print-architecture)"
  info "Build host: Ubuntu ${rel} ${arch}"
  info "Packages  : ${PACKAGES}"

  local work; work="$(mktemp -d)"
  local debs="${work}/debs"
  mkdir -p "${debs}"

  info "Refreshing apt metadata"
  apt-get update -y >/dev/null 2>&1 || warn "apt-get update had warnings"

  # Resolve the FULL recursive dependency closure (real packages only).
  info "Resolving dependency closure (this can take a moment)"
  local closure
  closure="$(apt-cache depends --recurse --no-recommends --no-suggests \
      --no-conflicts --no-breaks --no-replaces --no-enhances ${PACKAGES} 2>/dev/null \
      | grep '^[a-zA-Z0-9]' | sort -u)"

  local n=0 fail=0
  cd "${debs}"
  for p in ${closure}; do
    # skip pure virtual packages (no candidate) quietly
    if apt-get download "${p}" >/dev/null 2>&1; then
      n=$((n+1))
    else
      fail=$((fail+1))
    fi
  done
  local count; count="$(ls -1 "${debs}"/*.deb 2>/dev/null | wc -l)"
  ok "Downloaded ${count} .deb files (${fail} virtual/skipped)"
  [[ "${count}" -gt 0 ]] || die "No .deb files downloaded — check internet / package names"

  # Manifest for reference
  {
    echo "# ubuntu_offline_packages bundle"
    echo "# built: Ubuntu ${rel} ${arch}"
    echo "# packages requested: ${PACKAGES}"
    echo "# deb count: ${count}"
  } > "${work}/MANIFEST.txt"

  info "Creating bundle: ${OUTPUT}"
  tar -czf "${OUTPUT}" -C "${work}" debs MANIFEST.txt
  rm -rf "${work}"
  local sz; sz="$(du -h "${OUTPUT}" | cut -f1)"
  ok "Bundle ready: ${OUTPUT} (${sz}, ${count} debs)"

  cat <<EOF

Next: carry ${OUTPUT} to the air-gapped Ubuntu box (same ${rel}/${arch}) and run:
  sudo bash ${SCRIPT_NAME} --install --bundle $(basename "${OUTPUT}")
EOF
}

# ---------------------------------------------------------------------------
# INSTALL — extract bundle + dpkg install (offline)
# ---------------------------------------------------------------------------
do_install() {
  [[ -n "${BUNDLE}" ]] || die "--install needs --bundle FILE"
  [[ -f "${BUNDLE}" ]] || die "Bundle not found: ${BUNDLE}"

  local work; work="$(mktemp -d)"
  info "Extracting ${BUNDLE}"
  tar -xzf "${BUNDLE}" -C "${work}"
  local debs="${work}/debs"
  [[ -d "${debs}" ]] || die "Bundle has no debs/ directory"
  local count; count="$(ls -1 "${debs}"/*.deb 2>/dev/null | wc -l)"
  info "Installing ${count} .deb packages (offline, dpkg)"

  # dpkg twice to resolve install ordering, then configure any half-installed
  dpkg -i "${debs}"/*.deb >/dev/null 2>&1 || true
  dpkg -i "${debs}"/*.deb >/dev/null 2>&1 || true
  dpkg --configure -a >/dev/null 2>&1 || true

  rm -rf "${work}"

  # verify
  info "Verifying"
  local okall=1
  for p in ${PACKAGES}; do
    if dpkg -l "${p}" 2>/dev/null | grep -q '^ii'; then
      ok "installed: ${p}"
    else
      warn "NOT installed: ${p}"; okall=0
    fi
  done
  [[ "${okall}" == "1" ]] && ok "All requested packages installed offline" \
    || die "Some packages missing — rebuild the bundle on a matching Ubuntu release"
}

main() {
  require_root
  parse_args "$@"
  require_ubuntu
  info "${SCRIPT_NAME} v${SCRIPT_VERSION} — mode: ${MODE}"
  case "${MODE}" in
    build)   do_build ;;
    install) do_install ;;
  esac
}

main "$@"
