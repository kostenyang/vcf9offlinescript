# Connecting a VCF Installer to an HTTPS + Basic-auth offline depot

Hard-won notes from wiring VCF Installer 9.1 to a depot stood up with
`create_vcf9_depot_server_v5.sh` (nginx, HTTPS, self-signed cert, Basic auth).
Every one of these produced a **misleading** error; they are listed with the
symptom you actually see.

---

## 1. Depot credentials go in `offlineAccount`, NOT `depotConfiguration`

**Symptom:** `PUT /v1/system/settings/depot` succeeds or the UI accepts the creds,
but the depot status is `DEPOT_INVALID_CREDENTIAL` / "The depot user or password is
invalid" — even though the exact same user/password works with `curl -u`.

**Cause:** `DepotSettings` schema is:

```json
{
  "offlineAccount":    { "username": "...", "password": "..." },
  "depotConfiguration":{ "isOfflineDepot": true, "url": "https://..." }
}
```

If you put `username`/`password` inside `depotConfiguration`, lcm receives **empty**
credentials and sends an unauthenticated request. The nginx access log confirms it —
you see `10.0.1.x - - "HEAD /PROD/metadata/..." 401` with **no auth user** (`-`).

**Fix:** put the credentials in the top-level `offlineAccount` object.

## 2. Use the depot **IP**, not the FQDN, in the depot URL

**Symptom:** `https://vcf9depotserver.home.lab` → *"The offline depot URL … is
invalid. Reason: … valid URL without query parameters or fragments."* (the URL has
neither). The **exact same** request with `https://10.0.0.61` gets past URL
validation.

**Fix:** configure the depot URL as `https://<depot-ip>` (no port; 443 is implied).
Make sure the self-signed cert has the IP in its SAN — `create_vcf9_depot_server_v5.sh`
already adds `IP:<ip>` to `subjectAltName`, so IP-based TLS verifies cleanly.

## 3. The depot cert must be trusted by the **system** store, not just Java cacerts

**Symptom:** cert imported into the JRE cacerts (`keytool -list` shows the alias),
but the depot connection **still** fails as "invalid username or password". lcm
validates the depot over the OS/OpenSSL trust path, so the JRE keystore alone is not
enough. `curl https://<depot>` (without `-k`) returns `ssl_verify_result=18`
(self-signed in chain).

**Cause:** on the Photon OS used by VCF Installer / SDDC Manager, `c_rehash` is often
absent, so the earlier `import_vcf9depot_ca.sh` copied the PEM into `/etc/ssl/certs`
but never rebuilt the trust hashes.

**Fix:** run Photon's own tool — `rehash_ca_certificates.sh`. `import_vcf9depot_ca.sh`
now falls back to it automatically. After it runs, `curl -u user:pass https://<depot>/…`
returns `verify=0` and `200`. Restart `lcm.service` so it re-reads trust.

## 4. Required bundles must be **downloaded into the installer** before bring-up

**Symptom:** bring-up validation "Versions and Bundles" → `FAILED` with
`FAILED_TO_RETRIEVE_COMPONENT_BINARY … Could not retrieve binary for component X` for
~16 components — even though the depot HTTP-serves every one of them.

**Cause:** connecting a depot only syncs the manifest; every bundle starts with
`downloadStatus: PENDING`. Validation checks the installer's **local** copy.

**Fix:** trigger downloads of the release's bundles into the installer:

```
PATCH /v1/bundles/{id}   body: {"bundleDownloadSpec": {"downloadNow": true}}
```

The installer pulls them from the depot into local storage (~60–100 GB for a base
9.1.0.0 install — the VCF Installer appliance has room). Then re-validate.

---

## Odds & ends

- **`lcm.service`** is the VCF Installer's core Java backend (nginx is only the
  front end on :443). Restart it — not `vcf-installer` — after any cert/trust change.
- **VCF Installer has SSH disabled** by default. Use vCenter guest operations
  (`Invoke-VMScript`) to run commands / import the cert on the appliance.
- **CRLF:** if you edit these scripts on Windows and copy them to a Linux box, run
  `sed -i 's/\r$//' <script>` first, or they fail with `set: pipefail: invalid
  option name`.
