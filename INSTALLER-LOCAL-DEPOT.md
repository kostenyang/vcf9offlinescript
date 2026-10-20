# VCF Installer 自己當 depot（metadata zip / download tool 本機下載）

現場**只有 VCF Installer、沒有 depot server** 時，把 metadata zip 放到 installer 本機，
讓 installer 從 `http://127.0.0.1:8080` 同步自己、下載自己。

> 實測環境：VCF Installer 9.1.1。sync **SYNCED**、bundle 下載 **SUCCESSFUL**、還原 OK。

---

## 為什麼不能直接把 zip 解進 installer

| 試過的做法 | 結果 |
|---|---|
| zip 解進 `/nfs/vmware/vcf/nfs-mount/{metadata,compatibility,vsan-hcl}/` + 重啟 lcm | ❌ 檔案換了，但 API 上的 bundle 清單**完全沒變** —— installer 認的是 postgres DB，只有 sync 會寫 DB |
| installer depot URL 指 `http://127.0.0.1:8080` + 帳密 | ❌ 400 `VMWARE_DEPOT_AUTH_HTTP_OFFLINE_DEPOT_IS_UNSUPPORTED` |
| installer depot URL 指 `http://127.0.0.1:8080`、**不帶帳密** | ✅ 連線成功 → SYNCED → 下載成功，免憑證、免匯 CA |

---

## 兩種情境

| | 情境 A：只有 metadata zip | 情境 B：download tool 就裝在 installer 上 |
|---|---|---|
| depot 內容來源 | 外面產好的 zip 帶進來 | download tool 直接下載到 installer 本機 |
| 需要 zip 嗎 | 要 | **不用**（`binaries download` 會一起下 metadata，含 Compatibility） |
| script 用法 | `--zip <zip>` | `--dir <download tool 的 -d 目錄>` |

### 情境 B 指令（例：PROD 在 `/nfs/vmware/vcf/nfs-mount/vcf911/`）

```bash
# root(su -):下載。-d 指到 PROD 的上一層,工具會自己建 PROD/
DT=/opt/vmware/vcf/lcm/vcf-download/bin/vcf-download-tool
D=/nfs/vmware/vcf/nfs-mount/vcf911
$DT binaries download -d=$D --depot-download-token-file=/root/token.txt     --vcf-version=9.1.1.0 --sku=VCF --automated-install --type=INSTALL --ceip=DISABLE
chmod -R a+rX $D          # 下載出來是 root 的,讓 vcf 讀得到
```

```bash
# vcf:讓 installer 以自己為 depot
bash installer-local-depot.sh --dir /nfs/vmware/vcf/nfs-mount/vcf911
```

- 目錄是 root 的沒關係，script 只要求**讀得到**；有讀不到的檔會列出來並停下，照提示用 root `chmod -R a+rX` 一次即可。
- 之後用 download tool 補下載（同一個 `-d`，累加不覆蓋），installer 那邊重新 sync 就看得到：
  `bash installer-local-depot.sh --dir /nfs/vmware/vcf/nfs-mount/vcf911`
- **不要**再對這個目錄 `--zip`：download tool 下的 metadata 比 zip 新，script 會拒絕蓋（硬要蓋加 `--force`）。
- 空間：`df -h /nfs/vmware/vcf/nfs-mount`，9.1.1 INSTALL 全套約 62G。

---

## 需要的檔案

| 檔案 | 用途 |
|---|---|
| `vcf-9.1.1.0-offline-depot-metadata-full.zip` | metadata（catalog / Compatibility / vSAN HCL / vCenter upgrade_info + manifest），17 檔、7.3 MB |
| `installer-local-depot.sh` | 在 installer 上鋪 depot、起 server、改 depot URL、sync、還原 |
| （要下載元件時）各元件的 binary | zip **只有 metadata**，要裝的元件 binary 另外放（見步驟 4） |

zip 用 `make-metadata-zip.sh` 從完整 depot 產：

```bash
bash make-metadata-zip.sh /depot/vcf911 /root/vcf-9.1.1.0-offline-depot-metadata-full.zip
```

---

## 步驟

### 1. 檔案傳到 installer

```bash
scp vcf-9.1.1.0-offline-depot-metadata-full.zip installer-local-depot.sh vcf@<INSTALLER_IP>:/tmp/
```

installer 只開 `vcf` 帳號 SSH，root 不能直接登；這支 script **用 `vcf` 就能跑**。

### 2. 在 installer 上跑

```bash
ssh vcf@<INSTALLER_IP>
cd /tmp && sed -i 's/\r$//' installer-local-depot.sh
bash installer-local-depot.sh --zip /tmp/vcf-9.1.1.0-offline-depot-metadata-full.zip
```

會問 `admin@local` 密碼（或先 `export INSTALLER_PASSWORD=...`）。script 做的事：

1. zip 解到 `/nfs/vmware/vcf/nfs-mount/local-depot/`（這個分割區通常有幾百 G）
2. 檢查 `PROD/metadata/productVersionCatalog` 和 Compatibility 都在
3. 起 `python3 -m http.server 8080 --bind 127.0.0.1`
4. 原本的 depot 設定存到 `local-depot/.prev-depot-settings.json`
5. `PUT /v1/system/settings/depot` → `http://127.0.0.1:8080`（不帶帳密）
6. `PATCH .../depot-sync-info` → 等到 `SYNCED`

### 3. 確認

```bash
grep -E '"(GET|HEAD) ' /tmp/vcf-local-depot.log | awk '{print $7,$9}' | sort | uniq -c
```

會看到 installer 抓了 catalog / Compatibility / vcfManifest / upgrade_info，全部 200。

### 4. 下載元件（zip 沒有 binary，要補）

UI 勾元件下載，或 API：

```bash
curl -sk -X PATCH https://127.0.0.1/v1/bundles/<bundleId> -H "Authorization: Bearer <token>" \
  -H 'Content-Type: application/json' -d '{"bundleDownloadSpec":{"downloadNow":true}}'
```

第一次會失敗，因為 binary 還不在本機 depot。看它要哪個檔：

```bash
grep ' 404 ' /tmp/vcf-local-depot.log
```

例：
```
"HEAD /PROD/COMP/TELEMETRY_ACCEPTOR/telemetry-acceptor-9.1.1.0.25671600.tgz HTTP/1.1" 404
```

把該元件目錄下**同版本的全部檔案**（`.tgz` + `depot-manifest-*.yaml` + `configuration-schema-*.yaml` + `*-plugin-*.tgz`）
放到 `local-depot/PROD/COMP/<元件>/`，路徑照 404 那行：

```bash
mkdir -p /nfs/vmware/vcf/nfs-mount/local-depot/PROD/COMP/TELEMETRY_ACCEPTOR
cp /path/to/TELEMETRY_ACCEPTOR/*9.1.1.0.25671600* /nfs/vmware/vcf/nfs-mount/local-depot/PROD/COMP/TELEMETRY_ACCEPTOR/
chmod -R a+rX /nfs/vmware/vcf/nfs-mount/local-depot
```

installer 會自己重試，抓到就變 `SUCCESSFUL`，不用重送。

> **要裝的元件很多** → 不要一個個補，直接用完整 depot tar：
> `bash installer-local-depot.sh --tar vcf911-depot.tar.gz`（script 會先檢查空間）。

### 5. 收尾

改回原本的 depot：

```bash
bash installer-local-depot.sh --stop --restore-url https://<原depot IP> --restore-user <帳號>
```

只停 server、不改設定：

```bash
bash installer-local-depot.sh --stop
```

已下載的 bundle 會留在 installer 上，不受影響。

---

## 注意

- **重開機 server 會消失**（nohup 背景程序）。重開後：
  `bash installer-local-depot.sh --dir /nfs/vmware/vcf/nfs-mount/local-depot`
- **catalog 比 installer 現有的舊時**（`sequenceNumber` 較小），sync 會成功但 installer 保留新的那份。全新 installer 沒這問題。
- **`admin@local` 打錯幾次會鎖**，不會自動解，要重啟 commonsvcs。
- server 只綁 `127.0.0.1`，外部連不到。
