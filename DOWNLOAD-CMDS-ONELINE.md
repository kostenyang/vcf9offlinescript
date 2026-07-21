# VCF Download Tool — 可貼指令（每條一行）

把佔位符換成你的：`<tool>` = `…\bin\vcf-download-tool.bat`（Linux 去 `.bat`）、`<code>` = activation code 單行檔、`<depot>` = 下載輸出夾。

> 下方每條都附一行 **▸ 範例**（本機 rtolab 實際路徑）：
> `<tool>`=`E:\vdt0400-test\bin\vcf-download-tool.bat`、`<code>`=`E:\vdt0400-test\actcode.txt`、`<depot>`=`E:\vcf9-depot`
>
> ✅ **Windows 執行確認**（2026-07-21 實測）：§0–§3d 全在原生 cmd/PowerShell 跑得動（呼叫 `.bat`）。
> **只有 §3e 是 bash 腳本,需 Git Bash**。download 若回 403 = 那顆 code 沒下載權限,非語法問題（換有權限的 code 即可）。

## 0. 拿 Software depot ID（第一次用工具才要做）
**產一顆 Software depot ID**（工具本機只會有一顆；`--force` 才會蓋掉重產）：
```
<tool> configuration generate --software-depot-id
```
▸ 範例：
```
E:\vdt0400-test\bin\vcf-download-tool.bat configuration generate --software-depot-id
```
**讀出目前這顆**（換 code 時要用，貼去 portal 重產 activation code）：
```
<tool> configuration get --software-depot-id
```
▸ 範例：
```
E:\vdt0400-test\bin\vcf-download-tool.bat configuration get --software-depot-id
```
> 流程：`generate` 產 ID → 到 <https://vcf.broadcom.com> 用這顆 ID 產 **activation code** → 存成單行檔 `<code>` → 之後每條指令都帶 `--depot-download-activation-code-file=<code>`。
> ⚠️ 換 code 用 **`get`** 讀原本那顆 ID 去 portal 重產,**不要 `generate --force`**（換 ID 等於全新綁定）。

## 1. 驗 code（回 "Depot credentials are valid" = OK）
```
<tool> releases list --depot-download-activation-code-file=<code>
```
▸ 範例：
```
E:\vdt0400-test\bin\vcf-download-tool.bat releases list --depot-download-activation-code-file=E:\vdt0400-test\actcode.txt
```

## 2. 查版本 + 拿 bundle ID（ID 在每列最前）
```
<tool> binaries list --vcf-version=9.1.0.0 --sku=VCF --automated-install --type=INSTALL --depot-download-activation-code-file=<code>
```
▸ 範例：
```
E:\vdt0400-test\bin\vcf-download-tool.bat binaries list --vcf-version=9.1.0.0 --sku=VCF --automated-install --type=INSTALL --depot-download-activation-code-file=E:\vdt0400-test\actcode.txt
```

## 3a. 下特定版本（用 bundle ID，最精準）
```
<tool> binaries download --depot-store=<depot> --depot-download-activation-code-file=<code> --id=<bundleId> --ceip=DISABLE
```
▸ 範例（下 SDDC_MANAGER_VCF 9.1.0.0400.25570100）：
```
E:\vdt0400-test\bin\vcf-download-tool.bat binaries download --depot-store=E:\vcf9-depot --depot-download-activation-code-file=E:\vdt0400-test\actcode.txt --id=d562377e-7bec-5038-ac46-5a725e064212 --ceip=DISABLE
```

## 3b. 下多個特定版本（逗號分隔）
```
<tool> binaries download --depot-store=<depot> --depot-download-activation-code-file=<code> --id=<id1>,<id2>,<id3> --ceip=DISABLE
```
▸ 範例（SDDC + FLEET_LCM + SDDC_LCM 三個 0400）：
```
E:\vdt0400-test\bin\vcf-download-tool.bat binaries download --depot-store=E:\vcf9-depot --depot-download-activation-code-file=E:\vdt0400-test\actcode.txt --id=d562377e-7bec-5038-ac46-5a725e064212,95acbc11-298a-51c2-9b0e-e0668b8ef5e8,d0d5bea0-c8a5-5a11-a398-19f23eb30291 --ceip=DISABLE
```

## 3c. 下整條 9.1.0.0 線的 install 集（filter，不釘 ID）
```
<tool> binaries download --depot-store=<depot> --depot-download-activation-code-file=<code> --vcf-version=9.1.0.0 --sku=VCF --automated-install --type=INSTALL --ceip=DISABLE
```
▸ 範例：
```
E:\vdt0400-test\bin\vcf-download-tool.bat binaries download --depot-store=E:\vcf9-depot --depot-download-activation-code-file=E:\vdt0400-test\actcode.txt --vcf-version=9.1.0.0 --sku=VCF --automated-install --type=INSTALL --ceip=DISABLE
```

## 3d. 下某元件的特定版（--component + 版本，要帶 --vcf-version）
```
<tool> binaries download --depot-store=<depot> --depot-download-activation-code-file=<code> --vcf-version=9.1.0.0 --sku=VCF --type=INSTALL --component=VCF_LICENSE_SERVER --component-version=9.1.0.0200 --ceip=DISABLE
```
▸ 範例（只下 License Server 9.1.0.0400）：
```
E:\vdt0400-test\bin\vcf-download-tool.bat binaries download --depot-store=E:\vcf9-depot --depot-download-activation-code-file=E:\vdt0400-test\actcode.txt --vcf-version=9.1.0.0 --sku=VCF --type=INSTALL --component=VCF_LICENSE_SERVER --component-version=9.1.0.0400 --ceip=DISABLE
```

## 3e. 只下「每元件最新版」（wrapper 自動 list→挑最新→下,不用手撈 ID）
> ⚠️ **這是 bash 腳本,純 Windows cmd/PowerShell 跑不動,要 Git Bash。** 沒 Git Bash 的機器改走下面「純 cmd 替代」。
```
bash download-latest.sh <tool> <code> <depot> 9.1.0.0
```
▸ 範例（有 Git Bash,在 Git Bash 視窗跑）：
```
bash download-latest.sh E:\vdt0400-test\bin\vcf-download-tool.bat E:\vdt0400-test\actcode.txt E:\vcf9-depot 9.1.0.0
```
▸ 在 cmd 想直接叫 Git Bash 跑（用 bash.exe 全路徑）：
```
"C:\Program Files\Git\bin\bash.exe" download-latest.sh E:\vdt0400-test\bin\vcf-download-tool.bat E:\vdt0400-test\actcode.txt E:\vcf9-depot 9.1.0.0
```
先看要下哪些版本不真下,加 `--dry-run`。

**純 cmd 替代（沒 Git Bash）**：跑 §2 `binaries list`,肉眼挑每元件版本最高那列的 ID,填進 §3b `--id=` 下載。效果一樣,只是手動挑。
> 工具無 `--latest` 旗標;此腳本 list 全版本→每元件挑版本最高→`--id` 下。出新 patch 自動抓新最新。

---
- `--depot-store` = 下載輸出夾（自動建 `PROD/COMP/…` + `metadata/`）；同夾重跑會累加、跳過已下的
- `--id`（特定版本）跟 `--vcf-version`（filter）**三選一互斥**，不要混
- 範例的 bundle ID 是**今天這版**的（`--id` 會隨新 patch 變）；用前先跑 §2 重撈確認
- Linux 路徑同理：`<tool>`→`/opt/vdt/bin/vcf-download-tool`、`<depot>`→`/opt/vcf-depot/vcf9`
- code 有時效；過期或 binary 403 → 換一顆有下載權限的 code（同 software depot ID 重產）

> 完整說明見 [VCF-DOWNLOAD-TOOL.md](VCF-DOWNLOAD-TOOL.md)；下成 depot 的流程見 [DOWNLOAD-INTO-DEPOT.md](DOWNLOAD-INTO-DEPOT.md)。
