#!/usr/bin/env bash
# make-metadata-zip.sh — 從 depot tar(.gz) 或已解開的 depot 目錄，抽出 metadata 打成
# 與官方 vcf-9.1.0.XXXX-offline-depot-metadata.zip 完全相同結構(13 檔)的 zip。
#
# 用途：手上只有官方 0100 metadata zip、但 binary 是 0400 時，從 download-tool 下的
#       depot(或完整 depot tar)反做一個「版本對得上」的 metadata zip，餵給
#       sort-flat-depot.sh 第三參數、或直接解進 depot 的 PROD/。
#
# Usage:
#   bash make-metadata-zip.sh <depot.tar.gz | depot根目錄(含 PROD/)> <輸出.zip>
# 例:
#   bash make-metadata-zip.sh vcf9-depot-0400.tar.gz vcf-9.1.0.0400-offline-depot-metadata.zip
#   bash make-metadata-zip.sh ./vcf9-depot            vcf-9.1.0.0400-offline-depot-metadata.zip
#
# - tar 模式為單趟串流掃描(不落地解壓)；66GB tar 約需數分鐘~十餘分鐘(解壓讀取)。
# - 只需 python3。輸出頂層為 PROD/。缺任何預期檔會 WARN(sync 必要檔缺少會 exit 1)。
# - NOTE: keep LF line endings (sed -i 's/\r$//' 本檔 if edited on Windows).
set -euo pipefail
SRC="${1:?need <depot.tar.gz | depot dir>}"
OUT="${2:?need <output zip>}"

PYBIN="$(command -v python3 || command -v python || command -v py)"
[ -n "$PYBIN" ] || { echo "ERROR: need python3/python/py"; exit 2; }

"$PYBIN" - "$SRC" "$OUT" <<'PY'
import sys, os, tarfile, zipfile, fnmatch

src, out = sys.argv[1], sys.argv[2]

# 官方 metadata zip 的 13 檔結構（VCENTER 的 vmw/<uuid>/ 以萬用字元對應）
PATTERNS = [
 'PROD/metadata/Compatibility/v1/VmwareCompatibilityData.json',
 'PROD/metadata/Compatibility/v2/VmwareCompatibilityData.json',
 'PROD/metadata/manifest/v1/vcfManifest.json',
 'PROD/metadata/productVersionCatalog/v1/productVersionCatalog.json',
 'PROD/metadata/productVersionCatalog/v1/productVersionCatalog.sig',
 'PROD/metadata/vsan/hcl/all.json',
 'PROD/metadata/vsan/hcl/lastupdatedtime.json',
 'PROD/vsan/hcl/all.json',
 'PROD/vsan/hcl/lastupdatedtime.json',
 'PROD/COMP/SDDC_MANAGER_VCF/Compatibility/VmwareCompatibilityData.json',
 'PROD/COMP/VCENTER/vmw/*/upgrade_info.sig',
 'PROD/COMP/VCENTER/vmw/*/upgrade_info.xml',
 'PROD/COMP/VCENTER/vmw/*/upgrade_info.xml.sha256',
]
# installer sync 一定要有的（缺了 sync 會失敗 -> exit 1）
CRITICAL = [
 'PROD/metadata/productVersionCatalog/v1/productVersionCatalog.json',
 'PROD/metadata/Compatibility/v1/VmwareCompatibilityData.json',
 'PROD/COMP/SDDC_MANAGER_VCF/Compatibility/VmwareCompatibilityData.json',
]

def norm(n): return n.lstrip('./').replace(os.sep, '/')
def match(n): return any(fnmatch.fnmatch(n, p) for p in PATTERNS)

found = {}   # relpath -> bytes
if os.path.isdir(src):
    for root, _, files in os.walk(src):
        for f in files:
            full = os.path.join(root, f)
            rel = norm(os.path.relpath(full, src))
            if match(rel):
                with open(full, 'rb') as fh:
                    found[rel] = fh.read()
else:
    # 單趟串流掃 tar(.gz)：匹配到就當場讀出，不落地
    with tarfile.open(src, 'r|*') as tf:
        for m in tf:
            if m.isfile():
                rel = norm(m.name)
                if match(rel):
                    found[rel] = tf.extractfile(m).read()

with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
    for rel in sorted(found):
        z.writestr(rel, found[rel])

print(f"packed {len(found)} files -> {out} ({os.path.getsize(out)} bytes)")
for rel in sorted(found):
    print("   ", rel)

missing = [p for p in PATTERNS if not any(fnmatch.fnmatch(k, p) for k in found)]
rc = 0
for p in missing:
    crit = p in CRITICAL
    print(("MISSING(critical)" if crit else "WARN missing") + ":", p)
    if crit: rc = 1
sys.exit(rc)
PY
