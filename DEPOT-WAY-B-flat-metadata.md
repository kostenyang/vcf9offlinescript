# 路 B — 手動 flat 下載 + metadata zip → sort → 傳 depot server

> 上 depot server 三條路之一 · 另見 [路 A download-tool → tar](DEPOT-WAY-A-download-tool.md) · [路 C 0400 釘版](DEPOT-WAY-C-0400.md)

**適用**：沒下載工具/token，客戶只能從 Broadcom portal **手動點檔**下載。
流程：flat 檔全下到一個資料夾 → `sort-flat-depot.sh` 排版 + 鋪 metadata zip → 傳 depot server。

> 為什麼要 metadata zip：手動下載拿不到 `Compatibility` 互通矩陣,但 installer sync **一定要**
> `COMP/SDDC_MANAGER_VCF/Compatibility/VmwareCompatibilityData.json`,少了它 sync 卡
> `Vmware compatibility data download failed`。zip 補的就是這層（+ catalog / manifest / vsan hcl）。

前提：depot server 已建好（`create_vcf9_depot_server_v5.sh`，root `/opt/vcf-depot/vcf9`，服務 `PROD/`）。

---

## 1. 客戶手動下載 → 一個 flat 資料夾
從 portal 把 ova/iso/tgz/tar + 每元件的 config-schema/depot-manifest **全下到同一夾**（不分目錄）。

## 2. 準備 metadata zip（同源最重要）
```bash
sed -i 's/\r$//' make-metadata-zip.sh sort-flat-depot.sh
# 從「同一批 binaries 的 depot 或 depot.tar.gz」抽出 zip,保證 catalog 跟 flat 檔同源
bash make-metadata-zip.sh <那批 binaries 的 depot 或 depot.tar.gz> out-metadata.zip
```
> ⚠️ **catalog 必須跟 flat binaries 同源**。zip 的 `productVersionCatalog.json` 決定 installer
> sync 後「看到哪些版本」;若 zip 是別版抽的,installer 會列出對不到檔的版本 → sync 過但下載 Failed。
> 有官方對應版 metadata zip 也可直接用。

## 3. 排版 + 鋪 metadata（第 3 個參數帶 zip 是關鍵）
```bash
bash sort-flat-depot.sh <FLAT_DIR> <OUT_DEPOT> out-metadata.zip
#  -> OUT/PROD/COMP/<元件>/…              (binaries + schema + manifest,依檔名歸位)
#  -> OUT/PROD/metadata/…                 (zip 鋪的 catalog / manifest / vsan hcl)
#  -> OUT/PROD/COMP/SDDC_MANAGER_VCF/Compatibility/...   (zip 鋪的,sync 必要)
#  認不得的檔 -> OUT/_unsorted/,手動看
```
- 加 `-m`（放最前）= move 不 copy：`bash sort-flat-depot.sh -m <FLAT> <OUT> out-metadata.zip`
- 只處理 16 個 install-set 元件；額外檔留 `_unsorted/`
- 完整說明：[OA-FLAT-SORT-DEPOT.md](OA-FLAT-SORT-DEPOT.md)

## 4. 傳到 depot server
把 `OUT/PROD` 打包 tar（`cd OUT && tar -czf out.tar.gz PROD`）scp 上去,解到 depot 根；
或 rsync `OUT/PROD/` 到 `/opt/vcf-depot/vcf9/PROD/`。

## 5. 收權限 + reload + 驗證（v5 共通收尾）
```bash
WEB_USER=www-data        # RHEL/Rocky = nginx
sudo chown -R "$WEB_USER:$WEB_USER" /opt/vcf-depot/vcf9
sudo find /opt/vcf-depot/vcf9 -type d -exec chmod 0500 {} +
sudo find /opt/vcf-depot/vcf9 -type f -exec chmod 0400 {} +
sudo nginx -t && sudo systemctl reload nginx
curl -sk -u '<DEPOT_USER>:<DEPOT_PASS>' https://<DEPOT_FQDN>:443/PROD/metadata/productVersionCatalog/v1/productVersionCatalog.json -o /dev/null -w 'catalog %{http_code}\n'
curl -sk -u '<DEPOT_USER>:<DEPOT_PASS>' https://<DEPOT_FQDN>:443/PROD/COMP/SDDC_MANAGER_VCF/Compatibility/VmwareCompatibilityData.json -o /dev/null -w 'compat  %{http_code}\n'   # 都要 200
```

## 6. VCF Installer 接 depot
匯憑證 → 設 depot URL + basic-auth → sync（SYNCED）→ Bundle Management 勾元件下載。
見 [METADATA-ZIP-DEPOT.md](METADATA-ZIP-DEPOT.md) 第二段 / [INSTALLER_CONNECT_TROUBLESHOOTING.md](INSTALLER_CONNECT_TROUBLESHOOTING.md)。

> 進階變體：有 token 時可省手動下載,改用 token 直接下 binary（metadata 仍用 zip 鋪）→ [METADATA-ZIP-DEPOT.md](METADATA-ZIP-DEPOT.md)。
> rtolab 現成 depot server `172.16.10.50`（web root `/depot`、HTTP:8888）路徑/埠與 v5 不同,套用時改。
