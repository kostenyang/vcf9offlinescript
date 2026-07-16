# VCF 9.1.0.0400 Depot — 要下載的檔案清單（16 元件 / 48 檔 / 66GB）

「每元件最新版」的完整 install 集（= VCF Installer bringup 那套）。這就是 `E:\vcf-0400-flat`
平面夾的內容，也是 `sort-flat-depot.sh` 歸位後 `PROD/COMP/<代號>/` 的檔案。

- 版本：多數 **0400**；vCenter/NSX/VSP/VRA/VCD-Migration 最新為 **0200**、VIDB **0100**、Telemetry base。
- 每個元件 = 主 binary(.ova/.iso/.tgz/.tar) + plugin(.tgz) + `configuration-schema-*.yaml` + `depot-manifest-*.yaml`（後三個很小，跟著主檔）。
- 總量 **66GB**（大檔佔比：VSP 18G、VRA 15G、vCenter 12G、NSX 7.6G）。

---

## 依元件（代號）分組

### VCENTER — VMware vCenter（12 GB）
- `VMware-VCSA-all-9.1.0.0200.25573614.iso` — 12 GB

### NSX_T_MANAGER — VMware NSX（7.6 GB）
- `nsx-unified-appliance-9.1.0.0200.25524172.ova` — 7.6 GB

### SDDC_MANAGER_VCF — SDDC Manager（2.3 GB）
- `VCF-SDDC-Manager-Appliance-9.1.0.0400.25570100.ova` — 2.3 GB

### VROPS — VCF Operations（3.1 GB）
- `Operations-Appliance-9.1.0.0400.25541561.ova` — 3.1 GB

### VCF_OPS_CLOUD_PROXY — Cloud proxy（2.8 GB）
- `Operations-Cloud-Proxy-9.1.0.0400.25541562.ova` — 2.8 GB

### VCF_LICENSE_SERVER — License server（658 MB）
- `Vcf-License-Server-9.1.0.0400.25541557.ova` — 658 MB

### VSP — VCF services runtime（~18 GB）
- `vcf-services-platform-template-9.1.0.0200.25555874.ova` — 11 GB
- `vmsp-platform-9.1.0.0200.25555874.tar` — 6.9 GB
- `vmsp-cli-9.1.0.0200.25555874.tar.gz` — 48 MB
- `vmsp-plugin-9.1.0.0200.25555874.tgz` — 72 KB
- `configuration-schema-vmsp-platform-9.1.0.0200.25555874.yaml` / `depot-manifest-vmsp-platform-9.1.0.0200.25555874.yaml`

### VRA — VCF Automation（15 GB）
- `vcfa-bundle-9.1.0.0200.25556825.tar` — 15 GB
- `vcfa-plugin-9.1.0.0200.25556825.tgz` — 120 KB
- `configuration-schema-vcfa-bundle-9.1.0.0200.25556825.yaml` / `depot-manifest-vcfa-bundle-9.1.0.0200.25556825.yaml`

### VIDB — Identity broker（1.1 GB）
- `vidb-9.1.0.0100.25522734.tgz` — 1.1 GB
- `vidb-upgrade-plugin-9.1.0.0100.25522734.tgz` — 6.5 KB
- `configuration-schema-vidb-9.1.0.0100.25522734.yaml` / `depot-manifest-vidb-9.1.0.0100.25522734.yaml`

### VCF_SERVICE_VCD_MIGRATION_BACKEND — Migration service engine（522 MB）
- `vcd-migrator-9.1.0.0200.25556825.tgz` — 522 MB
- `vcd-migrator-plugin-9.1.0.0200.25556825.tgz` — 824 B
- `configuration-schema-vcd-migrator-9.1.0.0200.25556825.yaml` / `depot-manifest-vcd-migrator-9.1.0.0200.25556825.yaml`

### VCF_SDDC_LCM — SDDC lifecycle（815 MB）
- `vcf-sddc-lcm-9.1.0.0400.25570103.tgz` — 815 MB
- `vcf-sddc-lcm-plugin-9.1.0.0400.25570103.tgz` — 795 B
- `configuration-schema-vcf-sddc-lcm-9.1.0.0400.25570103.yaml` / `depot-manifest-vcf-sddc-lcm-9.1.0.0400.25570103.yaml`

### VCF_FLEET_LCM — Fleet lifecycle（756 MB）
- `vcf-fleet-lcm-9.1.0.0400.25570104.tgz` — 756 MB
- `vcf-fleet-lcm-plugin-9.1.0.0400.25570104.tgz` — 797 B
- `configuration-schema-vcf-fleet-lcm-9.1.0.0400.25570104.yaml` / `depot-manifest-vcf-fleet-lcm-9.1.0.0400.25570104.yaml`

### DEPOT_SERVICE — Software depot（550 MB）
- `vcf-fleet-depot-9.1.0.0400.25570105.tgz` — 550 MB
- `vcf-fleet-depot-plugin-9.1.0.0400.25570105.tgz` — 871 B
- `configuration-schema-vcf-fleet-depot-9.1.0.0400.25570105.yaml` / `depot-manifest-vcf-fleet-depot-9.1.0.0400.25570105.yaml`

### VCF_SALT — Salt master（346 MB）
- `salt-9.1.0.0400.25544946.tgz` — 346 MB
- `salt-plugin-9.1.0.0400.25544946.tgz` — 852 B
- `configuration-schema-salt-9.1.0.0400.25544946.yaml` / `depot-manifest-salt-9.1.0.0400.25544946.yaml`

### VCF_SALT_RAAS — Salt RaaS（434 MB）
- `salt-raas-9.1.0.0400.25544946.tgz` — 434 MB
- `salt-raas-plugin-9.1.0.0400.25544946.tgz` — 920 B
- `configuration-schema-salt-raas-9.1.0.0400.25544946.yaml` / `depot-manifest-salt-raas-9.1.0.0400.25544946.yaml`

### TELEMETRY_ACCEPTOR — Telemetry（99 MB）
- `telemetry-acceptor-9.1.0.0.25181946.tgz` — 99 MB
- `telemetry-acceptor-plugin-9.1.0.0.25181946.tgz` — 771 B
- `configuration-schema-telemetry-acceptor-9.1.0.0.25181946.yaml` / `depot-manifest-telemetry-acceptor-9.1.0.0.25181946.yaml`

---

## 另需（不含在上面 66GB 平面集裡）

| 項 | 說明 |
|----|------|
| **metadata 層** | catalog + Compatibility + vSAN HCL；用官方 metadata zip（`vcf-9.1.0.0400-offline-depot-metadata.zip`，13 檔）鋪 `PROD/metadata/`，見 `OA-FLAT-SORT-DEPOT.md` 附錄 |
| **ESXi**（可選）| `VMware-VMvisor-Installer-9.1.0.0200.25557999.x86_64.iso` → `ESX_HOST`（bringup host 用）|
| **選配、非必需** | HCX `9.1.0.0100.25535720`、NSX_ALB(Avi) `32.1.1.25377988`、VRSLCM `9.0.2`（9.1 不需要）|

> 用官方 `vcf-download-tool` 下這 16 元件 = `binaries download --id=<16 個最新版 bundleId>`（見 `DOWNLOAD-INTO-DEPOT.md`），工具會**連 metadata 一起下**，不必另配 metadata zip。
