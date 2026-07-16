# VCF 9.1 離線 Depot — 客戶 OA 平面下載 → 自動歸位 → 可用 depot

客戶在 OA / Broadcom portal 手動下載時，**不可能照 depot 那麼細的資料夾結構擺**，通常就是
把一堆檔全丟同一個資料夾。本文件說明：把這包**平面檔上傳到 depot server**，跑一支 script
**自動分類歸位**成標準 `PROD/COMP/<元件代號>/` depot，配上**對應版本的 metadata**，就能給 VCF
Installer sync + 下載。

> 相關：`CUSTOMER-DEPLOY-GUIDE.md`（完整 tar 交付法）、`UPLOAD-STEPS.md`（上傳步驟）、
> `METADATA-ZIP-DEPOT.md`（metadata zip + token 下 binary）。本文是「**平面亂下 → script 歸位**」法。

---

## 交付/準備物

| 檔案 | 說明 |
|------|------|
| `sort-flat-depot.sh` | 把平面資料夾的檔案照檔名 pattern 歸位成 `PROD/COMP/<代號>/` |
| `create_vcf9_depot_server_v5.sh` | 建 HTTPS + basic-auth nginx depot server |
| `import_vcf9depot_ca.sh` | 把 depot 憑證匯入 VCF Installer |
| `vcf-9.1.0.<NNNN>-offline-depot-metadata.zip` | **對應版本**的官方 metadata（catalog + Compatibility + vsan HCL）|

⚠️ 腳本從 Windows 取得後先轉 LF：`sed -i 's/\r$//' *.sh`

---

## 關鍵觀念：metadata 的版本要對得上 binary

- `sort-flat-depot.sh` 只負責把 **binary + config-schema + depot-manifest** 歸到 COMP 元件夾。
- **catalog / Compatibility / vsan HCL 這層 metadata 由 `offline-depot-metadata.zip` 提供**，
  而且 **catalog 版本必須對應你放的 binary 版本**：
  - depot 放 0400 binary，但 metadata zip 的 catalog 是 0100 → installer sync 只列 0100、
    找不到對應檔 → **Download 失敗**。
- 官方只固定發某些版本的 metadata zip。若手上 zip 版本與 binary 不符，可**用官方 download tool
  下出來的 depot 的 metadata 反做一個對應版本的 zip**（見下方附錄）。

---

## 第一段：DEPOT 端

### 1. 建 depot server（單機一支）
```bash
sudo bash create_vcf9_depot_server_v5.sh \
  --fqdn <DEPOT_FQDN> --ip <DEPOT_IP> --web-server nginx --skip-disk-setup
# 產出 depot 根 /opt/vcf-depot/vcf9，服務 https://<DEPOT_IP>/PROD/，自簽憑證含 IP-SAN
```

### 2. 上傳客戶的「平面包」＋對應 metadata zip
```bash
scp -r <平面資料夾>/  root@<DEPOT_IP>:/root/flat/
scp vcf-9.1.0.<NNNN>-offline-depot-metadata.zip root@<DEPOT_IP>:/root/
```

### 3. 跑 sort script 歸位（binary → COMP，metadata → PROD/metadata）
```bash
# 用法: sort-flat-depot.sh [-m] <平面夾> <輸出depot> [metadata.zip]
#   預設 copy(安全)；-m 改 move(省空間)
bash sort-flat-depot.sh -m /root/flat /opt/vcf-depot/vcf9 /root/vcf-9.1.0.<NNNN>-offline-depot-metadata.zip
# -> /opt/vcf-depot/vcf9/PROD/COMP/<16 元件>/ + PROD/metadata/ + vsan/
#    無法分類的檔會列出並丟到 <輸出>/_unsorted/ 供人工判斷
```

### 4. 收權限 + reload + 自我驗證
```bash
chown -R www-data:www-data /opt/vcf-depot/vcf9
find /opt/vcf-depot/vcf9 -type d -exec chmod 0500 {} +
find /opt/vcf-depot/vcf9 -type f -exec chmod 0400 {} +
nginx -t && systemctl reload nginx
curl -sk -u 'vcfdepot:VMware1!VMware1!' https://<DEPOT_IP>/PROD/metadata/productVersionCatalog/v1/productVersionCatalog.json -o /dev/null -w 'catalog %{http_code}\n'   # 200
curl -sk -u 'vcfdepot:VMware1!VMware1!' https://<DEPOT_IP>/PROD/COMP/SDDC_MANAGER_VCF/Compatibility/VmwareCompatibilityData.json -o /dev/null -w 'compat  %{http_code}\n'  # 200
```

---

## 第二段：INSTALLER 端
```bash
# vcf 登入 → su -（vcf 不能 sudo）
bash import_vcf9depot_ca.sh --url-insecure https://<DEPOT_IP>:443
systemctl restart lcm.service
```
UI：`Administration → Depot Settings` → Offline depot → URL `https://<DEPOT_IP>`（用 IP）、
`vcfdepot / VMware1!VMware1!` → 存檔自動 sync → `SYNCED` → Bundle Management 勾元件 → DOWNLOAD →
全部 `Downloaded`。

---

## 檔名 → 元件代號 對照（sort script 內建）

| 檔名開頭/樣式 | 元件代號 |
|---|---|
| `VMware-VCSA-all-` / `VMware-vCenter-` / `VMware-vlcm-operator-` | VCENTER |
| `nsx-unified-appliance-` | NSX_T_MANAGER |
| `VCF-SDDC-Manager-Appliance-` | SDDC_MANAGER_VCF |
| `Operations-Cloud-Proxy-` | VCF_OPS_CLOUD_PROXY |
| `Operations-Appliance-` / `Operations-Upgrade-` | VROPS |
| `Vcf-License-Server-` | VCF_LICENSE_SERVER |
| `vcf-fleet-lcm-` | VCF_FLEET_LCM |
| `vcf-fleet-depot-` | DEPOT_SERVICE |
| `vcf-sddc-lcm-` | VCF_SDDC_LCM |
| `telemetry-acceptor-` | TELEMETRY_ACCEPTOR |
| `salt-raas-` | VCF_SALT_RAAS |
| `salt-` | VCF_SALT |
| `vidb-` | VIDB |
| `vcfa-` | VRA |
| `vcd-migrator-` | VCF_SERVICE_VCD_MIGRATION_BACKEND |
| `vcf-services-platform-template-` / `vmsp-` | VSP |
| `VMware-VMvisor-Installer-` | ESX_HOST |

（`configuration-schema-*` / `depot-manifest-*` 依檔名內含的元件名跟著歸位。）

---

## 附錄：照 0100 zip 做一個「對應版本」的 metadata zip

當手上 binary 是 0400、但只有 0100 的 metadata zip 時，用官方 download tool 下出來的 0400
depot 的 metadata 反做一個 0400 zip（結構與 0100 zip 完全相同的 13 個檔）：

```python
# python：從 download-tool 下的 depot 抽 metadata 打成 zip
import zipfile, os
src = r'<download-tool 下的 depot 根>'   # 內有 PROD/metadata ...
out = r'vcf-9.1.0.0400-offline-depot-metadata.zip'
paths = [
 'PROD/COMP/SDDC_MANAGER_VCF/Compatibility/VmwareCompatibilityData.json',
 'PROD/COMP/VCENTER/vmw/<uuid>/upgrade_info.sig',
 'PROD/COMP/VCENTER/vmw/<uuid>/upgrade_info.xml',
 'PROD/COMP/VCENTER/vmw/<uuid>/upgrade_info.xml.sha256',
 'PROD/metadata/Compatibility/v1/VmwareCompatibilityData.json',
 'PROD/metadata/Compatibility/v2/VmwareCompatibilityData.json',
 'PROD/metadata/manifest/v1/vcfManifest.json',
 'PROD/metadata/productVersionCatalog/v1/productVersionCatalog.json',
 'PROD/metadata/productVersionCatalog/v1/productVersionCatalog.sig',
 'PROD/metadata/vsan/hcl/all.json',
 'PROD/metadata/vsan/hcl/lastupdatedtime.json',
 'PROD/vsan/hcl/all.json',
 'PROD/vsan/hcl/lastupdatedtime.json',
]
with zipfile.ZipFile(out,'w',zipfile.ZIP_DEFLATED) as z:
    for p in paths: z.write(os.path.join(src,p.replace('/',os.sep)), p)
```
產出的 zip 頂層是 `PROD/`，catalog 為 0400，可餵給 `sort-flat-depot.sh` 第三個參數。

---

## 實測（2026-07-16，截圖見隨附）

| 步驟 | 環境 | 結果 |
|------|------|------|
| depot server | 全新 Ubuntu `rtolab-depot-sort` 172.16.10.57 | v5 建站 OK |
| 平面包上傳 | 48 檔 / 66GB 平面夾 → scp 上 .57 | OK |
| **sort 歸位** | `sort-flat-depot.sh -m` + 自製 0400 metadata zip | **48/48 歸位、0 未分類**；serve catalog/compat/vcenter-iso 全 HTTP 200 |
| installer 接 depot | 全新 `kosten-vcf91-inst-sort` 192.168.114.28 → `https://172.16.10.57` | **DEPOT_CONNECTION_SUCCESSFUL + SYNCED** |
| **下載** | .28 觸發 0400 下載 | **16 元件全 Download Status=Success**（Cloud proxy/Fleet/Identity broker/License/Migration/Salt/Salt RaaS/SDDC LCM/SDDC Manager/Software depot/Telemetry/VCF Automation/VCF Operations/VSP/NSX 0200/vCenter）|

> 註：catalog「最新 build」有時會挑到 depot 未放的版本（NSX 誤挑 4.2.4、HCX、NSX_ALB、VRSLCM 9.0.2）→ 那幾列 Failed 屬**版本挑選假象非缺陷**；把版本下拉改成 depot 內有的（如 NSX `9.1.0.0200`）再下即 Success。
