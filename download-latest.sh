#!/usr/bin/env bash
# download-latest.sh — 用 VCF Download Tool 只下「每元件最新版」進 depot（自動挑 ID，不用手撈）。
#
# 工具沒有 --latest 旗標;--vcf-version 只能列整條線所有版本。本腳本 list -> 每元件挑最新 -> --id 下。
#
# Usage:
#   bash download-latest.sh <tool> <code-file> <depot-store> [vcf-version] [--dry-run]
# 例:
#   bash download-latest.sh /opt/vdt/bin/vcf-download-tool actcode.txt /opt/vcf-depot/vcf9 9.1.0.0
#   bash download-latest.sh .../vcf-download-tool.bat E:/vdt/actcode.txt E:/vcf9-depot 9.1.0.0 --dry-run
# NOTE: keep LF (sed -i 's/\r$//' if edited on Windows).
set -euo pipefail
TOOL="${1:?need tool path (vcf-download-tool[.bat])}"
CODE="${2:?need activation-code file}"
DEPOT="${3:?need depot-store dir}"
VER="${4:-9.1.0.0}"
DRY="${5:-}"

echo ">> listing $VER install binaries ..."
LIST="$("$TOOL" binaries list --vcf-version="$VER" --sku=VCF --automated-install --type=INSTALL \
        --depot-download-activation-code-file="$CODE" 2>&1)" || { echo "$LIST" | tail -5; exit 1; }

# 每列: ID | Component | Full Name | Version | Date | Size | INSTALL  -> 每元件挑最新版的 ID
IDS="$(printf '%s\n' "$LIST" | awk -F'|' '
  /\| INSTALL[[:space:]]*$/ {
    id=$1; comp=$2; ver=$4;
    gsub(/[[:space:]]/,"",id); gsub(/^[[:space:]]+|[[:space:]]+$/,"",comp); gsub(/[[:space:]]/,"",ver);
    key=""; n=split(ver,a,".");
    for(i=1;i<=6;i++){ v=(i<=n)?a[i]+0:0; key=key sprintf("%013d.",v) }
    if(key > best[comp]){ best[comp]=key; bid[comp]=id; bver[comp]=ver }
  }
  END{ first=1; for(c in bid){ printf "%s%s",(first?"":","),bid[c]; first=0 }
       for(c in bver){ printf "  # %s %s\n",c,bver[c] > "/dev/stderr" } }'
)"
echo ">> latest per component:"
echo ">> --id=$IDS"

if [ "$DRY" = "--dry-run" ]; then echo "(dry-run, not downloading)"; exit 0; fi

echo ">> downloading into $DEPOT ..."
"$TOOL" binaries download --depot-store="$DEPOT" \
  --depot-download-activation-code-file="$CODE" --id="$IDS" --ceip=DISABLE
