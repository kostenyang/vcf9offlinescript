# VCF 9.1 離線 Depot — 上傳步驟（depot 端 + installer 端，各自獨立）

單機自成一體的操作手冊。分兩段：先在 **Depot 端**把包上傳並開始服務，再到 **Installer 端**
接上 depot 並下載 bundle。照順序做即可。

---

## 交付物（三個檔）

| 檔案 | 放哪 | 用途 |
|------|------|------|
| `vcf9-depot-complete.tar.gz` | depot 端 | 完整 9.1 離線 depot（頂層 `PROD/`；含各元件最新 install 版）。sha256 `007eee1ef0ae2399c38e4116f87e51017c5550a55ad9d456e8cd96d9529fb714`，大小 `193831632275` bytes |
| `create_vcf9_depot_server_v5.sh` | depot 端 | 建 HTTPS + basic-auth depot server |
| `import_vcf9depot_ca.sh` | installer 端 | 把 depot 憑證匯入 installer 信任庫 |

- depot 帳密預設：`vcfdepot / VMware1!VMware1!`
- ⚠️ 腳本從 Windows 拿到後若跑不動，先轉 LF：`sed -i 's/\r$//' *.sh`

> **若交付物是 3 份 7-Zip 分割檔**（`vcf9-depot-complete.7z.001/.002/.003`）：3 份放同一資料夾，
> 先在 **.001** 上跑 7z 合併還原（會自動抓 .002/.003），再接下面步驟：
> ```bash
> 7z x vcf9-depot-complete.7z.001        # -> 還原 vcf9-depot-complete.tar.gz
> sha256sum vcf9-depot-complete.tar.gz   # 應為 007eee1ef0ae2399c38e4116f87e51017c5550a55ad9d456e8cd96d9529fb714
> ```
> 這個 tar **自帶官方 metadata + Compatibility + 全部元件 binary**（126 檔 / 22 元件），是完整可
> sync 的 depot，**不需另配 metadata**。（若只有 binary、缺官方 metadata，見 `METADATA-ZIP-DEPOT.md`。）

---

# 第一段：DEPOT 端（把包上傳並開始服務）

> 選 A 或 B 其中一種：
> **A = 獨立一台 depot server**（建議，多台 installer 可共用）
> **B = 不另建主機，把 depot 直接放 installer 本地**（跳到本段最後的「B」小節）

## A. 獨立 depot server

### A-1. 建 depot server（空殼，不要加 `--download-binaries`）
```bash
sudo bash create_vcf9_depot_server_v5.sh \
  --fqdn <DEPOT_FQDN> --ip <DEPOT_IP> \
  --web-server nginx \
  --data-disk /dev/sdb \        # depot 資料放獨立磁碟；已掛載改 --skip-disk-setup
  --import-ca
```
產出：depot 根目錄 `/opt/vcf-depot/vcf9`（服務 `https://<DEPOT_IP>/PROD/`）、
自簽憑證 `/etc/nginx/vcf9-certs/vcf9-depot.crt`（含 IP-SAN）。

### A-2. 上傳交付包並解開
```bash
scp vcf9-depot-complete.tar.gz root@<DEPOT_IP>:/root/
ssh root@<DEPOT_IP>

sha256sum /root/vcf9-depot-complete.tar.gz    # 對照交付清單

tar -xzf /root/vcf9-depot-complete.tar.gz -C /opt/vcf-depot/vcf9/    # 頂層就是 PROD/
```

### A-3. 收權限 + reload + 自我驗證
```bash
chown -R www-data:www-data /opt/vcf-depot/vcf9        # RHEL/Rocky 改 nginx
find /opt/vcf-depot/vcf9 -type d -exec chmod 0500 {} +
find /opt/vcf-depot/vcf9 -type f -exec chmod 0400 {} +
# RHEL + SELinux 另跑： restorecon -Rv /opt/vcf-depot/vcf9

nginx -t && systemctl reload nginx

curl -sk -u 'vcfdepot:VMware1!VMware1!' \
  https://<DEPOT_IP>/PROD/metadata/productVersionCatalog/v1/productVersionCatalog.json \
  -o /dev/null -w 'HTTP %{http_code}\n'                # 要回 HTTP 200
```
→ depot 端完成。**depot URL = `https://<DEPOT_IP>`（用 IP，不要 FQDN）**。跳到「第二段」。

## B. depot 放 installer 本地（不另建主機）

在 **installer** 上用 `vcf` 登入 → `su -` 取得 root：
```bash
# 上傳 + 解到大容量掛載
scp vcf9-depot-complete.tar.gz root@<INSTALLER_IP>:/nfs/vmware/vcf/nfs-mount/
mkdir -p /nfs/vmware/vcf/nfs-mount/localdepot/vcf9
tar -xzf /nfs/vmware/vcf/nfs-mount/vcf9-depot-complete.tar.gz \
    -C /nfs/vmware/vcf/nfs-mount/localdepot/vcf9/

# 開本地 depot（:8443 nginx + 憑證 + 匯信任庫 + 重啟 lcm，一支搞定）
bash _localdepot_on_installer.sh <INSTALLER_IP> /nfs/vmware/vcf/nfs-mount/localdepot/vcf9
```
→ **depot URL = `https://<INSTALLER_IP>:8443`**。憑證已在腳本內匯好，第二段的 A-3 憑證匯入可略過，
直接做 A-4 起。

---

# 第二段：INSTALLER 端（接 depot 並下載）

## S-1. 匯入 depot 憑證（模式 A 必做；模式 B 已在腳本內做過可略）
installer 上 `vcf` 登入 → `su -`：
```bash
sudo bash import_vcf9depot_ca.sh --url-insecure https://<DEPOT_IP>:443
systemctl restart lcm.service          # 是 lcm.service，不是 vcf-installer
```

## S-2. 設定 offline depot
**UI**：`Administration → Depot Settings` → Offline depot →
URL `https://<DEPOT_URL>`、帳號 `vcfdepot`、密碼 `VMware1!VMware1!` → 存檔後自動 sync。
（模式 A 的 URL 是 `https://<DEPOT_IP>`；模式 B 是 `https://<INSTALLER_IP>:8443`）

**API**（PowerShell，自動化用）：
```powershell
$inst='https://<INSTALLER_IP>'; $depotUrl='https://<DEPOT_URL>'
$tok=Invoke-RestMethod "$inst/v1/tokens" -Method Post -SkipCertificateCheck `
  -ContentType application/json -Body (@{username='admin@local';password='<INSTALLER_ADMIN_PW>'}|ConvertTo-Json)
$h=@{Authorization="Bearer $($tok.accessToken)"}

# 帳密放頂層 offlineAccount
$body=@{ depotConfiguration=@{isOfflineDepot=$true; url=$depotUrl}
         offlineAccount    =@{username='vcfdepot'; password='VMware1!VMware1!'} } | ConvertTo-Json
Invoke-RestMethod "$inst/v1/system/settings/depot" -Method Put -Headers $h `
  -ContentType application/json -Body $body -SkipCertificateCheck

# 觸發 sync，等到 SYNCED
Invoke-RestMethod "$inst/v1/system/settings/depot/depot-sync-info" -Method Patch -Headers $h -SkipCertificateCheck
do{Start-Sleep 15;$st=(Invoke-RestMethod "$inst/v1/system/settings/depot/depot-sync-info" -Headers $h -SkipCertificateCheck).syncStatus;$st}while($st-ne'SYNCED')
```

## S-3. 下載 bundle（讓 UI 從 Not downloaded 變 Downloaded）
**UI**：
1. 左側 → **Bundle Management / Download**（頂端有 `DOWNLOAD`、`DELETE`）。
2. 每列 **Version 下拉**選版本（本包各元件最新版都在，選最新即可）。
3. 勾選元件（左上 checkbox 可全選）。
4. 按上方 **DOWNLOAD**。
5. **Download Status**：`Not downloaded` → `Scheduled` → `In progress %` → **`Downloaded`**。全綠才算完成。

**API**（等同全選按 Download）：
```powershell
$dl=@{bundleDownloadSpec=@{downloadNow=$true}}|ConvertTo-Json
$bundles=(Invoke-RestMethod "$inst/v1/bundles" -Headers $h -SkipCertificateCheck).elements
foreach($b in $bundles){ Invoke-RestMethod "$inst/v1/bundles/$($b.id)" -Method Patch -Headers $h `
  -ContentType application/json -Body $dl -SkipCertificateCheck -EA SilentlyContinue }
# 輪詢
(Invoke-RestMethod "$inst/v1/bundles" -Headers $h -SkipCertificateCheck).elements |
  Group-Object downloadStatus | Select Name,Count
```
下載的實體檔會落在 installer 的 `/nfs/vmware/vcf/nfs-mount/bundle/<id>/`。

---

## 驗收 + 常見雷

**驗收**：depot curl 回 200 → installer `DEPOT_CONNECTION_SUCCESSFUL` + `SYNCED` →
bundle `Downloaded`/`SUCCESSFUL` → `/nfs/.../bundle/<id>/` 有實體檔。

| 症狀 | 解法 |
|------|------|
| 帳密對卻報 `Invalid username or password` | 憑證沒匯進信任庫 → 做 S-1 + 重啟 `lcm.service` |
| depot URL 報 `INVALID_URL` | 用 **IP**，不要 FQDN |
| 帳密欄位錯 | 放**頂層 `offlineAccount`**，不要塞 `depotConfiguration` |
| 某元件最新版 Download 失敗 | 該版 binary 不在 depot → 選 depot 內有的版本（本包已含各元件最新 install 版） |
| Cloud proxy / License server 只有 `9.1.0.0` | 這兩者無 patch，base 即最新，正常 |
| root SSH 連不上 | `vcf` 登入再 `su -`（root 密碼＝OVF ROOT_PASSWORD） |
| (模式B) `certificate_unknown` | 憑證要進 JRE cacerts `/usr/lib/jvm/openjdk-java21-headless.x86_64/lib/security/cacerts` + 重啟 lcm（`_localdepot_on_installer.sh` 已內建） |
| (模式B) nginx 500 `crypt_r()` | htpasswd 用 `python3 crypt`（腳本已改） |
| 腳本 `set: pipefail: invalid option` | CRLF → `sed -i 's/\r$//' *.sh` |
