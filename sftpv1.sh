#!/bin/bash

# ==========================================
# VMware (VC, NSX, SDDC) SFTP Server Setup
# ==========================================

# 確保以 root 執行
if [ "$EUID" -ne 0 ]; then
  echo "錯誤: 請使用 sudo 執行此腳本 (sudo ./setup_vmware_backup.sh)"
  exit 1
fi

# --- 設定變數 (可在此修改預設值) ---
BASE_DIR="/data/sftp"          # 實體硬碟存放路徑
GROUP_NAME="sftp_users"        # SFTP 專用群組
VC_USER="vcbackup"             # vCenter 帳號
NSX_USER="nsxbackup"           # NSX 帳號
SDDC_USER="sddcbackup"         # SDDC 帳號

# --------------------------------

echo "=========================================="
echo "   開始建置 VMware SFTP 備份伺服器...     "
echo "=========================================="

# 1. 安裝/更新 OpenSSH
echo "[1/6] 檢查並安裝 OpenSSH..."
apt-get update -qq
apt-get install -y openssh-server -qq

# 2. 建立 SFTP 群組
echo "[2/6] 設定群組 $GROUP_NAME..."
if ! getent group "$GROUP_NAME" > /dev/null; then
  groupadd "$GROUP_NAME"
fi

# 定義建立使用者的函式 (使用 Chroot 方式)
setup_user() {
    local USERNAME=$1
    local USER_HOME="$BASE_DIR/$USERNAME"

    # 確保基礎目錄結構存在
    mkdir -p "$BASE_DIR"
    chmod 755 "$BASE_DIR"
    if [[ "$BASE_DIR" == "/data/sftp" ]]; then
        chmod 755 /data 2>/dev/null || true
    fi

    echo "------------------------------------------"
    echo ">> 正在設定使用者: $USERNAME"

    # 建立或更新使用者 (使用 /sbin/nologin 禁止 SSH 登入)
    if id "$USERNAME" &>/dev/null; then
        usermod -g "$GROUP_NAME" -s /sbin/nologin -d "$USER_HOME" "$USERNAME"
    else
        useradd -m -d "$USER_HOME" -g "$GROUP_NAME" -s /sbin/nologin "$USERNAME"
    fi

    # 設定密碼 (SFTP only)
    echo "請設定 $USERNAME 的登入密碼:"
    passwd "$USERNAME"

    # Chroot 方式: 主目錄必須由 root 擁有且無寫入權限
    mkdir -p "$USER_HOME"
    chown root:root "$USER_HOME"
    chmod 755 "$USER_HOME"
    
    # 建立 upload 子目錄供使用者寫入
    mkdir -p "$USER_HOME/upload"
    chown "$USERNAME:$GROUP_NAME" "$USER_HOME/upload"
    chmod 777 "$USER_HOME/upload"
}

# 3. 執行三個帳號的建立
echo "[3/6] 開始建立備份帳號..."
setup_user "$VC_USER"
setup_user "$NSX_USER"
setup_user "$SDDC_USER"

# 4. 修改 SSHD 設定
echo "[4/6] 設定 SSHD Config (Chroot)..."
SSHD_CONFIG="/etc/ssh/sshd_config"

# 備份原始檔
if [ ! -f "${SSHD_CONFIG}.bak" ]; then
    cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak"
fi

# 啟用 internal-sftp (如果尚未啟用)
sed -i 's|^Subsystem.*sftp.*|Subsystem sftp internal-sftp|g' "$SSHD_CONFIG"

# 徹底移除舊的 Match Group 設定 (所有可能的舊格式)
sed -i '/^# --- VMware Backup SFTP Settings/,/^# -----------------------------------$/d' "$SSHD_CONFIG"
sed -i '/^Match Group sftp_users/,/^# ---/d' "$SSHD_CONFIG"

# 只添加一次新配置 (檢查是否已存在)
if ! grep -q "ChrootDirectory.*sftp" "$SSHD_CONFIG"; then
    # 確保文件末尾有新行
    if [ -n "$(tail -c 1 "$SSHD_CONFIG")" ]; then
        echo "" >> "$SSHD_CONFIG"
    fi
    
    cat <<EOT >> "$SSHD_CONFIG"
# --- VMware Backup SFTP Settings (Chroot) ---
Match Group $GROUP_NAME
    ChrootDirectory $BASE_DIR/%u
    X11Forwarding no
    AllowTcpForwarding no
    PasswordAuthentication yes
    ForceCommand internal-sftp
# -----------------------------------
EOT
    
    echo "✓ SSHD 配置已添加"
fi

# 驗證 SSHD 配置語法
if sshd -t > /dev/null 2>&1; then
    echo "✓ SSHD 配置語法正確"
else
    echo "✗ SSHD 配置有錯誤"
    sshd -t
fi

# 5. 重啟服務與防火牆
echo "[5/6] 重啟服務與設定防火牆..."
systemctl restart ssh
if command -v ufw > /dev/null; then
    ufw allow ssh >/dev/null
    echo "Firewall (UFW): SSH allowed."
fi

# 6. 輸出資訊
IP_ADDR=$(hostname -I | awk '{print $1}')

echo ""
echo "##########################################"
echo "           安裝完成！設定總表             "
echo "##########################################"
echo "SFTP Server IP : $IP_ADDR"
echo "Port           : 22"
echo ""
echo "請依據下方資訊填入各系統的備份設定頁面："
echo "------------------------------------------"
echo "[1] vCenter (VAMI)"
echo "    Protocol : SFTP"
echo "    Location : $IP_ADDR:/upload"
echo "    User     : $VC_USER"
echo "------------------------------------------"
echo "[2] NSX Manager"
echo "    Protocol : SFTP"
echo "    Directory: /upload"
echo "    User     : $NSX_USER"
echo "------------------------------------------"
echo "[3] SDDC Manager"
echo "    Path     : /upload"
echo "    User     : $SDDC_USER"
echo "------------------------------------------"
echo "注意: 使用 Chroot 限制，使用者登入後只能看到 /upload 目錄。"
echo "##########################################"
