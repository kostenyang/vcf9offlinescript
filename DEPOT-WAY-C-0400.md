# 路 C — 0400 這批：自製 metadata zip + 平面歸位 → 傳 depot server（0400 釘版）

> 上 depot server 三條路之一 · 另見 [路 A download-tool → tar](DEPOT-WAY-A-download-tool.md) · [路 B 手動 flat + metadata zip](DEPOT-WAY-B-flat-metadata.md)

[路 B](DEPOT-WAY-B-flat-metadata.md) 的流程，**釘死在 9.1.0.0400 這批實際檔案**上的一頁式 runbook。

> 適用情境：客戶自己從 Broadcom portal **手動下載**一堆 flat 檔（不是搬整包 tar），
> 用**自製 metadata zip** 補上 installer sync 要的 `metadata/`（含 Compatibility），
> 再 `sort-flat-depot.sh` 自動歸位成可用 depot。

---

## 交付物（0400 實際檔）

| 物件 | 路徑 | 備註 |
|------|------|------|
| 自製 metadata zip | `E:\vcf-9.1.0.0400-offline-depot-metadata.zip` | 13 檔 / 6,878,320 B / sha256 `6f983963…554c4` |
| flat binaries（48 檔） | `E:\vcf-0400-flat\` | ova/iso/tgz/tar + 每元件 config-schema/depot-manifest |
| 歸位腳本 | `sort-flat-depot.sh` | flat → `PROD/COMP/<CODE>/` + 鋪 metadata |
| 產 zip 腳本 | `make-metadata-zip.sh` | 從 depot/tar 抽出這顆 zip（同源保證版本一致） |

**這批的 16 元件版本**（sort 完 / installer sync 後要對得上這些）：

| 元件 | 版本 | | 元件 | 版本 |
|------|------|---|------|------|
| VCENTER | 9.1.0.0200.25573614 | | VCF_SDDC_LCM | 9.1.0.0400.25570103 |
| NSX_T_MANAGER | 9.1.0.0200.25524172 | | VCF_FLEET_LCM | 9.1.0.0400.25570104 |
| SDDC_MANAGER_VCF | 9.1.0.0400.25570100 | | DEPOT_SERVICE | 9.1.0.0400.25570105 |
| VROPS | 9.1.0.0400.25541561 | | VCF_SALT | 9.1.0.0400.25544946 |
| VCF_OPS_CLOUD_PROXY | 9.1.0.0400.25541562 | | VCF_SALT_RAAS | 9.1.0.0400.25544946 |
| VCF_LICENSE_SERVER | 9.1.0.0400.25541557 | | VCF_SERVICE_VCD_MIGRATION_BACKEND | 9.1.0.0200.25556825 |
| VSP | 9.1.0.0200.25555874 | | VRA | 9.1.0.0200.25556825 |
| VIDB | 9.1.0.0100.25522734 | | TELEMETRY_ACCEPTOR | 9.1.0.0.25181946 |

> ⚠️ 0400 是**維護等級不是可篩版本**：9 個元件有 0400，其餘 7 個最新落在 0200/0100/base。
> 完整檔案清單見 [DEPOT-0400-FILELIST.md](DEPOT-0400-FILELIST.md)。

---

## Step 0 —（可選）自己產 metadata zip

已有 `E:\vcf-9.1.0.0400-offline-depot-metadata.zip` 就跳過。要從別的 0400 depot/tar 重產：
```bash
sed -i 's/\r$//' make-metadata-zip.sh
bash make-metadata-zip.sh <這批 binaries 的 depot 或 depot.tar.gz> E:\vcf-9.1.0.0400-offline-depot-metadata.zip
```
> **同源才安全**：zip 的 `productVersionCatalog.json` 要跟 flat binaries 是同一批,否則 installer 會列出對不到檔的版本 → sync 過但下載 Failed。

## Step 1 — 平面歸位 + 鋪 metadata（一條搞定）

第 3 個參數帶 zip，`sort-flat-depot.sh` 會把 binaries 歸位 **並** 鋪好 metadata：
```bash
sed -i 's/\r$//' sort-flat-depot.sh
bash sort-flat-depot.sh /e/vcf-0400-flat /e/depot-0400-serve E:\vcf-9.1.0.0400-offline-depot-metadata.zip
```
產出：
```
/e/depot-0400-serve/PROD/
├── COMP/<16 元件>/…                                  # binaries + schema + manifest
│   └── SDDC_MANAGER_VCF/Compatibility/VmwareCompatibilityData.json   # ← zip 鋪的,sync 必要
├── metadata/…                                        # ← zip 鋪的 catalog / manifest / vsan hcl
└── (認不得的檔 → /e/depot-0400-serve/_unsorted/,手動看)
```
- 加 `-m`（放最前）改 move（省空間但搬走原檔）：`bash sort-flat-depot.sh -m /e/vcf-0400-flat …`

## Step 2 — 起 HTTPS 服務指向 `PROD`

把 `…/PROD` 當 web root，用 nginx 起 **HTTPS + basic-auth**（installer 只吃 HTTPS）。
depot server 建法/憑證見 [METADATA-ZIP-DEPOT.md](METADATA-ZIP-DEPOT.md) 第一段，或 [DEPOT_SERVERS.md](DEPOT_SERVERS.md) 現有機器。

自我驗證（都要 200）：
```bash
curl -sk -u 'vcfdepot:VMware1!VMware1!' https://<DEPOT_IP>/PROD/metadata/productVersionCatalog/v1/productVersionCatalog.json -o /dev/null -w 'catalog %{http_code}\n'
curl -sk -u 'vcfdepot:VMware1!VMware1!' https://<DEPOT_IP>/PROD/COMP/SDDC_MANAGER_VCF/Compatibility/VmwareCompatibilityData.json -o /dev/null -w 'compat  %{http_code}\n'
```

## Step 3 — installer 接 depot → sync → 下載

```bash
# 憑證匯進 installer(vcf 登入 → su -)
sudo bash import_vcf9depot_ca.sh --url-insecure https://<DEPOT_IP>:443
systemctl restart lcm.service
```
```powershell
$inst='https://<INSTALLER_IP>'; $depotIp='<DEPOT_IP>'
$tok=Invoke-RestMethod "$inst/v1/tokens" -Method Post -SkipCertificateCheck -ContentType application/json -Body (@{username='admin@local';password='<PW>'}|ConvertTo-Json)
$h=@{Authorization="Bearer $($tok.accessToken)"}
$body=@{depotConfiguration=@{isOfflineDepot=$true;url="https://$depotIp"};offlineAccount=@{username='vcfdepot';password='VMware1!VMware1!'}}|ConvertTo-Json
Invoke-RestMethod "$inst/v1/system/settings/depot" -Method Put -Headers $h -ContentType application/json -Body $body -SkipCertificateCheck
Invoke-RestMethod "$inst/v1/system/settings/depot/depot-sync-info" -Method Patch -Headers $h -SkipCertificateCheck
do{Start-Sleep 10;$s=(Invoke-RestMethod "$inst/v1/system/settings/depot/depot-sync-info" -Headers $h -SkipCertificateCheck).syncStatus;$s}while($s-ne'SYNCED')
# UI: Bundle Management → 勾元件(版本要對上上表) → DOWNLOAD → 等 Downloaded
```

---

## 踩雷（0400 特別注意）

| 症狀 | 解法 |
|------|------|
| sync 卡 `Vmware compatibility data download failed` | metadata 一定要用**含 Compatibility 的 zip** 鋪(Step 1 帶 zip);token 抓不到這檔 |
| sync 過但某版本 Download 失敗 | 該版 binary 不在 depot,或 zip catalog 與 flat 檔**不同源**。用同源 zip(Step 0),或補下缺的 binary |
| UI 找不到 0400 版本 | 記得 7 個元件最新不是 0400(見上表);別硬找 VCENTER/NSX/VRA/VSP/VIDB/VCD_MIGRATION/TELEMETRY 的 0400 |
| 憑證 `certificate_unknown` | `import_vcf9depot_ca.sh` 匯 cert 進 JRE cacerts + 重啟 `lcm.service` |
| 帳密對卻被拒 / URL 被拒 | 帳密放頂層 `offlineAccount`;URL 用 **IP** 不用 FQDN |
| `_unsorted/` 有檔 | 檔名不在 16 元件 pattern;非 install-set 的額外檔,手動決定要不要留 |

> 相關：整包 tar 交付走 [CUSTOMER-DEPLOY-GUIDE.md](CUSTOMER-DEPLOY-GUIDE.md);用 download-tool 直接下進 depot 走 [DOWNLOAD-INTO-DEPOT.md](DOWNLOAD-INTO-DEPOT.md)。
