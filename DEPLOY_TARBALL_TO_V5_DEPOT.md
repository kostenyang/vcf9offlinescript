# 把 depot tar.gz 灌進 v5 depot server（簡單版）

已建好的 `create_vcf9_depot_server_v5.sh` server 服務 `/opt/vcf-depot/vcf9/PROD/`，
交付的 tar 頂層就是 `PROD/`，所以**直接解到 depot 根目錄**，每個元件自動還原到各路徑，
不用手動搬檔。

> 前提：depot server 已存在（`create_vcf9_depot_server_v5.sh` 建，且 **不帶** `--download-binaries`——binary 都在 tar 裡了）。

## 交付的 tar（E: 上，擇一）

| tar | 大小 | sha256 | 內容 |
|-----|------|--------|------|
| `E:\vcf9-depot-complete.tar.gz` | ~180 GiB (`193831632275`) | `007eee1e…fb714` | 完整 install 集 + 最新 |
| `E:\vcf9-depot-0400.tar.gz` | ~62 GiB (`66133891214`) | `9d6d6fb4…99a65b` | 16 元件最新（含 0400） |

> 下面用 `<TARBALL>` 代表你選的那顆。tar 幾乎壓不下去是正常的——裡面是已壓縮的 ova/iso/tgz。
> depot server 磁碟要能放 **tar + 解出來的樹**（約 2×）。

## 1. 傳 tar 到 depot server
```bash
scp <TARBALL> root@<DEPOT_IP>:/root/
```

## 2. 傳完先驗 sha256（別解壞檔）
```bash
sha256sum /root/<tar 檔名>     # 對上表的 sha256
```

## 3. 解到 depot 根目錄（一行還原所有路徑）
```bash
sudo mkdir -p /opt/vcf-depot/vcf9
sudo tar -xzf /root/<tar 檔名> -C /opt/vcf-depot/vcf9/
# -> /opt/vcf-depot/vcf9/PROD/COMP/...  +  /opt/vcf-depot/vcf9/PROD/metadata/...
```

## 4. 重收權限（必要——v5 鎖成 web user 才讀得到）
```bash
WEB_USER=www-data        # Ubuntu/Debian = www-data ; RHEL/Rocky = nginx
sudo chown -R "$WEB_USER:$WEB_USER" /opt/vcf-depot/vcf9
sudo find /opt/vcf-depot/vcf9 -type d -exec chmod 0500 {} +
sudo find /opt/vcf-depot/vcf9 -type f -exec chmod 0400 {} +
# RHEL + SELinux: sudo restorecon -Rv /opt/vcf-depot/vcf9
```

## 5. reload + 驗證服務
```bash
sudo nginx -t && sudo systemctl reload nginx        # Apache: apachectl configtest && systemctl reload apache2
curl -sk -u '<DEPOT_USER>:<DEPOT_PASS>' \
  https://<DEPOT_FQDN>:443/PROD/metadata/productVersionCatalog/v1/productVersionCatalog.json \
  -o /dev/null -w 'HTTP %{http_code}\n'             # 要 HTTP 200
```

完成——depot 已就緒。VCF Installer 指到 `https://<DEPOT_FQDN>:443`（先匯 depot 憑證，再設 depot URL + basic-auth 帳密）。

---
> 對照：flat 檔手排 → [OA-FLAT-SORT-DEPOT.md](OA-FLAT-SORT-DEPOT.md)；自製 metadata zip → [METADATA-ZIP-DEPOT.md](METADATA-ZIP-DEPOT.md)；用 download-tool 直接下進 depot → [DOWNLOAD-INTO-DEPOT.md](DOWNLOAD-INTO-DEPOT.md)。
