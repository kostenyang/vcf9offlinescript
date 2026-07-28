# VCF Download Tool（Windows）走 Proxy 下載

客戶內網若**只能經 forward proxy 出外網**，Windows 版 vcf-download-tool 靠內建旗標
`--proxy-server` 就能整條走 proxy（認證 / 列版本 / metadata / binary 下載全部）。本文含
proxy 準備、帶 proxy 的完整指令（**含實際下載**）、以及一次實測驗證。

> 路徑 sample：工具 `C:\VCF9\bin\vcf-download-tool.bat`、code `C:\VCF9\actcode.txt`、輸出 `C:\VCF9\depot`、proxy `<PROXY_IP>:3128`。

---

## 1. Proxy 準備（二選一）

### A) 已有企業 proxy
直接用它的 `host:port`，跳到第 2 節。純 HTTP forward proxy（支援 HTTPS CONNECT）即可。

### B) 自建一個測試 proxy（Linux，無需裝套件，只要 python3）
把下面存成 `connect_proxy.py`（支援 HTTPS CONNECT 隧道 + 記 log）：
```python
import socket, threading, select, datetime
LISTEN=("0.0.0.0", 3128)
def log(m): print(f"{datetime.datetime.now().isoformat()} {m}", flush=True)
def tunnel(a,b):
    socks=[a,b]
    try:
        while True:
            r,_,x=select.select(socks,[],socks,30)
            if x or not r: break
            for s in r:
                other=b if s is a else a
                try: data=s.recv(65536)
                except: return
                if not data: return
                try: other.sendall(data)
                except: return
    finally:
        for s in (a,b):
            try: s.close()
            except: pass
def handle(c):
    try:
        c.settimeout(20); req=b""
        while b"\r\n\r\n" not in req:
            d=c.recv(4096)
            if not d: c.close(); return
            req+=d
        line=req.split(b"\r\n",1)[0].decode("latin1"); p=line.split()
        if len(p)>=2 and p[0].upper()=="CONNECT":
            host,_,port=p[1].partition(":"); port=int(port or 443)
            log(f"CONNECT {host}:{port}")
            try: remote=socket.create_connection((host,port),timeout=15)
            except Exception as e:
                log(f"  FAIL {host}:{port} {e}"); c.sendall(b"HTTP/1.1 502 Bad Gateway\r\n\r\n"); c.close(); return
            c.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n"); tunnel(c,remote)
        else:
            log(f"NON-CONNECT {line[:60]}"); c.close()
    except Exception as e:
        log(f"  err {e}")
        try: c.close()
        except: pass
srv=socket.socket(); srv.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
srv.bind(LISTEN); srv.listen(50); log(f"proxy listening {LISTEN}")
while True:
    cc,addr=srv.accept(); log(f"conn from {addr[0]}")
    threading.Thread(target=handle,args=(cc,),daemon=True).start()
```
**要用 systemd 跑**（背景直接 `nohup/&` 會隨 SSH session 被殺，這是踩過的雷）：
```bash
cat >/etc/systemd/system/testproxy.service <<'EOF'
[Unit]
Description=test connect proxy for vcf-download-tool
After=network.target
[Service]
ExecStart=/usr/bin/python3 /root/connect_proxy.py
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload && systemctl restart testproxy
systemctl is-active testproxy          # active
ss -ltn | grep 3128                    # LISTEN 0.0.0.0:3128
journalctl -u testproxy -f             # 看 CONNECT 記錄(stdout 進 journald,不是檔案)
```
> 這是**無認證 open proxy，只供內網測試**;測完 `systemctl disable --now testproxy` 拆掉。

---

## 2. 帶 Proxy 的指令（Windows cmd，加 `--proxy-server`）

只要在原本指令加 `--proxy-server=<PROXY_IP>:3128`。**純 HTTP proxy 不要加 `--proxy-https`**（那是「連 proxy 用 HTTPS」）。

```
:: 驗 code(經 proxy)
C:\VCF9\bin\vcf-download-tool.bat releases list --proxy-server=<PROXY_IP>:3128 --depot-download-activation-code-file=C:\VCF9\actcode.txt

:: 列版本(經 proxy)
C:\VCF9\bin\vcf-download-tool.bat binaries list --vcf-version=9.1.0.0 --sku=VCF --automated-install --type=INSTALL --proxy-server=<PROXY_IP>:3128 --depot-download-activation-code-file=C:\VCF9\actcode.txt

:: 實際下載 — 指定版本(經 proxy)
C:\VCF9\bin\vcf-download-tool.bat binaries download --depot-store=C:\VCF9\depot --proxy-server=<PROXY_IP>:3128 --depot-download-activation-code-file=C:\VCF9\actcode.txt --id=<bundleId1>,<bundleId2> --ceip=DISABLE

:: 實際下載 — 整條 9.1.0.0 安裝集(經 proxy)
C:\VCF9\bin\vcf-download-tool.bat binaries download --depot-store=C:\VCF9\depot --proxy-server=<PROXY_IP>:3128 --depot-download-activation-code-file=C:\VCF9\actcode.txt --vcf-version=9.1.0.0 --sku=VCF --automated-install --type=INSTALL --ceip=DISABLE
```

需 proxy 帳密時再加：`--proxy-user=<u> --proxy-user-password-file=<pwfile>`;proxy 本身走 HTTPS 才加 `--proxy-https`。

---

## 3. 下法（確認過的步驟）

照順序做;右欄是本次（2026-07-28 rtolab）**實測到的狀態**。

| 步驟 | 指令（都加 `--proxy-server=<PROXY_IP>:3128`） | 已驗證 |
|------|----------------------------------------------|--------|
| **① 起/確認 proxy** | 第 1 節 B) `systemctl is-active testproxy` = active、`ss -ltn｜grep 3128` | ✅ proxy listening、Windows 可達 |
| **② 驗 code 經 proxy** | `releases list --proxy-server=… --depot-download-activation-code-file=…` | ✅ exit=0、`Proxy configuration completed` |
| **③ 列版本挑 ID** | `binaries list --vcf-version=9.1.0.0 --sku=VCF --automated-install --type=INSTALL --proxy-server=… --…code-file=…` | ✅ exit=0、回 16 元件目錄（ID 在每列最前） |
| **④ 實際下載** | `binaries download --depot-store=C:\VCF9\depot --proxy-server=… --…code-file=… --id=<挑到的ID> --ceip=DISABLE` | ⚠️ 請求已穿 proxy 到 `dl.broadcom.com`;**bytes 需有下載權限的 code**（本次 code 無權限 → 403，非 proxy/指令問題） |
| **⑤ 確認結果** | 結尾看 `N SUCCESS / 0 FAILED`;`C:\VCF9\depot\PROD\COMP\…` 出現檔案 + `metadata\` | 待有權限 code 補綠 |

**流程確認結論**：①②③ 全綠、④ 的下載路徑已證實走 proxy。**下法本身正確**，唯一變數是 code 的下載 entitlement —— 換一顆有權限的 code，④ 就會實際落檔（同指令、不用改 proxy 設定）。

> 驗 proxy 真的有走：在 Linux 上 `journalctl -u testproxy -f`,執行上面任一步時會看到 `CONNECT eapi.broadcom.com:443` / `dl.broadcom.com:443` 等記錄。

---

## 4. 實測驗證（rtolab, 2026-07-28）

proxy = 自建 python CONNECT proxy on depot server `172.16.10.50:3128`；工具在 Windows（`172.16.10.32`）。

| 動作（帶 `--proxy-server=172.16.10.50:3128`） | 結果 |
|---|---|
| `releases list`（驗 code） | ✅ exit=0，`Proxy configuration completed` |
| `binaries list` | ✅ exit=0，回完整目錄（16 元件） |
| `binaries download --id=<Telemetry>` | 走 proxy 到 `dl.broadcom.com` → **403**（見下說明） |

**proxy journal 實錄**（工具的每種對外連線都經 proxy，共 38 筆 CONNECT）：
```
CONNECT eapi.broadcom.com:443        # 認證 / entitlement
CONNECT dl.broadcom.com:443          # binary 下載主機
CONNECT vvs.broadcom.com:443         # metadata / compatibility
CONNECT vsanhealth.vmware.com:443    # vSAN HCL
```
→ **證明 Windows 版工具在完全走 proxy 的環境下運作正常**：認證、列版本、metadata、binary 下載請求全部穿過 proxy。

### 關於「實際下載」的 403
上面 `binaries download` 回 403 **不是 proxy 問題**，是**當下那顆 activation code 沒有 binary 下載 entitlement**（proxy journal 顯示請求確實已送達 `dl.broadcom.com`）。
- 用**有下載權限的 code**，同一條 `--proxy-server` 指令即會實際下檔。
- 佐證：本專案先前（不經 proxy、用有權限的 code）已實測 `binaries download --id=<16 元件最新>` → **16/16 SUCCESS、66GB、含完整 metadata**。兩者相加 = **有權限的 code + proxy 環境 = 可完整下載**。

---

## 5. Proxy 旗標速查

| 旗標 | 說明 |
|---|---|
| `--proxy-server=<FQDN:Port>` | proxy 位址（**必要**） |
| `--proxy-https` | 「連 proxy 用 HTTPS」才加；一般 HTTP proxy **不要加** |
| `--proxy-user=<u>` | proxy 需認證時的帳號 |
| `--proxy-user-password-file=<file>` | proxy 密碼檔（單行） |

> 相關：一般（不走 proxy）指令見 [DOWNLOAD-CMDS-ONELINE.md](DOWNLOAD-CMDS-ONELINE.md) / email 版 [DOWNLOAD-CMDS-EMAIL.md](DOWNLOAD-CMDS-EMAIL.md)；工具手冊 [VCF-DOWNLOAD-TOOL.md](VCF-DOWNLOAD-TOOL.md)。
