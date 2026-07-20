# 把 VCF 9.1 binary 弄上 depot server — 三條路

三種把離線 binary 建成 depot 並上架到 depot server 的方法，**選一條**就好。
本文是速查總表；每條路的完整細節連到各自的 MD。

## 先選路

| 你的情況 | 走哪條 |
|---------|--------|
| 有下載 token / activation code，想用官方工具自動抓 | **路 A**（download-tool → tar → 傳） |
| 沒工具，客戶只能從 portal 手動點檔下載 | **路 B**（手動 flat + metadata zip → sort → 傳） |
| 就是要上 **9.1.0.0400 這批**（已備好 flat + 自製 zip） | **路 C**（0400 釘版，B 的特例） |

共同前提：depot server 已建好（`create_vcf9_depot_server_v5.sh`，root `/opt/vcf-depot/vcf9`，服務 `PROD/`）。rtolab 現成那台是 `172.16.10.50`（web root `/depot`、HTTP:8888）—— 路徑不同，套用時改一下。

---

## 路 A — VCF download-tool 下載（Windows）→ 打包 tar → 傳 depot server

**在 Windows 用工具把 binary 下進一個資料夾（它自動建 `PROD/COMP/…`）：**
```
E:\vdt0400-test\bin\vcf-download-tool.bat binaries download --depot-store=E:\vcf9-depot --depot-download-activation-code-file=E:\vdt0400-test\actcode.txt --vcf-version=9.1.0.0 --sku=VCF --automated-install --type=INSTALL --ceip=DISABLE
```
> 只下每元件最新 → 用 `download-latest.sh`（見 [DOWNLOAD-CMDS-ONELINE.md](DOWNLOAD-CMDS-ONELINE.md) 3e）；只下特定版 → 換 `--id=<bundleId>`。

**打包成 tar（頂層要是 `PROD/`）：**
```powershell
cd E:\vcf9-depot
tar -czf E:\vcf9-depot.tar.gz PROD
```

**傳到 depot server 並解到 depot 根（一行還原所有路徑）：**
```bash
scp E:\vcf9-depot.tar.gz root@<DEPOT_IP>:/root/
ssh root@<DEPOT_IP>
sudo tar -xzf /root/vcf9-depot.tar.gz -C /opt/vcf-depot/vcf9/
```
→ 之後收權限 + reload + 驗證，見 **[DEPLOY_TARBALL_TO_V5_DEPOT.md](DEPLOY_TARBALL_TO_V5_DEPOT.md)** step 4–5。

- 工具用法/雷：[VCF-DOWNLOAD-TOOL.md](VCF-DOWNLOAD-TOOL.md)、下進 depot 完整流程：[DOWNLOAD-INTO-DEPOT.md](DOWNLOAD-INTO-DEPOT.md)

---

## 路 B — 手動 flat 下載 + metadata zip → sort → 傳 depot server

客戶從 portal 把 ova/iso/tgz **全下到一個 flat 資料夾**（不分目錄）。工具抓不到
`Compatibility` 互通矩陣，所以要靠**官方/自製 metadata zip** 補 `metadata/` 層。

**排版 + 鋪 metadata（第 3 個參數帶 zip 是關鍵）：**
```bash
sed -i 's/\r$//' sort-flat-depot.sh
bash sort-flat-depot.sh <FLAT_DIR> <OUT_DEPOT> <metadata.zip>
#  -> OUT/PROD/COMP/<元件>/…  +  OUT/PROD/metadata/…  + SDDC_MANAGER_VCF/Compatibility + vsan/hcl
```

**傳到 depot server：** 把 `OUT/PROD` 打包 tar 或 rsync 上去，解/放到 depot 根的 `PROD`。

- 完整流程：**[OA-FLAT-SORT-DEPOT.md](OA-FLAT-SORT-DEPOT.md)**
- ⚠️ zip 的 catalog 必須跟 flat binaries **同源**，否則 installer 列出對不到檔的版本 → sync 過但下載 Failed。自己產同源 zip：`bash make-metadata-zip.sh <那批的 depot 或 tar> out.zip`
- 進階變體（有 token 時用 token 自動下 binary，不手動）：[METADATA-ZIP-DEPOT.md](METADATA-ZIP-DEPOT.md)

---

## 路 C — 0400 這批：自製 metadata.zip → 傳 depot server

路 B 釘死在 9.1.0.0400 的實際檔案上：

| 物件 | 路徑 |
|------|------|
| 自製 metadata zip | `E:\vcf-9.1.0.0400-offline-depot-metadata.zip`（sha `6f983963…554c4`） |
| flat binaries（48 檔） | `E:\vcf-0400-flat\` |

```bash
bash sort-flat-depot.sh /e/vcf-0400-flat /e/depot-0400-serve E:\vcf-9.1.0.0400-offline-depot-metadata.zip
# 再把 /e/depot-0400-serve/PROD 傳上 depot server
```
- 完整釘版手冊（含 16 元件版本表 + 0400 雷）：**[METADATA-ZIP-0400-RUNBOOK.md](METADATA-ZIP-0400-RUNBOOK.md)**
- 0400 檔案清單：[DEPOT-0400-FILELIST.md](DEPOT-0400-FILELIST.md)

---

## 上架後（三條路共通）

不管走哪條，binary 進 depot server 的 `PROD/` 後都要：
1. 收權限（v5 鎖 web user + `0500/0400`）→ `chown`/`chmod`（見 [DEPLOY_TARBALL_TO_V5_DEPOT.md](DEPLOY_TARBALL_TO_V5_DEPOT.md) step 4）
2. `nginx -t && systemctl reload nginx`
3. `curl` 驗 `PROD/metadata/productVersionCatalog/v1/productVersionCatalog.json` 與 `PROD/COMP/SDDC_MANAGER_VCF/Compatibility/VmwareCompatibilityData.json` 都 **200**
4. VCF Installer 匯 depot 憑證 → 設 depot URL + basic-auth → sync → 下載（見 [METADATA-ZIP-DEPOT.md](METADATA-ZIP-DEPOT.md) 第二段 / [INSTALLER_CONNECT_TROUBLESHOOTING.md](INSTALLER_CONNECT_TROUBLESHOOTING.md)）
