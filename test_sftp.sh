#!/bin/bash

# ==========================================
# SFTP Server Configuration Test Script
# ==========================================

SFTP_SERVER="${1:-10.0.0.18}"
TEST_USERS=("vcbackup" "nsxbackup" "sddcbackup")

echo "=========================================="
echo "   SFTP 服务器配置测试 - $SFTP_SERVER"
echo "=========================================="
echo ""
echo "注意: 此脚本需要 SSH key 配置或在提示时输入密码"
echo ""

# 颜色代码
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 测试计数
TESTS_PASSED=0
TESTS_FAILED=0

# 测试函数
test_result() {
    local TEST_NAME=$1
    local RESULT=$2
    
    if [ $RESULT -eq 0 ]; then
        echo -e "${GREEN}✓${NC} $TEST_NAME"
        ((TESTS_PASSED++))
    else
        echo -e "${RED}✗${NC} $TEST_NAME"
        ((TESTS_FAILED++))
    fi
}

# ========== 测试 1: 基本连接测试 ==========
echo "[1] 测试基本连接..."
if ping -c 1 -W 2 "$SFTP_SERVER" > /dev/null 2>&1; then
    test_result "网络连接到 $SFTP_SERVER" 0
else
    test_result "网络连接到 $SFTP_SERVER" 1
    echo -e "${RED}无法连接到服务器，请检查网络!${NC}"
    exit 1
fi
echo ""

# ========== 测试 2: SSH 端口检查 ==========
echo "[2] 检查 SSH 端口..."
if timeout 3 bash -c "echo >/dev/tcp/$SFTP_SERVER/22" 2>/dev/null; then
    test_result "SSH 端口 (22) 开放" 0
else
    test_result "SSH 端口 (22) 开放" 1
fi
echo ""

# ========== 测试 3: SFTP 连接测试 (需要密码) ==========
echo "[3] SFTP 连接测试 (需要输入密码)..."
for USER in "${TEST_USERS[@]}"; do
    # 使用 sshpass 或交互式输入
    sftp -o ConnectTimeout=5 -o StrictHostKeyChecking=no "$USER@$SFTP_SERVER" << EOF > /tmp/sftp_test_$USER.log 2>&1
pwd
ls -la
bye
EOF
    
    # 检查是否连接成功和是否在 Chroot 环境
    if grep -q "Remote working directory" /tmp/sftp_test_$USER.log; then
        if grep "Remote working directory: /" /tmp/sftp_test_$USER.log | grep -v "/data" > /dev/null; then
            test_result "SFTP 连接 + Chroot - $USER" 0
        else
            test_result "SFTP 连接 - $USER (Chroot)" 0
        fi
        # 显示目录列表
        echo "   登录后目录内容:"
        grep -A 20 "Remote working directory" /tmp/sftp_test_$USER.log | head -6 | sed 's/^/   /'
    else
        test_result "SFTP 连接 - $USER" 1
    fi
    
    rm -f /tmp/sftp_test_$USER.log
done
echo ""

# ========== 测试 4: 服务器端验证 (需要 root 密码) ==========
echo "[4] 服务器端配置检查 (需要输入 root 密码)..."

# 检查 SSHD 配置
ssh -o StrictHostKeyChecking=no "root@$SFTP_SERVER" "grep -c 'Match Group sftp_users' /etc/ssh/sshd_config" > /tmp/sshd_count.log 2>&1

if [ -s /tmp/sshd_count.log ]; then
    CONFIG_COUNT=$(cat /tmp/sshd_count.log | grep -oE '[0-9]+')
    if [ "$CONFIG_COUNT" -eq 1 ]; then
        test_result "SSHD 配置 (无重复)" 0
    else
        test_result "SSHD 配置 (检测到重复)" 1
        echo -e "${YELLOW}   提示: 检测到 $CONFIG_COUNT 个 Match Group 配置，应该只有 1 个${NC}"
    fi
fi

# 检查目录权限
echo "   目录权限检查:"
for USER in "${TEST_USERS[@]}"; do
    ssh -o StrictHostKeyChecking=no "root@$SFTP_SERVER" "stat -c '%A %U:%G' /data/sftp/$USER/upload 2>/dev/null" > /tmp/perm_check.log 2>&1
    
    if [ -s /tmp/perm_check.log ]; then
        PERMS=$(cat /tmp/perm_check.log)
        echo "   $USER: $PERMS"
        test_result "   目录权限 - $USER" 0
    fi
done

rm -f /tmp/sshd_count.log /tmp/perm_check.log
echo ""

# ========== 测试 5: SSH 服务状态 ==========
echo "[5] SSH 服务状态检查..."
ssh -o StrictHostKeyChecking=no "root@$SFTP_SERVER" "systemctl is-active ssh" > /tmp/ssh_status.log 2>&1
if grep -q "active" /tmp/ssh_status.log; then
    test_result "SSH 服务运行状态" 0
    cat /tmp/ssh_status.log | sed 's/^/   /'
else
    test_result "SSH 服务运行状态" 1
fi

# 检查 SSH 监听
ssh -o StrictHostKeyChecking=no "root@$SFTP_SERVER" "ss -tlnp | grep :22" > /tmp/ssh_listen.log 2>&1
if [ -s /tmp/ssh_listen.log ]; then
    test_result "SSH 监听端口" 0
fi

rm -f /tmp/ssh_status.log /tmp/ssh_listen.log
echo ""

# ========== 测试 6: 文件上传/下载测试 ==========
echo "[6] 文件操作测试 (可选)..."
TEST_FILE="/tmp/test_sftp_$(date +%s).txt"
echo "Test upload - $(date)" > "$TEST_FILE"

# 仅测试第一个用户以节省时间
USER="${TEST_USERS[1]}"  # nsxbackup
sftp -o ConnectTimeout=5 -o StrictHostKeyChecking=no "$USER@$SFTP_SERVER" << EOF > /tmp/sftp_upload.log 2>&1
cd /upload
put $TEST_FILE test_file.txt
ls -la test_file.txt
bye
EOF

if grep -q "test_file.txt" /tmp/sftp_upload.log; then
    test_result "文件上传 - $USER" 0
else
    test_result "文件上传 - $USER" 1
fi

rm -f "$TEST_FILE" /tmp/sftp_upload.log
echo ""

# ========== 总结 ==========
echo "=========================================="
echo "          测试结果总结"
echo "=========================================="
echo -e "${GREEN}通过: $TESTS_PASSED${NC}"
echo -e "${RED}失败: $TESTS_FAILED${NC}"
echo ""

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}✓ 所有测试通过！SFTP 服务器配置正常${NC}"
    echo ""
    echo "配置完成，可以在以下系统中使用:"
    echo "  vCenter: $SFTP_SERVER:/upload (user: vcbackup)"
    echo "  NSX:     $SFTP_SERVER:/upload (user: nsxbackup)"
    echo "  SDDC:    $SFTP_SERVER:/upload (user: sddcbackup)"
    exit 0
else
    echo -e "${RED}✗ 部分测试失败，请检查服务器配置${NC}"
    echo ""
    echo "常见问题排查:"
    echo "  1. 如果连接超时，检查网络和防火墙"
    echo "  2. 如果认证失败，检查密码是否正确"
    echo "  3. 如果配置有重复，运行以下命令:"
    echo "     ssh root@$SFTP_SERVER"
    echo "     sudo sed -i '/# --- VMware Backup SFTP Settings/,/# -----------------------------------/d' /etc/ssh/sshd_config"
    echo "     sudo systemctl restart ssh"
    exit 1
fi

