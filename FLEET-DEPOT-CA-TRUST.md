# 讓 VCF 9.1 Fleet Depot Service 信任 offline depot 的 CA

在 VCF 9.1，software depot 的連線由 **Fleet Depot Service** 負責，它跑在 **VSP(VCF Service Runtime)平台**上。
要讓 fleet 連 **自簽/自建 CA 的 offline depot**，光把 CA 匯進 SDDC Manager appliance 的 keytool 是**不夠的** ——
CA 必須進 **VSP 平台的 trusted-certificates 庫**。官方做法見 **Broadcom KB 442978**，用其附的
`add_trusted_certificate.py`。

> 🔒 **腳本本體不放本 repo**：`add_trusted_certificate.py` 標示 *Copyright Broadcom / Broadcom Confidential*，
> 請自行從 **[KB 442978](https://knowledge.broadcom.com/external/article/442978)** 下載。本文件只記錄「怎麼用」。

---

## 前置：depot 憑證要合格(否則怎麼匯都白搭)

VCF 9.1 Fleet 強制要求 depot TLS 憑證 **SAN 同時含 FQDN + IP**(見 KB 424807)。先驗：
```bash
echo | openssl s_client -connect <depot-ip>:443 -servername <depot-fqdn> 2>/dev/null \
  | openssl x509 -noout -subject -ext subjectAltName
# 要看到:  DNS:<depot-fqdn>, IP Address:<depot-ip>   ← 兩個都要有
```
少了就重簽 depot 憑證(builder 的 `change_depot_hostname_ip.sh` 會自動重生對的 SAN)。

## 步驟 1 — 把 depot 自簽 CA 抓成 PEM
```bash
echo | openssl s_client -connect <depot-ip>:443 -servername <depot-fqdn> 2>/dev/null \
  | openssl x509 -outform PEM > /tmp/depot-ca.pem
```
> PEM 鏈順序:leaf(可略)→ intermediate(有就必附)→ **root(必附)**。
> 自簽 depot：那張自簽本身就是 root，上面 `openssl x509` 一張即可。

## 步驟 2 — 找 VSP(VCF Service Runtime)FQDN
```bash
# 在 SDDC Manager 上
getent hosts <vcf-instance>-vsp01.<domain>       # 例:vcf-m02-vsp01.home.lab
```

## 步驟 3 — 跑 add_trusted_certificate.py

### 參數
| 參數 | 說明 |
|---|---|
| `--vsp-fqdn` | VCF Service Runtime FQDN/IP(env `VSP_FQDN`) |
| `--admin-user` | VSP admin,預設 `admin@vsp.local`(env `ADMIN_USERNAME`) |
| `--admin-password` | VSP admin 密碼，不給會互動問(env `ADMIN_PASSWORD`) |
| `--cert-file <PEM>` | **模式A**:匯入手上的 PEM(自簽 depot CA 用這個) |
| `--fetch-from-proxy host:port` | **模式B**:透過 HTTP CONNECT proxy 自動抓 CA 鏈(搭 `--connect-host`，預設探 `eapi.broadcom.com:443`) |
| `--output-dir` | 模式B 拆出的 PEM 存哪 |
| `--import-leaf` | 連 leaf 也匯(預設跳過，只匯 CA) |
| `--dry-run` | **只印 payload 不呼叫 API**(先跑這個預覽) |
| `-v` | verbose |

### 官方跑法(在 SDDC Manager)
```bash
# copy add_trusted_certificate.py 到 SDDC Manager /home/vcf/
# SSH 以 vcf 登入 → su 到 root
python3 /home/vcf/add_trusted_certificate.py \
  --vsp-fqdn <vsp-fqdn> \
  --admin-user admin@vsp.local --admin-password '<VSP-admin-pw>' \
  --cert-file /tmp/depot-ca.pem
```

### 免 SSH 跑法(appliance sshd 被 STIG 擋時 — 用 vCenter guest-ops)
appliance root 常無法直接 SSH，改用 **vCenter guest-ops(VMware Tools)** 上傳 + 執行:
```bash
export GOVC_URL='https://administrator@vsphere.local:<pw>@<inner-vcenter>' GOVC_INSECURE=1 MSYS_NO_PATHCONV=1
VM='/<dc>/vm/<vcf-instance>-sddcm01'; L='root:<sddcm-root-pw>'

govc guest.upload -vm "$VM" -l "$L" -f ./add_trusted_certificate.py /home/vcf/add_trusted_certificate.py
govc guest.upload -vm "$VM" -l "$L" -f ./depot-ca.pem /tmp/depot-ca.pem

# 🔴 用 guest.run 直接帶參數(別用 `bash -c '...'`,引號會被 govc 吃掉 → 空 log)
govc guest.run -vm "$VM" -l "$L" /usr/bin/python3 /home/vcf/add_trusted_certificate.py \
  --vsp-fqdn <vsp-fqdn> --admin-user admin@vsp.local --admin-password '<VSP-admin-pw>' \
  --cert-file /tmp/depot-ca.pem
```

## 預期輸出(成功)
```
==> Acquiring VSP bearer token...   Token acquired successfully.
==> POST https://<vsp-fqdn>/api/v1/system/trusted-certificates?action=add   HTTP 201
==> Polling task ...   Pending → Running → Succeeded
==> Done.
```

## 步驟 4 — 等服務重啟
匯入後 **Software Depot UI 會空白 ~15 分鐘**，等 fleet 服務重啟即可(正常現象)。

---

## 步驟 5 — 設定 / 驗證 fleet 的 depot 連線(純 API,不用 UI 登入)

CA 信任好之後,就能設 depot 連線。fleet 的 depot-service(`vcf-m02-fleet01`)要 **VSP 發的 Bearer token**
(`Bearer realm="VCF"`;SDDC Manager `/v1/tokens`、VCFA provider token 都會被 `INVALID_TOKEN_ISSUER` 拒)。

**① 跟 VSP 拿 token**(同 `add_trusted_certificate.py` 內部那招):
```bash
VSP=vcf-m02-vsp01.home.lab
TOK=$(curl -sk -X POST "https://$VSP/api/v1/identity/token" \
  -H "Content-Type: application/x-www-form-urlencoded" -H "Accept: application/json" \
  --data-urlencode grant_type=password \
  --data-urlencode username=admin@vsp.local \
  --data-urlencode password='<VSP-admin-pw>' | jq -r .access_token)
```

**② 看目前 depot 連線設定**:
```bash
FLEET=vcf-m02-fleet01.home.lab
curl -sk -H "Authorization: Bearer $TOK" "https://$FLEET/depot-service/api/depot/v1/connectivity"
# {"depotType":"OFFLINE","offlineDepot":{"url":"https://...","username":"vcfdepot"}}
```

**③ 設(或改)成 offline depot**(用憑證 SAN 裡的 **FQDN**,不要用 IP):
```bash
curl -sk -X PUT "https://$FLEET/depot-service/api/depot/v1/connectivity" \
  -H "Authorization: Bearer $TOK" -H "Content-Type: application/json" \
  -d '{"depotType":"OFFLINE","offlineDepot":{
        "url":"https://vcf9depotserver.home.lab",
        "username":"vcfdepot","password":"<depot-pw>"}}'
# HTTP 202 (async) → GET 回來 url 應變成 https://vcf9depotserver.home.lab:443
```

### 實測(2026-07-17 本 lab M02)
```
GET  connectivity → {"depotType":"OFFLINE","offlineDepot":{"url":"https://10.0.0.61:443","username":"vcfdepot"}}
PUT  connectivity (改 FQDN) → HTTP 202
GET  connectivity → url = https://vcf9depotserver.home.lab:443    ← 無憑證錯誤 = CA 信任生效
```
> UI 驗證:VCF Operations → Fleet Management → Lifecycle → **Software Depot** 應顯示 Connected + 可用 bundle。

---

## 常見錯誤指紋
| 症狀 | 原因 / 對策 |
|---|---|
| `unable to find valid certification path to requested target` | fleet 不信任 depot CA → 就是本文件要解的,跑 add_trusted_certificate.py |
| `Failed to connect to authorization server to obtain access token` | 同上(KB 442978) |
| depot 連線一直跳憑證信任 / `errors syncing the LCM software depot` | depot 憑證 **SAN 缺 FQDN 或 IP**(KB 424807)→ 重簽 depot 憑證 |

## 除錯(2026-07-17 本 lab M02 實測踩到的坑)

1. **`govc guest.run/start` 用 `bash -c '複雜指令'` → 空 log / 沒跑到**
   引號經 bash → govc → guest 被吃掉,實際指令跑錯,log 檔 0 bytes。
   ✅ 改用 **`guest.run` 直接帶程式+參數**(同步收 stdout):
   `govc guest.run -vm <VM> -l root:<pw> /usr/bin/python3 /home/vcf/add_trusted_certificate.py --vsp-fqdn ... --cert-file ...`

2. **appliance keytool 匯 CA:SDDC Manager 成功、VCF OPS 失敗(且這不是 fleet 該匯的地方)**
   - `import_vcf9depot_ca.sh` 在 **SDDC Manager** 的 java21 cacerts:直接 OK。
   - **VCF OPS(vROps)**的 2 個 keystore(`/usr/java/jre-vmware-17`、`/usr/lib/vmware-vcops/jre`):
     `keytool` 預設(JKS)報 `Unrecognized keystore format`;`-storetype PKCS12` 報 `DerValue.getBigIntegerInternal, not expected 48`;`-cacerts` 也 `Unrecognized keystore format`
     → 這些是 **FIPS/BCFKS** 格式,keytool 一般模式吃不下。
     ✅ **別用 keytool,走 VCF Operations UI → Operate → Administration Control Panel → Trusted Certificates → Import(PEM)**。
   - 🔴 **重點**:appliance keytool 匯入 **不是** Fleet Depot Service 讀 trust 的地方 → 一定要跑 `add_trusted_certificate.py` 匯進 **VSP 平台**(本文件主流程)。

3. **fleet depot-service API token 被拒 `VCF_LCM_IAM_401_INVALID_TOKEN_ISSUER_ERR`**
   `https://<fleet01>/depot-service/api/depot/v1/connectivity` 要 `Bearer realm="VCF"`。
   用 **SDDC Manager `/v1/tokens`** 或 **VCFA `/cloudapi/1.0.0/sessions/provider`** 拿的 token 都被拒(issuer 對不上)。
   ✅ 正確 issuer = **VSP 發的 token**(`admin@vsp.local`,就是 `add_trusted_certificate.py` 內部 acquire 的那個);要純 API 設 depot 連線就用它。

4. **appliance 不能直接 SSH(STIG 硬化)** → 用 **vCenter guest-ops**(VMware Tools,`root/<root-pw>`)上傳 + 執行,繞過 sshd faillock。

## 相關
- **KB 442978** — VCF 9.1 Software Depot cert + `add_trusted_certificate.py`(腳本來源)
- **KB 424807** — depot 憑證 SAN(FQDN+IP)要求
- VCF Operations UI 匯 CA(FIPS keystore 正解):**Operate → Administration Control Panel → Trusted Certificates → Import(PEM)**
- depot 本體搭建見本 repo `create_vcf9_depot_server_v5.sh` / `import_vcf9depot_ca.sh`(那支是匯進 appliance,本文件是匯進 VSP 平台,兩者互補)
