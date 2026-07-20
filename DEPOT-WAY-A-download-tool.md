# 路 A — download-tool 下載（Windows）→ 打包 tar → 傳 depot server

> 上 depot server 三條路之一 · 另見 [路 B 手動 flat + metadata zip](DEPOT-WAY-B-flat-metadata.md) · [路 C 0400 釘版](DEPOT-WAY-C-0400.md)

**適用**：有下載 token / activation code，想用官方 `vcf-download-tool` 自動抓 binary。
流程：Windows 用工具下進資料夾 → 打包 tar → scp 到 depot server → 解到 depot 根。

前提：depot server 已建好（`create_vcf9_depot_server_v5.sh`，root `/opt/vcf-depot/vcf9`，服務 `PROD/`）。

---

## 1. Windows 用工具下 binary（自動建 `PROD/COMP/…`）

**整條 9.1.0.0 install 集：**
```
E:\vdt0400-test\bin\vcf-download-tool.bat binaries download --depot-store=E:\vcf9-depot --depot-download-activation-code-file=E:\vdt0400-test\actcode.txt --vcf-version=9.1.0.0 --sku=VCF --automated-install --type=INSTALL --ceip=DISABLE
```
- 只下**每元件最新** → `bash download-latest.sh <tool> <code> E:\vcf9-depot 9.1.0.0`（見 [DOWNLOAD-CMDS-ONELINE.md](DOWNLOAD-CMDS-ONELINE.md) 3e）
- 只下**特定版** → 換 `--id=<bundleId>[,<id2>…]`
- `--depot-store=` 就是下載路徑（可 Windows 或 Linux 路徑）
- 工具用法/雷完整版：[VCF-DOWNLOAD-TOOL.md](VCF-DOWNLOAD-TOOL.md)；下進 depot 完整流程：[DOWNLOAD-INTO-DEPOT.md](DOWNLOAD-INTO-DEPOT.md)

## 2. 打包成 tar（頂層必須是 `PROD/`）
```powershell
cd E:\vcf9-depot
tar -czf E:\vcf9-depot.tar.gz PROD
```

## 3. 傳到 depot server + 解到 depot 根（一行還原所有路徑）
```bash
scp E:\vcf9-depot.tar.gz root@<DEPOT_IP>:/root/
ssh root@<DEPOT_IP>
sha256sum /root/vcf9-depot.tar.gz            # 傳完先驗,別解壞檔
sudo mkdir -p /opt/vcf-depot/vcf9
sudo tar -xzf /root/vcf9-depot.tar.gz -C /opt/vcf-depot/vcf9/
#  -> /opt/vcf-depot/vcf9/PROD/COMP/...  +  /opt/vcf-depot/vcf9/PROD/metadata/...
```
> download-tool 下載時會**連 metadata 一起下**,所以 tar 內已含 `metadata/`,不必另外鋪 zip。

## 4. 收權限 + reload + 驗證（v5 共通收尾）
```bash
WEB_USER=www-data        # RHEL/Rocky = nginx
sudo chown -R "$WEB_USER:$WEB_USER" /opt/vcf-depot/vcf9
sudo find /opt/vcf-depot/vcf9 -type d -exec chmod 0500 {} +
sudo find /opt/vcf-depot/vcf9 -type f -exec chmod 0400 {} +
sudo nginx -t && sudo systemctl reload nginx
curl -sk -u '<DEPOT_USER>:<DEPOT_PASS>' https://<DEPOT_FQDN>:443/PROD/metadata/productVersionCatalog/v1/productVersionCatalog.json -o /dev/null -w 'catalog %{http_code}\n'
curl -sk -u '<DEPOT_USER>:<DEPOT_PASS>' https://<DEPOT_FQDN>:443/PROD/COMP/SDDC_MANAGER_VCF/Compatibility/VmwareCompatibilityData.json -o /dev/null -w 'compat  %{http_code}\n'   # 都要 200
```

## 5. VCF Installer 接 depot
匯 depot 憑證 → 設 depot URL + basic-auth → sync → 下載。
見 [METADATA-ZIP-DEPOT.md](METADATA-ZIP-DEPOT.md) 第二段 / [INSTALLER_CONNECT_TROUBLESHOOTING.md](INSTALLER_CONNECT_TROUBLESHOOTING.md)。

> rtolab 現成 depot server 是 `172.16.10.50`（web root `/depot`、HTTP:8888）—— 路徑/埠與 v5 不同,套用時改 `-C /depot` 且 URL 用 `http://172.16.10.50:8888`。
