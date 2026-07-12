#!/usr/bin/env bash
#
# my-vcfdepot.sh - roll-your-own COMPLETE offline VCF depot builder (Linux, no pwsh).
#
# Bash/curl/jq port of My-VcfDepot.ps1. Reads the full Broadcom productVersionCatalog
# directly with the download TOKEN (no activation code, no vcf-download-tool version cap;
# lists all ~49 components vs the tool's ~24) and builds a ready-to-serve offline depot.
#
# Builds (token + public endpoints only):
#   <out>/PROD/COMP/<component>/<fileName>                    binaries  (dl.broadcom.com/<TOKEN>)
#   <out>/PROD/metadata/productVersionCatalog/v1/*.json|.sig  catalog   (dl.broadcom.com/<TOKEN>)
#   <out>/PROD/metadata/manifest/v1/vcfManifest.json          manifest  (dl.broadcom.com/<TOKEN>)
#   <out>/PROD/metadata/vsan/hcl/all.json                     vSAN HCL  (partnerweb.vmware.com, PUBLIC)
#   <out>/PROD/metadata/vsan/hcl/lastupdatedtime.json         generated from all.json
# Does NOT build Compatibility/ (vvs.broadcom.com needs the vvs OAuth / activation code;
# it is day-2 interop data and does not gate bring-up).
#
# Requires: bash, curl, jq, sha256sum, awk.
#
# Usage:
#   ./my-vcfdepot.sh -t token.txt --summary
#   ./my-vcfdepot.sh -t token.txt --type INSTALL --summary
#   ./my-vcfdepot.sh -t token.txt --component VKR --filename-like '*1.33*' --summary
#   ./my-vcfdepot.sh -t token.txt --build-depot --latest-only -o /opt/vcf-depot/vcf9
#   ./my-vcfdepot.sh -t token.txt --component VSP,NSX_T_MANAGER --type INSTALL --latest-only --download -o /depot
set -euo pipefail

TOKEN_FILE=""; COMPONENT=""; TYPE=""; FNLIKE=""; OUTDIR="./vcf9-depot"
LATEST=0; SUMMARY=0; DOWNLOAD=0; METADATA=0; BUILD=0; NORESUME=0

# Convenience component set for --build-depot (avoids pulling all ~2.8 TB).
# NOTE: this is a hand-curated helper list, NOT the authoritative VCF-Installer set.
# The AUTHORITATIVE offline-install set is whatever the official tool downloads with
#   vcf-download-tool binaries download --automated-install -t INSTALL --vcf-version 9.1.0.0
# (16 components incl. VRA/VROPS/VCF_SERVICE_VCD_MIGRATION_BACKEND). Validate any depot
# built from MGMT_SET against a real VCF Installer before shipping it to a customer.
MGMT_SET="DEPOT_SERVICE,ESX_HOST,NSX_ALB,NSX_T_MANAGER,SDDC_MANAGER_VCF,TELEMETRY_ACCEPTOR,VCENTER,VCFDT,VCF_FLEET_LCM,VCF_LICENSE_SERVER,VCFMS_METRICS_STORE,VCF_OBSERVABILITY_DATA_PLATFORM,VCF_OPS_CLOUD_PROXY,VCF_SALT,VCF_SALT_RAAS,VCF_SDDC_LCM,VIDB,VSP,VSAN_FILE_SERVICES,VRA,VROPS,VCF_SERVICE_VCD_MIGRATION_BACKEND"

usage(){ grep '^#' "$0" | sed 's/^# \{0,1\}//' | sed -n '2,30p'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -t|--token-file)   TOKEN_FILE="$2"; shift 2;;
    -c|--component)    COMPONENT="$2"; shift 2;;
    --type)            TYPE="$2"; shift 2;;
    --filename-like)   FNLIKE="$2"; shift 2;;
    -o|--out-dir)      OUTDIR="$2"; shift 2;;
    --latest-only)     LATEST=1; shift;;
    --summary)         SUMMARY=1; shift;;
    --download)        DOWNLOAD=1; shift;;
    --metadata)        METADATA=1; shift;;
    --build-depot)     BUILD=1; shift;;
    --no-resume)       NORESUME=1; shift;;
    -h|--help)         usage 0;;
    *) echo "unknown arg: $1" >&2; usage 1;;
  esac
done

[ -n "$TOKEN_FILE" ] || { echo "ERROR: -t/--token-file required" >&2; usage 1; }
for b in curl jq sha256sum awk; do command -v "$b" >/dev/null || { echo "ERROR: need '$b' (e.g. apt-get install -y jq)"; exit 1; }; done

TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"
BASE="https://dl.broadcom.com/${TOKEN}/PROD"

if [ "$BUILD" = 1 ]; then METADATA=1; DOWNLOAD=1; [ -n "$COMPONENT" ] || COMPONENT="$MGMT_SET"; fi

echo "Fetching product version catalog..." >&2
CAT="$(curl -fsS --max-time 60 "$BASE/metadata/productVersionCatalog/v1/productVersionCatalog.json")"

# flatten catalog -> TSV: comp \t version \t vkey \t type \t fileName \t sizeBytes \t checksum
# vkey = SEMANTIC sort key for --latest-only: every numeric segment of productVersion
#   (e.g. 9.1.0.0.25368698) offset by 1e12 -> fixed 13-char width, padded to 6 segments,
#   dot-joined. String compare of vkeys == element-wise numeric version compare, so
#   9.1.0.0 > 9.0.2.0200 (NOT the old "last build number wins", which wrongly picked the
#   9.0.2 patch build 25456362 over 9.1 GA build 25368698).
ROWS="$(jq -r '
  def arr: if type=="array" then . elif .==null then [] else [.] end;
  (if type=="array" then .[0] else . end) as $root
  | ($root.patches | if type=="array" then .[0] else . end)   # .patches is an object keyed by component
  | to_entries[] | .key as $c | (.value|arr)[]
  | .productVersion as $v
  | ((([$v|scan("[0-9]+")|tonumber]) + [0,0,0,0,0,0])[0:6]
        | map(. + 1000000000000 | tostring) | join(".")) as $b
  | (.artifacts.bundles|arr)[] | .type as $t | (.binaries|arr)[]
  | [$c,$v,$b,$t,.fileName,(.size|tostring),.checksum] | @tsv
' <<<"$CAT")"

# --- filters (awk) ---
# component
if [ -n "$COMPONENT" ]; then
  ROWS="$(awk -F'\t' -v L=",$COMPONENT," 'index(L, ","$1",")>0' <<<"$ROWS")"
fi
# type
[ -n "$TYPE" ] && ROWS="$(awk -F'\t' -v T="$TYPE" '$4==T' <<<"$ROWS")"
# filename glob (bash-style)
if [ -n "$FNLIKE" ]; then
  ROWS="$(while IFS=$'\t' read -r c v b t fn sz ck; do case "$fn" in ($FNLIKE) printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$c" "$v" "$b" "$t" "$fn" "$sz" "$ck";; esac; done <<<"$ROWS")"
fi
# latest-only: per component keep only rows whose vkey == max(vkey) for that component.
# vkey is a fixed-width dotted string, so a plain string compare is the semantic version compare.
if [ "$LATEST" = 1 ] && [ -n "$ROWS" ]; then
  ROWS="$(awk -F'\t' 'NR==FNR{if($3>m[$1])m[$1]=$3; next} $3==m[$1]' <(printf '%s\n' "$ROWS") <(printf '%s\n' "$ROWS"))"
fi

human_gb(){ awk -v b="$1" 'BEGIN{printf "%.2f", b/1073741824}'; }

# --- summary ---
if [ "$SUMMARY" = 1 ]; then
  printf '%-34s %6s %10s\n' "Component" "Files" "TotalGB"
  awk -F'\t' '{f[$1]++; s[$1]+=$6} END{for(c in f) printf "%-34s %6d %10.2f\n", c, f[c], s[c]/1073741824}' <<<"$ROWS" | sort
  awk -F'\t' '{n++; s+=$6; comp[$1]=1} END{c=0; for(k in comp)c++; printf "\nComponents: %d   Files: %d   Total: %.1f GB\n", c, n, s/1073741824}' <<<"$ROWS"
  exit 0
fi

# --- list (no download/metadata) ---
if [ "$DOWNLOAD" = 0 ] && [ "$METADATA" = 0 ]; then
  printf '%-32s %-22s %-8s %8s  %s\n' "Component" "Version" "Type" "SizeGB" "FileName"
  while IFS=$'\t' read -r c v b t fn sz ck; do printf '%-32s %-22s %-8s %8s  %s\n' "$c" "$v" "$t" "$(human_gb "$sz")" "$fn"; done <<<"$ROWS"
  exit 0
fi

# --- metadata: catalog + manifest + vSAN HCL (token + public) ---
if [ "$METADATA" = 1 ]; then
  for m in metadata/productVersionCatalog/v1/productVersionCatalog.json \
           metadata/productVersionCatalog/v1/productVersionCatalog.sig \
           metadata/manifest/v1/vcfManifest.json; do
    echo "METADATA    $m"
    mkdir -p "$OUTDIR/PROD/$(dirname "$m")"
    curl -fsS --max-time 120 -o "$OUTDIR/PROD/$m" "$BASE/$m" && echo "  OK"
  done
  echo "METADATA    vsan/hcl/all.json  (partnerweb, public)"
  mkdir -p "$OUTDIR/PROD/metadata/vsan/hcl"
  curl -fsS --max-time 300 -o "$OUTDIR/PROD/metadata/vsan/hcl/all.json" \
       "https://partnerweb.vmware.com/service/vsan/all.json"
  jq -c '{timestamp, jsonUpdatedTime}' "$OUTDIR/PROD/metadata/vsan/hcl/all.json" \
       > "$OUTDIR/PROD/metadata/vsan/hcl/lastupdatedtime.json"
  echo "  OK  (+ generated lastupdatedtime.json)"
fi

# --- download binaries: resume + sha256 verify, idempotent ---
if [ "$DOWNLOAD" = 1 ]; then
  while IFS=$'\t' read -r c v b t fn sz ck; do
    [ -n "$fn" ] || continue
    dest="$OUTDIR/PROD/COMP/$c/$fn"; mkdir -p "$(dirname "$dest")"
    if [ -f "$dest" ] && [ "$(sha256sum "$dest" | awk '{print $1}')" = "$ck" ]; then
      echo "ALREADY_OK  $fn"; continue
    fi
    echo "DOWNLOAD    $fn  ($(human_gb "$sz") GB)"
    url="$BASE/COMP/$c/$fn"
    if [ "$NORESUME" = 1 ]; then curl -fsS -o "$dest" "$url"
    else curl -fsS -C - -o "$dest" "$url" || { echo "  resume failed; full refetch"; rm -f "$dest"; curl -fsS -o "$dest" "$url"; }; fi
    if [ "$(sha256sum "$dest" | awk '{print $1}')" = "$ck" ]; then echo "  OK  sha256 matches catalog"
    else echo "  !! CHECKSUM MISMATCH - refetch"; rm -f "$dest"; curl -fsS -o "$dest" "$url"
      [ "$(sha256sum "$dest" | awk '{print $1}')" = "$ck" ] && echo "  OK  (after refetch)" || echo "  !! STILL MISMATCH - left for inspection"; fi
  done <<<"$ROWS"
fi

echo ""
echo "Done. Depot root: $OUTDIR"
[ "$METADATA" = 1 ] && echo "Note: Compatibility/ (vvs.broadcom.com) NOT fetched - needs activation code; day-2 only, does not gate bring-up."
