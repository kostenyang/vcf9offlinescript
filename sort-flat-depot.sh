#!/usr/bin/env bash
# Sort a FLAT folder of manually-downloaded VCF 9.1 files (as a customer would dump
# them from the Broadcom portal) into a proper offline-depot layout:
#     <OUT>/PROD/COMP/<COMPONENT_CODE>/<files>
# and (optionally) lay the metadata layer from the official offline-depot-metadata zip:
#     <OUT>/PROD/metadata/... + PROD/COMP/SDDC_MANAGER_VCF/Compatibility + vsan/hcl
#
# Classifies each file by filename pattern (binaries + their config-schema/depot-manifest).
# Only the 16 install-set components are handled; anything unrecognised is listed and left
# in <OUT>/_unsorted/ for manual review.
#
# Usage:  bash sort-flat-depot.sh <FLAT_DIR> <OUT_DIR> [OFFLINE_DEPOT_METADATA_ZIP]
#   -m   move files (default is copy, safer)
# NOTE: keep LF line endings (sed -i 's/\r$//' sort-flat-depot.sh if edited on Windows).
set -euo pipefail

MODE=copy
if [ "${1:-}" = "-m" ]; then MODE=move; shift; fi
FLAT="${1:?need FLAT input dir}"
OUT="${2:?need OUT depot dir}"
ZIP="${3:-}"
COMP="$OUT/PROD/COMP"
mkdir -p "$COMP"

# filename -> component code. Order matters: more specific patterns first.
classify() {
  local f; f=$(basename "$1")
  shopt -s nocasematch
  case "$f" in
    VMware-VCSA-all-*|VMware-vCenter-Server-Appliance-*|VMware-vlcm-operator-*) echo VCENTER ;;
    nsx-unified-appliance-*)                                echo NSX_T_MANAGER ;;
    VCF-SDDC-Manager-Appliance-*)                           echo SDDC_MANAGER_VCF ;;
    Operations-Cloud-Proxy-*|*-cloud-proxy-*|*cloud-proxy*) echo VCF_OPS_CLOUD_PROXY ;;
    Operations-Appliance-*|Operations-Upgrade-*|VMware_Cloud_Foundation_Operations-*) echo VROPS ;;
    Vcf-License-Server-*)                                   echo VCF_LICENSE_SERVER ;;
    vcf-fleet-lcm-*|*-vcf-fleet-lcm-*)                      echo VCF_FLEET_LCM ;;
    vcf-fleet-depot-*|*-vcf-fleet-depot-*)                  echo DEPOT_SERVICE ;;
    vcf-sddc-lcm-*|*-vcf-sddc-lcm-*)                        echo VCF_SDDC_LCM ;;
    telemetry-acceptor-*|*-telemetry-acceptor-*)            echo TELEMETRY_ACCEPTOR ;;
    salt-raas-*|*-salt-raas-*)                              echo VCF_SALT_RAAS ;;
    salt-*|*-salt-*)                                        echo VCF_SALT ;;
    vidb-*|*-vidb-*)                                        echo VIDB ;;
    vcfa-*|*-vcfa-*)                                        echo VRA ;;
    vcd-migrator-*|*-vcd-migrator-*)                        echo VCF_SERVICE_VCD_MIGRATION_BACKEND ;;
    vcf-services-platform-template-*|vmsp-*|*-vmsp-*)       echo VSP ;;
    VMware-VMvisor-Installer-*)                             echo ESX_HOST ;;
    *) echo "" ;;
  esac
  shopt -u nocasematch
}

placed=0; unsorted=0
while IFS= read -r -d '' file; do
  code=$(classify "$file")
  if [ -n "$code" ]; then
    mkdir -p "$COMP/$code"
    if [ "$MODE" = move ]; then mv -f "$file" "$COMP/$code/"; else cp -f "$file" "$COMP/$code/"; fi
    placed=$((placed+1))
  else
    mkdir -p "$OUT/_unsorted"
    if [ "$MODE" = move ]; then mv -f "$file" "$OUT/_unsorted/"; else cp -f "$file" "$OUT/_unsorted/"; fi
    echo "  [?] 未分類: $(basename "$file")"
    unsorted=$((unsorted+1))
  fi
done < <(find "$FLAT" -maxdepth 1 -type f -print0)

# metadata layer from official zip (contains PROD/metadata + Compatibility + vsan)
if [ -n "$ZIP" ] && [ -f "$ZIP" ]; then
  echo "== laying metadata from $ZIP =="
  tmp=$(mktemp -d)
  python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$ZIP" "$tmp"
  cp -rf "$tmp/PROD/." "$OUT/PROD/"
  rm -rf "$tmp"
fi

echo ""
echo "== done: 歸位 $placed 檔, 未分類 $unsorted 檔 =="
echo "== COMP 元件 =="
ls -1 "$COMP" 2>/dev/null | sed 's/^/   /'
