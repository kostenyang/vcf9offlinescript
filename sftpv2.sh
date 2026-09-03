#!/bin/bash
# ===========================================================================
# sftpv2.sh — VMware (vCenter / NSX / SDDC Manager) 備份用 SFTP Server
#             **RHEL / Rocky / Alma / Ubuntu / Debian 通用版**
#
# v1 (sftpv1.sh) 寫死 Ubuntu,在 RHEL 上會壞在三個地方:
#   1. apt-get               -> RHEL 沒有
#   2. systemctl restart ssh -> RHEL 服務名是 sshd
#   3. ufw                   -> RHEL 用 firewalld
#   另外 RHEL 預設 SELinux Enforcing,SFTP chroot 會被擋(v1 完全沒處理)。
#
# v2 變更:
#   - 自動判斷套件管理員 / 服務名 / 防火牆
#   - SELinux 自動設定(setsebool + fcontext + restorecon)
#   - 設定寫進 /etc/ssh/sshd_config.d/ drop-in(RHEL9/Ubuntu22+ 有 Include)
#     避免主檔被 drop-in 覆蓋而失效
#   - upload 目錄權限 777 -> 750(v1 的 777 是 world-writable,沒必要)
#   - 新增 --dry-run / --users / --base-dir / --no-firewall
#   - 失敗即停(set -euo pipefail)+ 完整驗證
#
# 用法:
#   sudo bash sftpv2.sh                          # 預設三個帳號,互動設密碼
#   sudo bash sftpv2.sh --dry-run                # 只顯示會做什麼
#   sudo bash sftpv2.sh --users vcbackup,nsxbackup
#   sudo bash sftpv2.sh --base-dir /srv/sftp
# ===========================================================================
set -euo pipefail

BASE_DIR="/data/sftp"
GROUP_NAME="sftp_users"
USERS="vcbackup,nsxbackup,sddcbackup"
DRY=0
DO_FIREWALL=1

green(){ printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[1;33m%s\033[0m\n' "$*"; }
red(){ printf '\033[0;31m%s\033[0m\n' "$*" >&2; }
info(){ green "[INFO] $*"; }
warn(){ yellow "[WARN] $*"; }
die(){ red "[ERROR] $*"; exit 1; }
run(){ if [ "$DRY" = 1 ]; then echo "  [DRY] $*"; else eval "$@"; fi; }

while [ $# -gt 0 ]; do
  case "$1" in
    --base-dir)    BASE_DIR="$2"; shift 2;;
    --group)       GROUP_NAME="$2"; shift 2;;
    --users)       USERS="$2"; shift 2;;
    --no-firewall) DO_FIREWALL=0; shift;;
    --dry-run)     DRY=1; shift;;
    -h|--help)     awk 'NR==1{next} /^# ={10,}$/{c++; if(c==2) exit} {sub(/^# ?/,""); print}' "$0"; exit 0;;
    *) die "未知參數: $1";;
  esac
done

[ "$(id -u)" -eq 0 ] || die "請用 root 執行 (sudo bash $0)"

# --- 平台偵測 ------------------------------------------------------------
if command -v dnf >/dev/null 2>&1;      then PKG=dnf
elif command -v yum >/dev/null 2>&1;    then PKG=yum
elif command -v apt-get >/dev/null 2>&1;then PKG=apt
else die "找不到 dnf/yum/apt-get,不支援的發行版"; fi

# RHEL 服務名是 sshd,Debian/Ubuntu 是 ssh
# 🔴 不要寫成 `systemctl ... | grep -q ...`:grep -q 匹配後立刻結束,
#    systemctl 收到 SIGPIPE 以 141 結束,在 set -o pipefail 下整條 pipeline
#    被判定為失敗 → 永遠走 else 分支。實測在 RHEL 9.8 上就是這樣誤判成 ssh。
#    先把輸出收進變數再比對即可避開。
_units="$(systemctl list-unit-files --no-pager --type=service 2>/dev/null || true)"
case "$_units" in
  *sshd.service*) SSHD_SVC=sshd ;;
  *)              SSHD_SVC=ssh  ;;
esac

OS_NAME="$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}")"
info "OS       : ${OS_NAME}"
info "套件管理 : ${PKG}"
info "SSH 服務 : ${SSHD_SVC}"
info "SFTP 根  : ${BASE_DIR}"
info "群組     : ${GROUP_NAME}"
info "帳號     : ${USERS}"
[ "$DRY" = 1 ] && yellow "*** DRY-RUN:不會有任何實際變更 ***"
echo

# --- 1. 安裝 OpenSSH -----------------------------------------------------
info "[1/7] 安裝 OpenSSH server"
case "$PKG" in
  dnf|yum) run "$PKG install -y openssh-server >/dev/null";;
  apt)     run "apt-get update -qq >/dev/null"
           run "DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server -qq >/dev/null";;
esac

# SELinux 工具(semanage)在 RHEL 要另外裝
SELINUX_ON=0
if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce)" != "Disabled" ]; then
  SELINUX_ON=1
  info "      偵測到 SELinux ($(getenforce)) — 會一併設定"
  if ! command -v semanage >/dev/null 2>&1; then
    case "$PKG" in
      dnf|yum) run "$PKG install -y policycoreutils-python-utils >/dev/null || true";;
    esac
  fi
fi

# --- 2. 群組 --------------------------------------------------------------
info "[2/7] 建立群組 ${GROUP_NAME}"
if getent group "$GROUP_NAME" >/dev/null; then
  info "      已存在,略過"
else
  run "groupadd '$GROUP_NAME'"
fi

# --- 3. 目錄 --------------------------------------------------------------
info "[3/7] 建立 SFTP 根目錄"
run "mkdir -p '$BASE_DIR'"
# 🔴 chroot 的父目錄鏈必須 root 擁有且不可被群組/其他人寫,否則 sshd 拒絕連線
run "chown root:root '$BASE_DIR'"
run "chmod 755 '$BASE_DIR'"
parent="$(dirname "$BASE_DIR")"
if [ "$parent" != "/" ]; then
  run "chown root:root '$parent' 2>/dev/null || true"
  run "chmod 755 '$parent' 2>/dev/null || true"
fi

# --- 4. 使用者 ------------------------------------------------------------
info "[4/7] 建立備份帳號"
IFS=',' read -ra ULIST <<< "$USERS"
for U in "${ULIST[@]}"; do
  U="$(echo "$U" | tr -d ' ')"
  [ -n "$U" ] || continue
  HOME_DIR="${BASE_DIR}/${U}"
  echo "  ---- ${U}"
  if id "$U" &>/dev/null; then
    run "usermod -g '$GROUP_NAME' -s /sbin/nologin -d '$HOME_DIR' '$U'"
  else
    run "useradd -M -d '$HOME_DIR' -g '$GROUP_NAME' -s /sbin/nologin '$U'"
  fi
  # chroot 目標:必須 root:root 755
  run "mkdir -p '$HOME_DIR'"
  run "chown root:root '$HOME_DIR'"
  run "chmod 755 '$HOME_DIR'"
  # 實際可寫的子目錄
  run "mkdir -p '$HOME_DIR/upload'"
  run "chown '$U:$GROUP_NAME' '$HOME_DIR/upload'"
  run "chmod 750 '$HOME_DIR/upload'"
  if [ "$DRY" = 0 ]; then
    echo "  請設定 ${U} 的密碼:"
    passwd "$U"
  else
    echo "  [DRY] passwd $U"
  fi
done

# --- 5. SSHD 設定(drop-in) ------------------------------------------------
info "[5/7] 設定 SSHD"
SSHD_MAIN=/etc/ssh/sshd_config
DROPIN_DIR=/etc/ssh/sshd_config.d
DROPIN="${DROPIN_DIR}/60-vmware-sftp.conf"

run "cp -n '$SSHD_MAIN' '${SSHD_MAIN}.bak' 2>/dev/null || true"

# 🔴 RHEL9 / Ubuntu22+ 的 sshd_config 有 Include,drop-in 會覆蓋主檔。
#    寫進 drop-in 才不會被蓋掉;沒有 Include 的舊系統則直接寫主檔。
if grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d/' "$SSHD_MAIN" 2>/dev/null; then
  info "      偵測到 Include → 寫入 ${DROPIN}"
  run "mkdir -p '$DROPIN_DIR'"
  TARGET="$DROPIN"
else
  warn "      無 Include → 直接寫主檔 ${SSHD_MAIN}"
  TARGET="$SSHD_MAIN"
  # 清掉本腳本先前寫過的區塊,避免重複
  run "sed -i '/^# --- VMware Backup SFTP/,/^# --- end VMware Backup SFTP/d' '$SSHD_MAIN'"
fi

CONF_BLOCK="# --- VMware Backup SFTP (managed by sftpv2.sh) ---
Subsystem sftp internal-sftp
Match Group ${GROUP_NAME}
    ChrootDirectory ${BASE_DIR}/%u
    ForceCommand internal-sftp
    PasswordAuthentication yes
    X11Forwarding no
    AllowTcpForwarding no
# --- end VMware Backup SFTP ---"

if [ "$DRY" = 1 ]; then
  echo "  [DRY] 會寫入 ${TARGET}:"
  echo "$CONF_BLOCK" | sed 's/^/       /'
else
  if [ "$TARGET" = "$DROPIN" ]; then
    printf '%s\n' "$CONF_BLOCK" > "$TARGET"
    # 主檔若已有 Subsystem sftp,drop-in 再宣告會衝突 → 註解掉主檔那行
    sed -i 's|^\(Subsystem\s\+sftp\s\+.*\)|#\1  # moved to sshd_config.d/60-vmware-sftp.conf|' "$SSHD_MAIN"
  else
    printf '\n%s\n' "$CONF_BLOCK" >> "$TARGET"
    sed -i 's|^Subsystem.*sftp.*|Subsystem sftp internal-sftp|' "$SSHD_MAIN"
  fi
  chmod 600 "$TARGET"
fi

# --- 6. SELinux + 防火牆 --------------------------------------------------
info "[6/7] SELinux 與防火牆"
if [ "$SELINUX_ON" = 1 ]; then
  run "setsebool -P ssh_chroot_rw_homedirs on 2>/dev/null || true"
  if command -v semanage >/dev/null 2>&1; then
    run "semanage fcontext -a -t ssh_home_t '${BASE_DIR}(/.*)?' 2>/dev/null || true"
  fi
  run "restorecon -Rv '$BASE_DIR' >/dev/null 2>&1 || true"
  info "      SELinux context 已套用"
fi

if [ "$DO_FIREWALL" = 1 ]; then
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
    run "firewall-cmd --permanent --add-service=ssh >/dev/null"
    run "firewall-cmd --reload >/dev/null"
    info "      firewalld: ssh allowed"
  elif command -v ufw >/dev/null 2>&1; then
    run "ufw allow ssh >/dev/null 2>&1 || true"
    info "      ufw: ssh allowed"
  else
    warn "      找不到 firewalld/ufw,略過防火牆設定"
  fi
fi

# --- 7. 驗證並重啟 --------------------------------------------------------
info "[7/7] 驗證設定並重啟服務"
if [ "$DRY" = 0 ]; then
  if ! sshd -t; then
    red "sshd 設定語法錯誤 —— 未重啟服務,請修正後再跑一次"
    red "還原:cp ${SSHD_MAIN}.bak ${SSHD_MAIN}"
    exit 1
  fi
  info "      sshd -t 通過"
  systemctl enable --now "$SSHD_SVC" >/dev/null 2>&1 || true
  systemctl restart "$SSHD_SVC"
  systemctl is-active --quiet "$SSHD_SVC" && info "      ${SSHD_SVC} 運行中" || die "${SSHD_SVC} 啟動失敗"
else
  echo "  [DRY] sshd -t && systemctl restart $SSHD_SVC"
fi

IP_ADDR="$(hostname -I 2>/dev/null | awk '{print $1}')"
echo
green "=========================================="
green "  完成 — VMware 備份用 SFTP Server"
green "=========================================="
echo "  SFTP Server : ${IP_ADDR:-<IP>}  port 22"
echo "  帳號        : ${USERS}"
echo "  上傳路徑    : /upload   (chroot 後的相對路徑)"
echo "  實體路徑    : ${BASE_DIR}/<user>/upload"
echo
echo "  測試:"
echo "    sftp <user>@${IP_ADDR:-<IP>}"
echo "    sftp> cd upload && put <file>"
echo
echo "  vCenter/NSX/SDDC 備份設定填:"
echo "    Protocol=SFTP  Port=22  Path=/upload"
echo
yellow "  註:帳號為 nologin,只能 SFTP,無法 SSH 進 shell。"
