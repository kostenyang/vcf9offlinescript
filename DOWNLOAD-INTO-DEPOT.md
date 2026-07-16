# VCF 9.1 — 用官方 VCF Download Tool 把 binary 直接下載進 depot（完整流程）

不搬大 tar、也不靠瀏覽器一個個抓。用 Broadcom 官方 **VCF Download Tool** 憑 activation code
從 Broadcom depot 直接把要的元件 binary **下載成一個標準 offline depot**（頂層 `PROD/`，含
`COMP/<元件>/` + `metadata/`(catalog+Compatibility+vSAN HCL)），可直接給 VCF Installer sync。

> 對照：`CUSTOMER-DEPLOY-GUIDE.md`(完整 tar 交付)、`OA-FLAT-SORT-DEPOT.md`(OA 平面下載→sort 歸位)、
> `METADATA-ZIP-DEPOT.md`(metadata zip + 自己下 binary)。本文是「**官方 download tool 一步下成 depot**」。

---

## 0. 準備物

| 物件 | 說明 |
|------|------|
| `vcf-download-tool-9.1.0.<NNNN>.<build>.tar.gz` | 官方 VCF Download Tool（自帶 JRE，綠色可攜、免 admin）|
| Broadcom 帳號 + VCF 授權 | 產 activation code 用（https://vcf.broadcom.com）|
| 一台有網路的機器 | Windows 或 Linux 皆可；要連得到 Broadcom depot（或走 proxy）|

**免安裝**：解壓即用，自帶 `jre/`（Windows `jre\win32`、Linux `jre/lin64`），不用另裝 Java、不寫登錄檔/系統路徑。
```bash
tar -xzf vcf-download-tool-9.1.0.<NNNN>.<build>.tar.gz -C <解壓夾>
# Windows: <解壓夾>\bin\vcf-download-tool.bat
# Linux:   <解壓夾>/bin/vcf-download-tool
```

---

## 1. 產 Software depot ID → 換 activation code

工具的下載動作**都要 activation code**（`releases list`/`binaries download` 皆然），而 code 要先有
**Software depot ID** 才能在 portal 產。順序是：工具產 ID → portal 綁 ID 產 code。

```bash
# 產(或讀出已存在的) Software depot ID
vcf-download-tool configuration get --software-depot-id
#  -> Software depot ID: 0e9f3d64-5a6f-4ac9-9eb8-e1e728f1575d
#     並給一個註冊連結 https://vcf.broadcom.net/vcf/clm/download-manager/register?serviceId=<ID>
```
- 開該連結，或登入 https://vcf.broadcom.com → **Software depot Registration** → 貼上這個 ID → 產出 **activation code**。
- 把 code 存成**單行文字檔**，例如 `actcode.txt`（一行、無結尾換行）。
- ⚠️ code 綁這個 ID → **之後要用「同一份」工具實例**下載；別再 `configuration generate --software-depot-id` 重產（會讓 code 失效）。

驗證 code 有效（列出可下的 VCF releases）：
```bash
vcf-download-tool releases list --depot-download-activation-code-file=actcode.txt
#  Validating depot credentials. -> Depot credentials are valid.  即成功
#  (踩雷:releases list --vcf-version=X 單版本 detail 會撞工具 bug NoSuchElement;不帶版本列全部即可)
```

---

## 2. 看要下哪些（binaries list）

`--vcf-version` 用 **release 版**(`9.1.0.0`)，不要用 patch 版(`9.1.0.0400`)——後者 automated-install 會回 0。
工具會回傳整條 9.1.0.x 線每元件的所有版本(0/0100/0200/0300/0400)。

```bash
vcf-download-tool binaries list \
  --vcf-version=9.1.0.0 --sku=VCF --automated-install --type=INSTALL \
  --depot-download-activation-code-file=actcode.txt
# 每列: ID | Component | Full Name | Version | Release Date | Size | Type
```
filter 參數：`--sku=VCF|VVF`、`--component=VCENTER|NSX_T_MANAGER|…`、`--type=INSTALL|UPGRADE`、
`--automated-install`(VCF Installer bringup 那套)、`--component-version=`、`--id=<bundleId>,…`。

---

## 3. 下載進 depot（binaries download）

**下「每元件最新版」**（避免把 0/0100/0200/0300/0400 全下，量翻好幾倍）—— 從 step2 清單挑各元件
最新那版的 **ID**，用 `--id` 釘住：

```bash
IDS=<id1>,<id2>,...   # 各元件最新版的 bundle ID(逗號分隔)
vcf-download-tool binaries download \
  --depot-store=<depot輸出夾> \
  --depot-download-activation-code-file=actcode.txt \
  --id=$IDS
```
或按版本/SKU 整批下（會含該 filter 命中的所有版本）：
```bash
vcf-download-tool binaries download \
  --depot-store=<depot輸出夾> \
  --depot-download-activation-code-file=actcode.txt \
  --vcf-version=9.1.0.0400 --sku=VCF --automated-install --type=INSTALL
```

下載過程工具會**自動一起下 metadata**（product version catalog、unified release manifest、vSAN HCL、
Compatibility data）→ 產出的 `<depot輸出夾>` 頂層就是標準 `PROD/`：
```
<depot輸出夾>/PROD/
├── COMP/<元件代號>/<OVA/ISO/tgz/tar> (+ config-schema/depot-manifest, VCENTER 有 vmw/<uuid>)
├── metadata/  (productVersionCatalog + .sig / manifest / Compatibility v1,v2 / vsan/hcl)
└── vsan/hcl/
```
每檔下載時工具會**對簽章 catalog 驗 sha256**；結尾印 `N SUCCESS / 0 FAILED`。
> 過網路慢時 `Average Speed` 會顯示；`--depot-store` 同夾重跑是**累加**(不重下已有的)。

備援參數：`--proxy-server=<FQDN:Port> --proxy-https --proxy-user=<u> --proxy-user-password-file=<f>`。

---

## 4. 把 depot 拿去 serve 給 VCF Installer

產出的 `PROD/` 已是完整可 sync 的 depot。二選一：

**A. 架 depot server**（多台 installer 共用）
```bash
sudo bash create_vcf9_depot_server_v5.sh --fqdn <FQDN> --ip <IP> --web-server nginx --skip-disk-setup
cp -r <depot輸出夾>/PROD  /opt/vcf-depot/vcf9/           # 頂層 PROD/
chown -R www-data:www-data /opt/vcf-depot/vcf9
find /opt/vcf-depot/vcf9 -type d -exec chmod 0500 {} + ; find /opt/vcf-depot/vcf9 -type f -exec chmod 0400 {} +
nginx -t && systemctl reload nginx
# installer: import_vcf9depot_ca.sh -> Depot Settings 指 https://<IP> / vcfdepot -> SYNCED -> Download
```

**B. 放 installer 本地**（單機，見 `UPLOAD-STEPS.md` 模式 B：nginx:8443 + 憑證進 JRE cacerts）。

---

## 實測（2026-07-15）

| 步驟 | 值/結果 |
|------|---------|
| Software depot ID | `0e9f3d64-5a6f-4ac9-9eb8-e1e728f1575d`（Windows 免 admin 產）|
| activation code | portal 綁 ID 產出 → **credentials valid** |
| binaries download | `--id=<16 元件最新版>` → **16/16 SUCCESS**，66GB，含完整 metadata |
| depot 輸出 | `PROD/COMP/<16>` + `metadata/`(catalog=0400) + `vsan/` |
| installer 驗證 | 全新 installer 接該 depot → SYNCED → 各元件 Download **Success** |

## 踩雷

| 症狀 | 解法 |
|------|------|
| `Missing required argument: --depot-download-activation-code-file` | 每個下載動作都要帶 code 檔 |
| `releases list --vcf-version=X` 撞 `NoSuchElementException` | 工具單版本 detail bug;不帶版本列全部即可 |
| `binaries list --vcf-version=9.1.0.0400 --automated-install` 回 0 elements | 用 **release 版 `9.1.0.0`**(0400 是它底下 patch) |
| 下拉「最新」挑到 `9.0.2`/`4.2.4` 等別線版本 | 別只看 build number;用 `--id` 釘各元件正確版 |
| `configuration generate --software-depot-id` 後 code 失效 | ID 一改,舊 code 作廢;要重新 portal 產 code |
| root SSH / admin | **不需要**;工具綠色可攜,一般使用者即可跑 |
