# VCF 9.1 離線 Depot — 用「官方 metadata zip + 自己下 binary」建 depot

一種**輕量**的離線 depot 建法：不搬整包（~180GiB tar），而是用 Broadcom 官方的
**metadata zip**（幾 MB）鋪好 depot 的 metadata（含 sync 必要的 Compatibility），
再用 token 自己**只下要的元件 binary** 塞進去。全新 installer 實測可正常 sync + 下載。

> 對照另兩份：`CUSTOMER-DEPLOY-GUIDE.md` / `UPLOAD-STEPS.md` 是「完整 tar」交付法。
> 本文是「metadata zip + 選擇性下 binary」法，適合只需要部分元件、或想省搬運量。

---

## 為什麼這樣可行（關鍵）

- **token 直讀 catalog 抓得到 binary，但抓不到 `Compatibility` 互通矩陣**（那要 activation
  code / vvs OAuth）。而 **VCF Installer 的 offline depot sync *需要*
  `COMP/SDDC_MANAGER_VCF/Compatibility/VmwareCompatibilityData.json`**，少了它 sync 會卡
  `Vmware compatibility data download failed`。
- **官方 metadata zip 內含 Compatibility**（以及 catalog、manifest、vSAN HCL、vCenter
  upgrade_info）。所以：**metadata 用官方 zip 鋪 → sync 過得了；binary 用 token 自己下 → 省搬運**。

## 交付/準備物

| 檔案 | 說明 |
|------|------|
| `vcf-9.1.0.0100-offline-depot-metadata.zip` | Broadcom 官方 metadata 包（含 Compatibility）。頂層是 `PROD/` |
| `create_vcf9_depot_server_v5.sh` | 建 depot server（若還沒有 depot server） |
| `import_vcf9depot_ca.sh` | 把 depot 憑證匯入 installer |
| `my-vcfdepot.sh`（或 `My-VcfDepot.ps1`）+ 下載 token | 用 token 直讀 catalog、下 binary |

⚠️ 腳本從 Windows 取得後先轉 LF：`sed -i 's/\r$//' *.sh`

---

## 第一段：DEPOT 端

### 1. 建 depot server（若尚無；已有可跳過）
```bash
sudo bash create_vcf9_depot_server_v5.sh --fqdn <DEPOT_FQDN> --ip <DEPOT_IP> --web-server nginx
# 產出 depot 根目錄 /opt/vcf-depot/vcf9，服務 https://<DEPOT_IP>/PROD/，憑證 /etc/nginx/vcf9-certs/vcf9-depot.crt
```

### 2. 用官方 metadata zip 鋪 metadata（含 Compatibility）
```bash
D=/opt/vcf-depot/vcf9
# 解到 depot 根目錄（zip 頂層就是 PROD/）
python3 -c "import zipfile; zipfile.ZipFile('vcf-9.1.0.0100-offline-depot-metadata.zip').extractall('$D')"
#  -> $D/PROD/metadata/... + $D/PROD/COMP/SDDC_MANAGER_VCF/Compatibility/VmwareCompatibilityData.json + vsan/hcl
```

### 3. 用 token 下要的元件 binary，塞進同一個 depot
> **關鍵：binary 版本要對得上「zip 的 catalog」。** zip 是某個時間點（0100）的快照；
> `my-vcfdepot` 讀的是**即時** catalog，可能有更新版本（不在 zip 裡）。用 `--filename-like`
> 釘住 zip catalog 裡實際有的版本，才不會下到 installer 不認的版本。

先查 zip catalog 裡某元件是哪版：
```bash
python3 - <<'PY'
import json
d=json.load(open('/opt/vcf-depot/vcf9/PROD/metadata/productVersionCatalog/v1/productVersionCatalog.json'))
def walk(o):
    if isinstance(o,dict):
        for k,v in o.items():
            if k=='VIDB' and isinstance(v,list):
                for e in v: print(k, e.get('productVersion'))
            walk(v)
    elif isinstance(o,list):
        [walk(x) for x in o]
walk(d)
PY
# 例：VIDB 9.1.0.0.25368698
```

下該版 binary（釘版本）：
```bash
bash my-vcfdepot.sh -t token.txt --component VIDB \
     --filename-like '*9.1.0.0.25368698*' --download -o /opt/vcf-depot/vcf9
#  每檔 sha256 對照簽章 catalog；要幾個元件就重複幾次（TELEMETRY_ACCEPTOR、SDDC_MANAGER_VCF…）
```

### 4. 收權限 + reload + 自我驗證
```bash
chown -R www-data:www-data /opt/vcf-depot/vcf9      # RHEL/Rocky 改 nginx
find /opt/vcf-depot/vcf9 -type d -exec chmod 0500 {} +
find /opt/vcf-depot/vcf9 -type f -exec chmod 0400 {} +
nginx -t && systemctl reload nginx

curl -sk -u 'vcfdepot:VMware1!VMware1!' https://<DEPOT_IP>/PROD/metadata/productVersionCatalog/v1/productVersionCatalog.json -o /dev/null -w 'catalog %{http_code}\n'
curl -sk -u 'vcfdepot:VMware1!VMware1!' https://<DEPOT_IP>/PROD/COMP/SDDC_MANAGER_VCF/Compatibility/VmwareCompatibilityData.json -o /dev/null -w 'compat  %{http_code}\n'   # 要 200
```

---

## 第二段：INSTALLER 端

```bash
# 1. 匯憑證（installer 上 vcf 登入 → su -）
sudo bash import_vcf9depot_ca.sh --url-insecure https://<DEPOT_IP>:443
systemctl restart lcm.service
```
```powershell
# 2. 接 depot + sync + 下載（PowerShell）
$inst='https://<INSTALLER_IP>'; $depotIp='<DEPOT_IP>'
$tok=Invoke-RestMethod "$inst/v1/tokens" -Method Post -SkipCertificateCheck -ContentType application/json -Body (@{username='admin@local';password='<PW>'}|ConvertTo-Json)
$h=@{Authorization="Bearer $($tok.accessToken)"}
$body=@{depotConfiguration=@{isOfflineDepot=$true;url="https://$depotIp"};offlineAccount=@{username='vcfdepot';password='VMware1!VMware1!'}}|ConvertTo-Json
Invoke-RestMethod "$inst/v1/system/settings/depot" -Method Put -Headers $h -ContentType application/json -Body $body -SkipCertificateCheck
Invoke-RestMethod "$inst/v1/system/settings/depot/depot-sync-info" -Method Patch -Headers $h -SkipCertificateCheck
do{Start-Sleep 10;$s=(Invoke-RestMethod "$inst/v1/system/settings/depot/depot-sync-info" -Headers $h -SkipCertificateCheck).syncStatus;$s}while($s-ne'SYNCED')
# UI：Bundle Management → 勾元件（選 depot 內有的版本）→ DOWNLOAD → 等 Downloaded
```

---

## 實測驗證（全新環境）

全新 Ubuntu VM 跑 v5 建 depot → 灌官方 metadata zip + token 下的 binary → 全新 installer：

| 步驟 | 結果 |
|------|------|
| installer 接 depot | `DEPOT_CONNECTION_SUCCESSFUL` |
| metadata sync（Compatibility 來自 zip） | **SYNCED** |
| Telemetry (98MB) 下載 | **SUCCESSFUL** |
| VIDB (1.04GB 真元件) 下載 | **SUCCESSFUL** |

## 踩雷

| 症狀 | 解法 |
|------|------|
| sync 卡 `Vmware compatibility data download failed` | metadata 一定要用**含 Compatibility 的官方 zip** 鋪（token 抓不到這檔） |
| UI 選某版本 Download 失敗 | 該版 binary 不在 depot；或版本不在 zip catalog 內。用 `--filename-like` 下**zip catalog 有的版本** |
| 憑證 `certificate_unknown` | `import_vcf9depot_ca.sh` 把 cert 匯進 JRE cacerts + 重啟 `lcm.service` |
| 帳密對卻報錯 / URL 被拒 | 帳密放頂層 `offlineAccount`；URL 用 **IP** |
