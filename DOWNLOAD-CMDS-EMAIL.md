# VCF Download Tool 指令 — Email 可直接貼版（絕對路徑 sample）

給客戶/同事的純文字版，複製下面整段貼進信即可。**把 `C:\VCF9` 換成對方實際的工具路徑**。

> 佔位路徑：工具根 `C:\VCF9`（`bin\vcf-download-tool.bat`）、code 檔 `C:\VCF9\actcode.txt`、輸出 `C:\VCF9\depot`。
> Windows 原生 cmd 直接跑（§0–§5 皆是）；Linux 去 `.bat`、路徑換成 `/…`。

```
【VCF Download Tool 指令 — Windows】
工具路徑：C:\VCF9\bin\vcf-download-tool.bat
Code 檔  ：C:\VCF9\actcode.txt        （單行純文字，內容=activation code）
下載輸出 ：C:\VCF9\depot              （會自動長出 PROD\COMP\... + metadata）

■ 0. 取得 Software depot ID（第一次；拿去 portal 產 activation code）
C:\VCF9\bin\vcf-download-tool.bat configuration get --software-depot-id

■ 1. 驗證 code（回 "Depot credentials are valid" = OK）
C:\VCF9\bin\vcf-download-tool.bat releases list --depot-download-activation-code-file=C:\VCF9\actcode.txt

■ 2. 列出可下載的元件版本（ID 在每列最前欄）
C:\VCF9\bin\vcf-download-tool.bat binaries list --vcf-version=9.1.0.0 --sku=VCF --automated-install --type=INSTALL --depot-download-activation-code-file=C:\VCF9\actcode.txt

■ 3. 下載指定版本（用 §2 查到的 bundle ID，逗號分隔多個）
C:\VCF9\bin\vcf-download-tool.bat binaries download --depot-store=C:\VCF9\depot --depot-download-activation-code-file=C:\VCF9\actcode.txt --id=<bundleId1>,<bundleId2> --ceip=DISABLE

■ 4. 下載整條 9.1.0.0 安裝集（不指定版本，全下）
C:\VCF9\bin\vcf-download-tool.bat binaries download --depot-store=C:\VCF9\depot --depot-download-activation-code-file=C:\VCF9\actcode.txt --vcf-version=9.1.0.0 --sku=VCF --automated-install --type=INSTALL --ceip=DISABLE

■ 5. 下載某元件的特定版（例：License Server 9.1.0.0400）
C:\VCF9\bin\vcf-download-tool.bat binaries download --depot-store=C:\VCF9\depot --depot-download-activation-code-file=C:\VCF9\actcode.txt --vcf-version=9.1.0.0 --sku=VCF --type=INSTALL --component=VCF_LICENSE_SERVER --component-version=9.1.0.0400 --ceip=DISABLE

備註：
- 「只下最新」= 先跑 §2，挑每個元件版本最高那列的 ID，填進 §3 的 --id。
- --vcf-version 要用 9.1.0.0（不是 9.1.0.0400；0400 是其下的 patch）。
- code 有時效；若下載回 403，代表該 code 帳號沒下載權限，換一顆有權限的即可（指令不用改）。
```

---
- 帶佔位符 + 每條實填範例的版本：[DOWNLOAD-CMDS-ONELINE.md](DOWNLOAD-CMDS-ONELINE.md)
- 工具完整手冊（旗標/雷）：[VCF-DOWNLOAD-TOOL.md](VCF-DOWNLOAD-TOOL.md)
