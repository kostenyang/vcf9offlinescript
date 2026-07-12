# VCF 9.1 離線 Depot 部署與下載指南（客戶交付）

本文件說明如何用交付的 **VCF 9.1 完整離線 depot 壓縮包**，讓 VCF Installer
（離線環境）下載所有元件 bundle 至 **Download 成功**。提供兩種部署模式，擇一即可。

---

## 0. 交付物清單

| 檔案 | 說明 |
|------|------|
| `vcf9-depot-complete.tar.gz` | 完整 9.1 離線 depot（含各元件**最新版** install bundle）。頂層目錄為 `PROD/`。sha256 見隨附交付清單。 |
| `create_vcf9_depot_server_v5.sh` | 一鍵建立 HTTPS + basic-auth depot server（nginx / Apache 皆支援） |
| `import_vcf9depot_ca.sh` | 把 depot 自簽憑證匯入 VCF Installer 系統 + Java 信任庫 |

**帳密（可自訂）**：depot basic-auth 預設 `vcfdepot / VMware1!VMware1!`
（用 v5 的 `--user/--password` 可改）。

**depot 內容**：涵蓋 automated-install 全套 + 各元件 9.1 最新 install 版本
（vCenter / NSX / SDDC Manager / VCF Automation / VCF Operations / Cloud Proxy /
License Server / Fleet & SDDC Lifecycle / Salt / Identity Broker / Migration 等）。

---

## 模式 A：獨立 Depot Server（建議，可多台 Installer 共用）

### A-1. 建立 depot server（空殼，**不要**加 `--download-binaries`）

```bash
sudo bash create_vcf9_depot_server_v5.sh \
  --fqdn <DEPOT_FQDN> --ip <DEPOT_IP> \
  --web-server nginx \
  --data-disk /dev/sdb \      # 若 depot 資料要放獨立磁碟；已掛載則用 --skip-disk-setup
  --import-ca
```
產出：depot 根目錄 `/opt/vcf-depot/vcf9`（對外服務 `https://<DEPOT_IP>/PROD/`）、
自簽憑證 `/etc/nginx/vcf9-certs/vcf9-depot.crt`（含 IP-SAN）。

### A-2. 灌入交付包

```bash
scp vcf9-depot-complete.tar.gz root@<DEPOT_IP>:/root/
ssh root@<DEPOT_IP>

# 驗證傳輸完整（對照交付清單的 sha256）
sha256sum /root/vcf9-depot-complete.tar.gz

# 解壓到 depot 根目錄（tar 頂層就是 PROD/）
tar -xzf /root/vcf9-depot-complete.tar.gz -C /opt/vcf-depot/vcf9/

# 重收權限（v5 要求 0500 目錄 / 0400 檔、屬主 www-data）
chown -R www-data:www-data /opt/vcf-depot/vcf9      # RHEL/Rocky 改 nginx
find /opt/vcf-depot/vcf9 -type d -exec chmod 0500 {} +
find /opt/vcf-depot/vcf9 -type f -exec chmod 0400 {} +
# RHEL + SELinux 另跑： restorecon -Rv /opt/vcf-depot/vcf9

nginx -t && systemctl reload nginx

# 自我驗證（要回 HTTP 200）
curl -sk -u 'vcfdepot:VMware1!VMware1!' \
  https://<DEPOT_IP>/PROD/metadata/productVersionCatalog/v1/productVersionCatalog.json \
  -o /dev/null -w 'HTTP %{http_code}\n'
```

### A-3. VCF Installer 匯入 depot 憑證（**必做，否則帳密會誤報錯**）

在 **VCF Installer** 上，用 `vcf` 帳號登入 SSH（root SSH 預設關）後 `su -` 取得 root：

```bash
sudo bash import_vcf9depot_ca.sh --url-insecure https://<DEPOT_IP>:443
systemctl restart lcm.service        # 是 lcm.service，不是 vcf-installer
```

### A-4. Installer 設定 offline depot（UI 或 API 擇一）

**UI**：`Administration → Depot Settings` → 選 Offline depot →
URL 填 `https://<DEPOT_IP>`（**用 IP，不要用 FQDN**）、帳號 `vcfdepot`、密碼 `VMware1!VMware1!`
→ 儲存後會自動 sync catalog。

**API**（在能連到 Installer 的機器上，PowerShell）：

```powershell
$inst='https://<INSTALLER_IP>'; $depotIp='<DEPOT_IP>'
$tok=Invoke-RestMethod "$inst/v1/tokens" -Method Post -SkipCertificateCheck `
  -ContentType application/json -Body (@{username='admin@local';password='<INSTALLER_ADMIN_PW>'}|ConvertTo-Json)
$h=@{Authorization="Bearer $($tok.accessToken)"}

# 帳密放頂層 offlineAccount；url 用 IP
$body=@{
  depotConfiguration=@{isOfflineDepot=$true; url="https://$depotIp"}
  offlineAccount    =@{username='vcfdepot'; password='VMware1!VMware1!'}
} | ConvertTo-Json
Invoke-RestMethod "$inst/v1/system/settings/depot" -Method Put -Headers $h `
  -ContentType application/json -Body $body -SkipCertificateCheck

# 觸發 metadata sync，等到 SYNCED
Invoke-RestMethod "$inst/v1/system/settings/depot/depot-sync-info" -Method Patch -Headers $h -SkipCertificateCheck
do{Start-Sleep 15;$st=(Invoke-RestMethod "$inst/v1/system/settings/depot" -Headers $h -SkipCertificateCheck).depotSyncInfo.syncStatus;$st}while($st-ne'SYNCED')
```

### A-5. 下載 bundle

**UI**：進 bundle 下載頁 → 勾選元件（版本下拉可選最新）→ **Download** → 等 Download Status = Success。

**API**（下載全部可下載的 bundle 並等到成功）：

```powershell
$dl=@{bundleDownloadSpec=@{downloadNow=$true}}|ConvertTo-Json
$bundles=(Invoke-RestMethod "$inst/v1/bundles" -Headers $h -SkipCertificateCheck).elements
foreach($b in $bundles){
  Invoke-RestMethod "$inst/v1/bundles/$($b.id)" -Method Patch -Headers $h `
    -ContentType application/json -Body $dl -SkipCertificateCheck -EA SilentlyContinue
}
# 輪詢狀態
Invoke-RestMethod "$inst/v1/bundles" -Headers $h -SkipCertificateCheck).elements |
  Group-Object downloadStatus | Select Name,Count
```
下載的 bundle 檔案會落在 Installer 的 `/nfs/vmware/vcf/nfs-mount/bundle/<id>/`。

---

## 模式 B：Depot 直接放在 Installer 上（本地，免額外主機）

適用單台 Installer、不想另建 depot server。把交付包解在 Installer 內，用 Installer
內建的 nginx 在 `:8443` 開本地 depot，Installer 指向自己。

在 **VCF Installer**（`su -` 取得 root）：

```bash
# 1. 傳包 + 解壓到大容量掛載（/nfs/... 有數百 GB）
scp vcf9-depot-complete.tar.gz root@<INSTALLER_IP>:/nfs/vmware/vcf/nfs-mount/
mkdir -p /nfs/vmware/vcf/nfs-mount/localdepot/vcf9
tar -xzf /nfs/vmware/vcf/nfs-mount/vcf9-depot-complete.tar.gz \
    -C /nfs/vmware/vcf/nfs-mount/localdepot/vcf9/

# 2. 開本地 depot（nginx :8443 + 憑證 + 匯信任庫 + 重啟 lcm）
bash _localdepot_on_installer.sh <INSTALLER_IP> /nfs/vmware/vcf/nfs-mount/localdepot/vcf9
```

之後 depot URL 用 `https://<INSTALLER_IP>:8443`、帳密 `vcfdepot / VMware1!VMware1!`，
其餘 sync / 下載步驟同 **A-4 / A-5**（URL 換成 `:8443`）。

---

## 常見問題 / 踩雷筆記

| 症狀 | 原因 | 解法 |
|------|------|------|
| depot 帳密正確卻報 `Invalid username or password` | 憑證沒匯進 Installer 系統信任庫 | 跑 A-3 的 `import_vcf9depot_ca.sh` + `systemctl restart lcm.service` |
| depot URL 被判 `INVALID_URL` | 用了 FQDN（`.local`）而 cert 只認 IP-SAN | URL 一律用 **IP**（v5 憑證已含 IP-SAN） |
| 帳密欄位放錯 | 塞進 `depotConfiguration` 內 | 帳密要放**頂層 `offlineAccount`** |
| 某元件選「最新 patch 版」Download 失敗 | 該版本 binary 不在 depot | depot 內若無該版就選 depot 有的版本；本交付包已含各元件最新 install 版 |
| Cloud proxy / License server 只有 `9.1.0.0` 可選 | 這兩者若無 patch 版即以 base 為最新 | 屬正常，非缺料 |
| Installer root SSH 連不上 | root SSH 預設關閉 | 用 `vcf` / 安裝時的 local 密碼登入，再 `su -`（root 密碼＝OVF 部署時的 ROOT_PASSWORD） |
| **(模式B)** 本地 depot 連線報 `certificate_unknown` / `Unable to construct a valid chain` | 憑證沒進 **lcm 用的 JRE cacerts**（只做系統 rehash 不夠） | keytool 匯入 `/usr/lib/jvm/openjdk-java21-headless.x86_64/lib/security/cacerts`（storepass `changeit`）再 `systemctl restart lcm.service`；`_localdepot_on_installer.sh` 已內建 |
| **(模式B)** nginx 回 HTTP 500 `crypt_r() failed` | Photon 的 `openssl passwd -apr1` 產出**空 hash** | htpasswd 改用 `python3 crypt` SHA-512；腳本已改 |
| **(模式B)** `_localdepot_on_installer.sh` 報 `set: pipefail: invalid option` | 從 Windows 取檔帶了 CRLF | `sed -i 's/\r$//' _localdepot_on_installer.sh`（repo `.gitattributes` 已強制 `*.sh` LF） |
| **(模式B)** depot URL 帶 `:8443` 會不會被拒？ | — | **不會**，實測 installer 接受非標準埠 `https://<ip>:8443` |

---

## 驗收標準

- depot server 自我 `curl` 回 **HTTP 200**
- Installer depot 設定 → `DEPOT_CONNECTION_SUCCESSFUL` + `syncStatus = SYNCED`
- bundle 下載 → **Download Status = Success**（UI）/ `downloadStatus = SUCCESSFUL`（API）
- Installer `/nfs/vmware/vcf/nfs-mount/bundle/<id>/` 內出現實體檔
