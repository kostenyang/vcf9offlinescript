#!/usr/bin/env bash
# =============================================================================
# installer-local-depot.sh — 把 VCF Installer 自己變成 offline depot,自己下載自己
#
# 情境:現場只有 VCF Installer,沒有另外的 depot server。
#       把 metadata zip / depot tar.gz 丟到 installer 本機 → 本機起 HTTP server
#       → installer 的 depot URL 指回 http://127.0.0.1:<port> → sync → 下載 bundle。
#
# 實測(VCF Installer 9.1.1,vcf-m04-inst01):
#   - unauthenticated HTTP offline depot 是支援的 → 不用憑證、不用匯 CA
#   - HTTP 帶帳密會被拒:VMWARE_DEPOT_AUTH_HTTP_OFFLINE_DEPOT_IS_UNSUPPORTED
#   - 用 vcf 帳號就能跑(/nfs/vmware/vcf/nfs-mount 是 root:vcf 775),不用 root
#   - 直接把檔案塞進 /nfs/.../metadata 沒用:installer 認的是 DB,只有 sync 會寫 DB
#
# 用法(在 installer 上,vcf 登入即可):
#   bash installer-local-depot.sh --zip  vcf-9.1.1.0-offline-depot-metadata-full.zip
#   bash installer-local-depot.sh --tar  vcf911-depot.tar.gz
#   bash installer-local-depot.sh --dir  /nfs/vmware/vcf/nfs-mount/local-depot   # 已解好,只起服務+sync
#   bash installer-local-depot.sh --dir  /nfs/vmware/vcf/nfs-mount/vcf911         # download tool -d= 下載好的 depot
#   bash installer-local-depot.sh --stop                                         # 停本機 server
#   bash installer-local-depot.sh --stop --restore-url https://10.0.0.61 --restore-user vcfdepot
#
# admin@local 密碼:環境變數 INSTALLER_PASSWORD,沒設就互動輸入。
# 還原用的 depot 密碼:環境變數 RESTORE_PASSWORD,沒設就互動輸入。
# =============================================================================
set -euo pipefail

NFS=/nfs/vmware/vcf/nfs-mount
DEPOT_DIR="${NFS}/local-depot"
PORT=8080
API=https://127.0.0.1
API_USER=admin@local
SRC_ZIP=""
SRC_TAR=""
DO_STOP=false
NO_SYNC=false
FORCE=false
RESTORE_URL=""
RESTORE_USER=""
LOG=/tmp/vcf-local-depot.log

info() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

usage() { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --zip)          SRC_ZIP="$2"; shift 2 ;;
    --tar)          SRC_TAR="$2"; shift 2 ;;
    --dir)          DEPOT_DIR="$2"; shift 2 ;;
    --port)         PORT="$2"; shift 2 ;;
    --user)         API_USER="$2"; shift 2 ;;
    --no-sync)      NO_SYNC=true; shift ;;
    --force)        FORCE=true; shift ;;
    --stop)         DO_STOP=true; shift ;;
    --restore-url)  RESTORE_URL="$2"; shift 2 ;;
    --restore-user) RESTORE_USER="$2"; shift 2 ;;
    -h|--help)      usage ;;
    *) die "不認得的參數: $1(--help 看用法)" ;;
  esac
done

# ---------- 前置檢查 ----------
[[ -d "$NFS" ]] || die "找不到 $NFS — 這台不是 VCF Installer?"
command -v python3 >/dev/null || die "缺 python3"
command -v curl    >/dev/null || die "缺 curl"

# ---------- API ----------
get_token() {
  local pw="${INSTALLER_PASSWORD:-}"
  if [[ -z "$pw" ]]; then read -rsp "${API_USER} 密碼: " pw; echo; fi
  local body
  body=$(python3 -c 'import json,sys;print(json.dumps({"username":sys.argv[1],"password":sys.argv[2]}))' "$API_USER" "$pw")
  TOKEN=$(curl -sk -X POST "$API/v1/tokens" -H 'Content-Type: application/json' -d "$body" --max-time 60 \
          | python3 -c 'import json,sys;print(json.load(sys.stdin).get("accessToken",""))' 2>/dev/null || true)
  [[ -n "$TOKEN" ]] || die "拿不到 token(密碼錯?注意 admin@local 連錯會鎖,鎖了要重啟 commonsvcs)"
}
api() {  # api METHOD PATH [JSON]
  local m="$1" p="$2" d="${3:-}"
  if [[ -n "$d" ]]; then
    curl -sk -X "$m" "$API$p" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d "$d" --max-time 120
  else
    curl -sk -X "$m" "$API$p" -H "Authorization: Bearer $TOKEN" --max-time 120
  fi
}
jget() { python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get(sys.argv[1],""))' "$1" 2>/dev/null || true; }

wait_sync() {
  local s i
  api PATCH /v1/system/settings/depot/depot-sync-info >/dev/null
  for i in $(seq 1 90); do
    s=$(api GET /v1/system/settings/depot/depot-sync-info | jget syncStatus)
    info "  sync: $s"
    case "$s" in
      SYNCED) return 0 ;;
      *FAIL*) api GET /v1/system/settings/depot/depot-sync-info; echo; return 1 ;;
    esac
    sleep 10
  done
  warn "sync 15 分鐘還沒完成"; return 1
}

stop_server() {
  # 🔴 不要 pkill -f "http.server $PORT":會連自己這個 ssh 指令列一起殺掉
  local pids
  pids=$(pgrep -f "htt[p].server ${PORT} " || true)
  if [[ -n "$pids" ]]; then
    kill $pids && info "已停止本機 depot server(pid $pids)"
  else
    info "沒有在跑的本機 depot server(port $PORT)"
  fi
}

# ---------- --stop(可選還原 depot URL) ----------
if $DO_STOP; then
  if [[ -n "$RESTORE_URL" ]]; then
    get_token
    rpw="${RESTORE_PASSWORD:-}"
    if [[ -n "$RESTORE_USER" && -z "$rpw" ]]; then read -rsp "${RESTORE_USER}@depot 密碼: " rpw; echo; fi
    body=$(python3 -c '
import json,sys
url,u,p=sys.argv[1:4]
d={"depotConfiguration":{"isOfflineDepot":True,"url":url}}
if u: d["offlineAccount"]={"username":u,"password":p}
print(json.dumps(d))' "$RESTORE_URL" "$RESTORE_USER" "$rpw")
    info "depot URL 改回 $RESTORE_URL"
    api PUT /v1/system/settings/depot "$body"; echo
    wait_sync || warn "還原後 sync 沒成功,請檢查"
  fi
  stop_server
  exit 0
fi

# ---------- 1. 鋪 depot 內容 ----------
mkdir -p "$DEPOT_DIR"
avail=$(df -Pk "$DEPOT_DIR" | awk 'NR==2{print $4}')
if [[ -n "$SRC_ZIP" ]]; then
  [[ -f "$SRC_ZIP" ]] || die "找不到 $SRC_ZIP"
  # 目錄裡已經有 catalog(例如 download tool 下的)→ zip 比較舊就不要蓋,避免 metadata 倒退
  _cur="$DEPOT_DIR/PROD/metadata/productVersionCatalog/v1/productVersionCatalog.json"
  if [[ -f "$_cur" ]] && ! $FORCE; then
    read -r _cs _zs < <(python3 -c '
import json,sys,zipfile
cur=json.load(open(sys.argv[1]))["sequenceNumber"]
z=zipfile.ZipFile(sys.argv[2])
n=[x for x in z.namelist() if x.endswith("productVersionCatalog/v1/productVersionCatalog.json")]
print(cur, json.loads(z.read(n[0]))["sequenceNumber"] if n else -1)' "$_cur" "$SRC_ZIP")
    if (( _zs < _cs )); then
      die "zip 的 catalog(seq $_zs)比 $DEPOT_DIR 現有的(seq $_cs)舊,不蓋。不需要 zip,直接 --dir $DEPOT_DIR;硬要蓋加 --force"
    fi
  fi
  info "解 metadata zip → $DEPOT_DIR"
  python3 -c 'import zipfile,sys;zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$SRC_ZIP" "$DEPOT_DIR"
elif [[ -n "$SRC_TAR" ]]; then
  [[ -f "$SRC_TAR" ]] || die "找不到 $SRC_TAR"
  need=$(( $(stat -c %s "$SRC_TAR") / 1024 * 11 / 10 ))
  (( avail > need )) || die "空間不夠:$DEPOT_DIR 剩 $((avail/1024/1024))G,tar 解開約需 $((need/1024/1024))G 以上"
  info "解 depot tar → $DEPOT_DIR(大檔要一段時間)"
  tar -xzf "$SRC_TAR" -C "$DEPOT_DIR"
fi
CAT="$DEPOT_DIR/PROD/metadata/productVersionCatalog/v1/productVersionCatalog.json"
[[ -f "$CAT" ]] || die "$DEPOT_DIR 底下沒有 PROD/metadata/productVersionCatalog — 內容結構不對(頂層要是 PROD/)"
[[ -f "$DEPOT_DIR/PROD/COMP/SDDC_MANAGER_VCF/Compatibility/VmwareCompatibilityData.json" ]] \
  || warn "缺 Compatibility 檔,sync 可能卡 'Vmware compatibility data download failed'"
# download tool 常用 root 跑 → 檔案是 root 的,vcf 改不了權限;改不了沒關係,只要讀得到
chmod -R a+rX "$DEPOT_DIR" 2>/dev/null || true
unread=$( { find "$DEPOT_DIR/PROD" ! -readable -print; find "$DEPOT_DIR/PROD" -type d ! -executable -print; } 2>/dev/null | head -5)
if [[ -n "$unread" ]]; then
  echo "$unread" | sed 's/^/    /' >&2
  die "上面這些 $(id -un) 讀不到 → 用 root 跑一次:chmod -R a+rX $DEPOT_DIR"
fi
seq=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["sequenceNumber"])' "$CAT")
info "depot 內容 OK:$(find "$DEPOT_DIR/PROD" -type f | wc -l) 檔,catalog sequenceNumber=$seq"

# ---------- 2. 起本機 HTTP server(只綁 127.0.0.1) ----------
stop_server
setsid nohup python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$DEPOT_DIR" >"$LOG" 2>&1 </dev/null &
sleep 2
code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/PROD/metadata/productVersionCatalog/v1/productVersionCatalog.json" || true)
[[ "$code" == 200 ]] || die "本機 server 自測失敗(HTTP $code),看 $LOG"
info "本機 depot server 起來了:http://127.0.0.1:${PORT}  (access log: $LOG)"
warn "這是 nohup 背景程序,installer 重開機會消失 → 重開後再跑一次 --dir $DEPOT_DIR"

# ---------- 3. installer 指向自己 + sync ----------
if $NO_SYNC; then info "--no-sync:不改 installer 設定,結束"; exit 0; fi
get_token
prev=$(api GET /v1/system/settings/depot)
PREV_FILE="${HOME:-/tmp}/.vcf-local-depot-prev.json"   # 不寫進 depot 目錄:那裡可能是 root 的
echo "$prev" > "$PREV_FILE" 2>/dev/null || { PREV_FILE=/tmp/.vcf-local-depot-prev.json; echo "$prev" > "$PREV_FILE"; }
prev_url=$(echo "$prev" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("depotConfiguration",{}).get("url",""))' 2>/dev/null || true)
info "原本 depot 設定:${prev_url:-(無)}(已存 $PREV_FILE)"

# 🔴 HTTP 不能帶 offlineAccount,帶了會 400 VMWARE_DEPOT_AUTH_HTTP_OFFLINE_DEPOT_IS_UNSUPPORTED
info "installer depot URL → http://127.0.0.1:${PORT}"
r=$(api PUT /v1/system/settings/depot "{\"depotConfiguration\":{\"isOfflineDepot\":true,\"url\":\"http://127.0.0.1:${PORT}\"}}")
echo "$r" | grep -q DEPOT_CONNECTION_SUCCESSFUL || die "installer 接不上本機 depot:$r"
info "連線:DEPOT_CONNECTION_SUCCESSFUL"

wait_sync || die "sync 失敗"

echo
echo "================================================================"
echo " 完成:installer 已經以自己為 depot 同步成功"
echo "================================================================"
echo " 下一步:UI 勾元件下載,或 API:"
echo "   curl -sk -X PATCH $API/v1/bundles/<bundleId> -H \"Authorization: Bearer <token>\" \\"
echo "     -H 'Content-Type: application/json' -d '{\"bundleDownloadSpec\":{\"downloadNow\":true}}'"
echo
echo " 下載失敗時看它要哪個檔(404 = depot 裡缺那個 binary):"
echo "   grep ' 404 ' $LOG"
echo
echo " 注意:catalog sequenceNumber 比 installer 現有的舊時,installer 會保留新的那份;"
echo "       全新 installer 就直接用這份。"
echo
echo " 收尾 / 改回原 depot:"
echo "   bash $0 --stop --restore-url https://<原depot IP> --restore-user <帳號>"
echo "================================================================"
