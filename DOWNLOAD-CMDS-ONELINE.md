# VCF Download Tool — 可貼指令（每條一行）

把佔位符換成你的：`<tool>` = `…\bin\vcf-download-tool.bat`（Linux 去 `.bat`）、`<code>` = activation code 單行檔、`<depot>` = 下載輸出夾。

## 1. 驗 code（回 "Depot credentials are valid" = OK）
```
<tool> releases list --depot-download-activation-code-file=<code>
```

## 2. 查版本 + 拿 bundle ID（ID 在每列最前）
```
<tool> binaries list --vcf-version=9.1.0.0 --sku=VCF --automated-install --type=INSTALL --depot-download-activation-code-file=<code>
```

## 3a. 下特定版本（用 bundle ID，最精準）
```
<tool> binaries download --depot-store=<depot> --depot-download-activation-code-file=<code> --id=<bundleId> --ceip=DISABLE
```

## 3b. 下多個特定版本（逗號分隔）
```
<tool> binaries download --depot-store=<depot> --depot-download-activation-code-file=<code> --id=<id1>,<id2>,<id3> --ceip=DISABLE
```

## 3c. 下整條 9.1.0.0 線的 install 集（filter，不釘 ID）
```
<tool> binaries download --depot-store=<depot> --depot-download-activation-code-file=<code> --vcf-version=9.1.0.0 --sku=VCF --automated-install --type=INSTALL --ceip=DISABLE
```

## 3d. 下某元件的特定版（--component + 版本，要帶 --vcf-version）
```
<tool> binaries download --depot-store=<depot> --depot-download-activation-code-file=<code> --vcf-version=9.1.0.0 --sku=VCF --type=INSTALL --component=VCF_LICENSE_SERVER --component-version=9.1.0.0200 --ceip=DISABLE
```

## 3e. 只下「每元件最新版」（wrapper 自動 list→挑最新→下,不用手撈 ID）
```
bash download-latest.sh <tool> <code> <depot> 9.1.0.0
```
先看要下哪些版本不真下,加 `--dry-run`:
```
bash download-latest.sh <tool> <code> <depot> 9.1.0.0 --dry-run
```
> 工具無 `--latest` 旗標;此腳本 list 全版本→每元件挑版本最高→`--id` 下。出新 patch 自動抓新最新。

## 讀 Software depot ID（換 code 用；別 generate 重產）
```
<tool> configuration get --software-depot-id
```

---
- `--depot-store` = 下載輸出夾（自動建 `PROD/COMP/…` + `metadata/`）；同夾重跑會累加、跳過已下的
- `--id`（特定版本）跟 `--vcf-version`（filter）**三選一互斥**，不要混
- code 有時效；過期或 binary 403 → 換一顆有下載權限的 code（同 software depot ID 重產）

> 完整說明見 [VCF-DOWNLOAD-TOOL.md](VCF-DOWNLOAD-TOOL.md)；下成 depot 的流程見 [DOWNLOAD-INTO-DEPOT.md](DOWNLOAD-INTO-DEPOT.md)。
