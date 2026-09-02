# 離線 OS 套件庫 + RHEL 版 VCF Depot（air-gapped 場景）

VCF depot server 本身也要一台 OS。在**完全斷網**的環境，這台 OS 要裝 nginx/openssl/keytool 等
套件時沒有網路 apt/dnf 可用 —— 這組腳本解決「**先把 OS 套件庫也離線化**」，並提供 **RHEL 版**的
VCF depot（跟主線 Ubuntu 的 `create_vcf9_depot_server_v5.sh` 對應）。

> 主線（Ubuntu + v5）見 `CUSTOMER-DEPLOY-GUIDE.md` / `UPLOAD-STEPS.md`。本文是 **RHEL/離線 OS repo** 的搭配。

---

## 腳本一覽

| 腳本 | 用途 |
|------|------|
| `setup_rhel10_offline_repo.sh` | 用 RHEL 10 安裝 DVD ISO 架**本地 DNF/YUM repo**（BaseOS+AppStream，HTTP:80），免 Red Hat 訂閱/網路 |
| `setup_rhel_offline_all.sh` | RHEL/Rocky/Alma **一體式**：同一台一個 nginx 同時跑 ① DNF repo(HTTP:80) ② VCF depot(HTTPS:443) |
| `create_vcf9_depot_server_rhel.sh` | **RHEL 版** VCF 離線 depot（nginx，HTTPS+Basic-auth，可與其他服務共存於同 host）|
| `change_rhel_offline_hostname_ip.sh` | 改上述 RHEL 離線 server 的 hostname/IP，並同步更新所有引用（/etc/hosts、nginx、cert…）|
| `ubuntu_offline_packages.sh` | Ubuntu 無安裝 DVD repo → **預先在有網機器抓 .deb 包**、帶進 air-gapped Ubuntu 離線安裝。<br>💡 20.04 / 22.04 / 24.04 **已有 build 好的包**放在 [Releases](https://github.com/kostenyang/vcf9offlinescript/releases/tag/ubuntu-vcfdepot-offline)，可直接下載免自己 build（見場景 C）|

---

## 場景 A：RHEL 一體式（DNF repo + VCF depot 同機）

```bash
# 1. 架 RHEL 離線 DNF repo + VCF depot（DVD ISO 掛好）
sudo bash setup_rhel_offline_all.sh --iso /path/RHEL-10.x-x86_64-dvd.iso \
     --fqdn <FQDN> --ip <IP>
#  -> DNF repo  http://<IP>/rhel/{BaseOS,AppStream}
#  -> VCF depot https://<IP>/PROD/ (nginx, basic-auth vcfdepot)

# 2. RHEL client 指到離線 repo（免訂閱）
#    /etc/yum.repos.d/offline.repo 指 http://<IP>/rhel/BaseOS 等

# 3. 灌 VCF binary 進 depot（PROD/ 放好後）
sudo cp -r <depot>/PROD  /opt/vcf-depot/vcf9/
sudo chown -R nginx:nginx /opt/vcf-depot/vcf9              # RHEL 是 nginx(不是 www-data)
sudo find /opt/vcf-depot/vcf9 -type d -exec chmod 0500 {} +
sudo find /opt/vcf-depot/vcf9 -type f -exec chmod 0400 {} +
sudo restorecon -Rv /opt/vcf-depot/vcf9                    # ⚠️ RHEL+SELinux Enforcing 必做,否則 nginx 讀不到
sudo nginx -t && sudo systemctl reload nginx
```

## 場景 B：只要 RHEL 版 VCF depot（不需 OS repo）
```bash
sudo bash create_vcf9_depot_server_rhel.sh --fqdn <FQDN> --ip <IP> --web-server nginx
# 與其他 web 服務共存;埠可調(預設 443)。之後灌 PROD/ 同上(chown nginx + restorecon)。
```

## 場景 C：air-gapped Ubuntu 先離線化套件

Ubuntu 沒有像 RHEL 那種可當 repo 的安裝 DVD，所以離線裝 nginx 這類套件，
必須先在**有網路**的機器抓好完整相依樹再帶進去。

### 快路：直接下載已 build 好的包（GitHub Release）

已預先 build 好 20.04 / 22.04 / 24.04 三個版本，**不用自己 build**：

```bash
gh release download ubuntu-vcfdepot-offline -R kostenyang/vcf9offlinescript -p 'ubuntu-vcfdepot-offline-2404-amd64.tar.gz'
```
```bash
curl -LO https://github.com/kostenyang/vcf9offlinescript/releases/download/ubuntu-vcfdepot-offline/ubuntu-vcfdepot-offline-2404-amd64.tar.gz
```

| 附件 | 大小 | 對應 Ubuntu |
|---|---|---|
| `ubuntu-vcfdepot-offline-2004-amd64.tar.gz` | 61.2 MB | 20.04 |
| `ubuntu-vcfdepot-offline-2204-amd64.tar.gz` | 66.5 MB | 22.04 |
| `ubuntu-vcfdepot-offline-2404-amd64.tar.gz` | 72.1 MB | 24.04 |

內容為 `create_vcf9_depot_server_v5.sh` 需要的**全部**套件完整相依樹：

```
openssl apache2-utils jq tar curl unzip ca-certificates nginx default-jre-headless
```

> 🔴 **舊的 `ubuntu-offline-2004` release 只含 `nginx apache2-utils openssl`，缺 `jq` / `unzip`**
> → 會卡在 `[ERROR] apt could not install: jq unzip`。請改用本 release。

三包皆在 `docker run --network none`（**完全斷網**）的乾淨容器內實測 `dpkg -i` 安裝，
確認 `jq unzip nginx openssl htpasswd curl tar` 全部可用。

> 🔴 **版本與架構必須完全相符** —— 24.04 的 .deb 不能裝在 22.04 上。先確認目標機：
> ```bash
> lsb_release -rs && dpkg --print-architecture
> ```

### 慢路：自己 build（清單不同或非 amd64 時）

在**有網路、且與目標機同 release + 同架構**的 Ubuntu 上：

```bash
sudo bash ubuntu_offline_packages.sh --build --packages "nginx apache2-utils openssl jq tar curl unzip ca-certificates default-jre-headless" --output /root/ubuntu-vcfdepot-offline.tar.gz
```

### 帶進 air-gapped Ubuntu 安裝

```bash
sudo bash ubuntu_offline_packages.sh --install --bundle ./ubuntu-vcfdepot-offline-2404-amd64.tar.gz
```
```bash
sudo bash create_vcf9_depot_server_v5.sh --fqdn <FQDN> --ip <IP> --web-server nginx --skip-disk-setup
```

### 旗標

| 旗標 | 說明 |
|---|---|
| `--build` / `--install` | 模式（擇一） |
| `--packages "<pkg1> <pkg2>"` | 要抓的套件，預設 `nginx apache2-utils openssl` |
| `--output <file>.tar.gz` | build 輸出，預設 `/root/ubuntu-offline-packages.tar.gz` |
| `--bundle <file>.tar.gz` | install 讀取的包 |

## 額外：depot 開一個 `:8888` no-auth HTTP 端點（9.1 新 HTTP offline depot 用）
VCF 9.1 支援**免認證 HTTP** offline depot（僅 API 可設，UI 不行）。在 depot server 加一段 nginx：
```nginx
# /etc/nginx/conf.d/vcf9-noauth.conf
server {
  listen 8888;
  location /PROD/ { alias /opt/vcf-depot/vcf9/PROD/; autoindex on; }
}
```
`nginx -t && systemctl reload nginx` → installer 用 `http://<IP>:8888`（API 設定，無帳密、無憑證匯入）。

---

## 改 hostname/IP
```bash
sudo bash change_rhel_offline_hostname_ip.sh --new-ip <IP> --new-fqdn <FQDN>
#  一次更新 hostnamectl + /etc/hosts + nginx server_name + 重簽含 IP-SAN 的 cert
```
（Ubuntu 版對應 `change_depot_hostname_ip.sh`。）

---

## 踩雷（RHEL 特有）

| 症狀 | 解法 |
|------|------|
| nginx 403/讀不到 depot 檔（權限對卻不行）| **SELinux**：`restorecon -Rv /opt/vcf-depot/vcf9`（Enforcing 下必做）|
| 屬主用 www-data 失敗 | RHEL nginx 跑 **`nginx`** 使用者，不是 Ubuntu 的 `www-data` |
| DNF client 仍要訂閱 | client `/etc/yum.repos.d/` 指離線 repo + `subscription-manager config --rhsm.manage_repos=0` |
