# VCF Download Tool — 使用手冊（指令 + 雷）

官方 **VCF Download Tool** 用 activation code 從 Broadcom depot 下載 VCF 元件 binary + metadata。
本文只講**工具本身**（安裝、認證、指令、旗標、踩雷）；「下成一個 depot 的完整流程」見
[DOWNLOAD-INTO-DEPOT.md](DOWNLOAD-INTO-DEPOT.md)。

> 指令語法已對照工具 `--help` 逐條核實（tool build `9.1.0.0400.25570101`）。

---

## 1. 安裝（綠色可攜、免 admin）

解壓即用，**自帶 JRE**（Windows `jre\win32`、Linux `jre/lin64`），不用另裝 Java、不寫登錄檔/系統路徑。
```bash
tar -xzf vcf-download-tool-9.1.0.<NNNN>.<build>.tar.gz -C vdt
# 執行檔:
#   Windows: vdt\bin\vcf-download-tool.bat
#   Linux:   vdt/bin/vcf-download-tool
```
下面用 `vcf-download-tool` 代表該執行檔。

**頂層 commands**：`binaries` / `configuration` / `metadata` / `releases` / `esx` / `depot`
（`-h/--help` 每層都有；`-v/--version` 印版本）

---

## 2. 認證：Software depot ID → activation code

工具的**每個下載動作都要 activation code**（連 `releases list` 也要）。code 要先有 **Software depot ID** 才能在 portal 產。

```bash
# 讀出(或首次產生) Software depot ID
vcf-download-tool configuration get --software-depot-id
#   -> Software depot ID: <UUID>
#      + 註冊連結 https://vcf.broadcom.net/vcf/clm/download-manager/register?serviceId=<UUID>
```
- 開該連結，或登入 `https://vcf.broadcom.com` → **Software depot Registration** → 貼 ID → 產 **activation code**。
- 存成**單行文字檔**（例 `actcode.txt`，無結尾換行）。
- ⚠️ **code 綁這個 ID**：之後要用**同一份工具實例**下載；**別再 `configuration generate --software-depot-id` 重產**（ID 一改，舊 code 立即失效）。

驗 code 有效：
```bash
vcf-download-tool releases list --depot-download-activation-code-file=actcode.txt
#   Validating depot credentials. -> Depot credentials are valid.  = 成功
```

---

## 3. 列出可下的東西

```bash
# 所有 VCF releases（不要帶 --vcf-version 單版本,見雷#2）
vcf-download-tool releases list --depot-download-activation-code-file=actcode.txt

# 某 release 有哪些元件 binary
vcf-download-tool binaries list \
  --vcf-version=9.1.0.0 --sku=VCF --automated-install --type=INSTALL \
  --depot-download-activation-code-file=actcode.txt
#   輸出每列: ID | Component | Full Name | Version | Release Date | Size | Type
```

---

## 4. 下載

```bash
# A) 按 filter 整批下（該 filter 命中的所有版本都下）
vcf-download-tool binaries download \
  --depot-store=<輸出dir> \
  --depot-download-activation-code-file=actcode.txt \
  --vcf-version=9.1.0.0 --sku=VCF --automated-install --type=INSTALL

# B) 按 bundle ID 精準下（只下你要的版本 → 建議,量可控）
vcf-download-tool binaries download \
  --depot-store=<輸出dir> \
  --depot-download-activation-code-file=actcode.txt \
  --id=<id1>,<id2>,...
```
- **metadata 一起下**：下載過程會自動抓 product version catalog、unified release manifest、vSAN HCL、
  Compatibility data → 產出 `<輸出dir>/PROD/`（`COMP/<元件>` + `metadata/` + `vsan/`）。

### 只下「特定版本」（不是整條線最新）
```bash
# 方式1：--id（最精準,一個 ID = 一個確切版本;binaries list 先查 ID）
vcf-download-tool binaries download --depot-store=<dir> \
  --depot-download-activation-code-file=actcode.txt --id=<bundleId>
#  -> 輸出 "1 element" + 精準對到該版(實測 --id 只選那一版,不會下同元件其他版)

# 方式2：--component + --component-version（要搭 --vcf-version=9.1.0.0,同群組必填)
vcf-download-tool binaries download --depot-store=<dir> \
  --depot-download-activation-code-file=actcode.txt \
  --vcf-version=9.1.0.0 --sku=VCF --type=INSTALL \
  --component=VCF_LICENSE_SERVER --component-version=9.1.0.0200
```
> ⚠️ `--component/--component-version` 屬 [VCF VERSION] 群組 → **一定要帶 `--vcf-version`**（否則印 usage、exit 2）。單獨用 `--component-version` 不行。
- 每檔對**簽章 catalog 驗 sha256**；結尾印 `N SUCCESS / 0 FAILED`。
- 同 `--depot-store` 重跑是**累加**（跳過已下的）。
- 首次跑會問 **CEIP**：`--ceip=DISABLE`（或 `echo N|` 餵入）。

---

## 5. 旗標速查

| 群組 | 旗標 | 說明 |
|------|------|------|
| 必填 | `-d, --depot-store=<dir>` | 下載輸出目錄（`*`必填）|
| 必填(認證) | `--depot-download-activation-code-file=<file>` | activation code 檔（`*`必填）|
| 認證(舊) | `--depot-download-token-file=<file>` | download token（被 activation code 取代，5.x EOL 前還在）|
| **filter（三選一互斥）** | **[VCF VERSION]** | `--vcf-version=<a[..b]>`、`--sku=<VCF\|VVF>`、`-t/--type=<INSTALL\|UPGRADE>`、`--automated-install`、`--component=<…>`、`--component-version=<…>`、`--lifecycle-managed-by=<…>`、`--patches-only`、`--upgrades-only` |
| | **[BUNDLE ID]** | `--id=<bundleId>[,<bundleId>...]` |
| | **[DOWNLOAD SPEC]** | `--download-spec-file=<file>` |
| 其他 | `--ceip=<ENABLE\|DISABLE>` | 首次不帶會互動詢問，選擇會記住 |
| Proxy | `--proxy-server=<FQDN:Port>`、`--proxy-https`、`--proxy-user=<u>`、`--proxy-user-password-file=<f>` | 走 proxy 上網 |

> `--component` 可選值：VCENTER, SDDC_MANAGER_VCF, NSX_T_MANAGER, ESX_HOST, VRSLCM, VRA, VROPS,
> VRLI, VRNI, VSAN_*_WITNESS, VMTOOLS, VCFDT, VCF_OPS_CLOUD_PROXY, VIDB, HCX, VMRC, VRO, VSP,
> DEPOT_SERVICE, VCF_LICENSE_SERVER, TELEMETRY_ACCEPTOR, VCF_FLEET_LCM, VCF_SDDC_LCM,
> VCF_CONSUMPTION_CLI(_PLUGINS), VCFMS_METRICS_STORE, VCF_SERVICE_VCD_MIGRATION_BACKEND,
> VCF_SALT, VCF_SALT_RAAS, VCF_OBSERVABILITY_DATA_PLATFORM。

---

## 6. 踩雷

| # | 症狀 | 解法 |
|---|------|------|
| 1 | `Missing required argument: --depot-download-activation-code-file` | **每個**下載/列出動作都要帶 code 檔 |
| 2 | `releases list --vcf-version=X` 撞 `NoSuchElementException` | 工具**單版本 detail** 的 bug；**不帶版本**列全部即可 |
| 3 | `binaries list/download --vcf-version=9.1.0.0400 --automated-install` 回 **0 elements** | `--vcf-version` 要用 **release 版 `9.1.0.0`**（`0400` 是它底下的 patch，非 release）|
| 4 | 「最新」誤挑到 `9.0.2` / NSX `4.2.4` 等別線版本 | 別只看尾碼 build number（跨產品線會誤判）；用 **`--id`** 釘各元件正確版 |
| 5 | `--id` 跟 `--vcf-version` 一起下 | filter **三選一互斥**，不能混用；擇一 |
| 6 | `configuration generate --software-depot-id` 後 code 失效 | ID 一改舊 code 作廢 → 重新 portal 產 code |
| 7 | 要 root / admin | **不需要**；工具綠色可攜，一般使用者即可跑 |
| 8 | `configuration get` 過期報 `Can't access Broadcom depot with provided activation code` | code **有時效**；用**同一個 software depot ID** 到 portal 重新產一顆新 code（ID 不用動）|
| 9 | list/metadata 可讀，但 binary 下載 **HTTP 403 Forbidden**（`dl.broadcom.com` `/COMP/…`）| 該 code 的**帳號沒有 binary 下載 entitlement**（不同 site/tenant 權限不同）→ 換一顆有下載權限的 code。**注意：這與指令無關**，`--id` 仍會正確命中該版（印 `1 element`）|

---

## 7. 實測（2026-07-15）

| 項 | 結果 |
|----|------|
| Windows 免 admin（自帶 jre\win32）跑 `--version/--help/releases list` | ✅ |
| `configuration get --software-depot-id` → portal 換 code → `Depot credentials are valid` | ✅ |
| `binaries download --id=<16 元件最新版>` | **16/16 SUCCESS**，66GB，含完整 metadata |
| 產出 depot 給全新 installer sync + 下載 | **各元件 Download = Success** |
