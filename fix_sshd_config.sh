#!/bin/bash

# ==========================================
# SSHD Configuration Fix Script
# 用于修复 sftpv1.sh 造成的重复配置
# ==========================================

SSHD_CONFIG="/etc/ssh/sshd_config"
BASE_DIR="/data/sftp"
GROUP_NAME="sftp_users"

echo "=========================================="
echo "   SSHD 配置修复工具"
echo "=========================================="
echo ""

# 检查是否以 root 运行
if [ "$EUID" -ne 0 ]; then
    echo "错误: 请使用 sudo 执行此脚本"
    exit 1
fi

# 显示当前配置
echo "[1] 当前 SSHD Match 配置数量:"
CONFIG_COUNT=$(grep -c "Match Group sftp_users" "$SSHD_CONFIG" 2>/dev/null || echo 0)
echo "    检测到: $CONFIG_COUNT 个 Match Group 配置"

if [ "$CONFIG_COUNT" -gt 1 ]; then
    echo "    ⚠️ 检测到重复配置，正在修复..."
    echo ""
    
    # 备份
    cp "$SSHD_CONFIG" "${SSHD_CONFIG}.backup_$(date +%Y%m%d_%H%M%S)"
    echo "[2] 备份原始配置文件"
    
    # 删除所有 VMware SFTP 相关配置
    echo "[3] 删除旧配置..."
    sed -i '/^# --- VMware Backup SFTP Settings/,/^# -----------------------------------$/d' "$SSHD_CONFIG"
    sed -i '/^Match Group sftp_users/,/^ForceCommand internal-sftp$/d' "$SSHD_CONFIG"
    
    # 确保 Subsystem 正确
    echo "[4] 检查 Subsystem 配置..."
    if grep -q "^Subsystem sftp" "$SSHD_CONFIG"; then
        sed -i 's|^Subsystem.*sftp.*|Subsystem sftp internal-sftp|g' "$SSHD_CONFIG"
    else
        # 添加 Subsystem 配置（在最后一个 Subsystem 后或在文件合适位置）
        if grep -q "^Subsystem" "$SSHD_CONFIG"; then
            sed -i '/^Subsystem/a Subsystem sftp internal-sftp' "$SSHD_CONFIG" | head -1
        else
            echo "Subsystem sftp internal-sftp" >> "$SSHD_CONFIG"
        fi
    fi
    
    # 添加新的正确配置
    echo "[5] 添加新的 Chroot 配置..."
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
    
    echo "    ✓ 新配置已添加"
else
    echo "    ✓ 配置数量正确，无需修复"
fi

echo ""

# 验证语法
echo "[6] 验证 SSHD 配置语法..."
if sshd -t 2>&1; then
    echo "    ✓ 配置语法正确"
else
    echo "    ✗ 配置语法有错误"
    sshd -t
    exit 1
fi

echo ""

# 显示最终配置
echo "[7] 最终配置内容:"
echo "---"
grep -A 6 "Match Group sftp_users" "$SSHD_CONFIG"
echo "---"

echo ""

# 重启 SSH 服务
echo "[8] 重启 SSH 服务..."
systemctl restart ssh

if systemctl is-active --quiet ssh; then
    echo "    ✓ SSH 服务已重启"
else
    echo "    ✗ SSH 服务重启失败"
    exit 1
fi

echo ""

# 最终验证
echo "[9] 最终验证:"
NEW_CONFIG_COUNT=$(grep -c "Match Group sftp_users" "$SSHD_CONFIG" 2>/dev/null || echo 0)
echo "    Match Group 配置数量: $NEW_CONFIG_COUNT"

if [ "$NEW_CONFIG_COUNT" -eq 1 ]; then
    echo ""
    echo "=========================================="
    echo "✓ 修复完成！SSHD 配置已恢复正常"
    echo "=========================================="
    exit 0
else
    echo ""
    echo "=========================================="
    echo "✗ 修复失败！配置仍有问题"
    echo "=========================================="
    exit 1
fi
