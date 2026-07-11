# VCF 9.1 Offline Depot — step-by-step rundown (Linux, token-only)

Build a complete, ready-to-serve VCF 9.1 offline depot with just your **download
token** — no activation code, no Java download tool, no tool-version cap. Runs
**on the depot server itself** (Linux), so there is no download-then-upload step.

```
┌─ depot server (Linux) ─────────────────────────────────────────┐
│  pwsh My-VcfDepot.ps1 -BuildDepot -OutDir /opt/vcf-depot/vcf9   │
│         │  token → dl.broadcom.com  +  partnerweb (HCL)         │
│         ▼                                                       │
│  /opt/vcf-depot/vcf9/PROD/{COMP,metadata}  ──► nginx :443       │
└──────────────────────────────────────────────────────────┬─────┘
                                              VCF Installer ─┘ points here
```

> This repo is public — every `<...>` is a placeholder. Use your own values.
> Reference scripts live in this repo: `My-VcfDepot.ps1`,
> `create_vcf9_depot_server_v5.sh`, `sync-vcf-depot.sh`,
> `INSTALLER_CONNECT_TROUBLESHOOTING.md`.

---

## What you need

- A **Linux** box that will be the depot server (Ubuntu 20.04 / RHEL 8-9).
- Your **Broadcom download token** (the long path token, not an activation code).
- Outbound HTTPS to `dl.broadcom.com` and `partnerweb.vmware.com` **for the
  download phase only** — the server can be air-gapped afterwards.
- Disk: mgmt/bring-up set (`INSTALL`) is ~**250 GB**; plan a **≥ 400 GB** data
  disk on the depot root. (Full catalog incl. VKS/VKR/HCX is ~2.8 TB.)

---

## Step 1 — Install PowerShell 7 (one-time)

**Ubuntu 20.04:**
```bash
cd /tmp
wget -q https://packages.microsoft.com/config/ubuntu/20.04/packages-microsoft-prod.deb -O ms.deb
sudo dpkg -i ms.deb
sudo apt-get update
sudo apt-get install -y powershell
pwsh --version        # PowerShell 7.x
```

**RHEL 8/9:**
```bash
curl -sSL https://packages.microsoft.com/config/rhel/9/prod.repo | sudo tee /etc/yum.repos.d/microsoft.repo
sudo dnf install -y powershell
```

---

## Step 2 — Put the token in a file

```bash
echo '<YOUR-DOWNLOAD-TOKEN>' > /root/token.txt
chmod 600 /root/token.txt
```

---

## Step 3 — Build the depot in place

Grab `My-VcfDepot.ps1` from this repo onto the server, then:

```bash
# one-shot: management/bring-up component set + all metadata (catalog, manifest,
# vSAN HCL). No activation code needed.
pwsh /root/My-VcfDepot.ps1 -TokenFile /root/token.txt \
     -BuildDepot -OutDir /opt/vcf-depot/vcf9
```

- Idempotent + resume-safe: re-run any time; finished files show `ALREADY_OK`,
  partial files resume, every file is SHA-256 verified against the catalog.
- Output lands exactly where nginx serves it: `/opt/vcf-depot/vcf9/PROD/...`.
- **First** see what the token exposes: `-Summary` (all ~49 components) or
  `-Type INSTALL -Summary`.

**Add extra components later** (e.g. VKS material) into the same depot:
```bash
# pick one Kubernetes release instead of all of VKR (which is ~327 GB)
pwsh /root/My-VcfDepot.ps1 -TokenFile /root/token.txt \
     -Component VKR -Type INSTALL -FileNameLike '*1.33*' \
     -Download -OutDir /opt/vcf-depot/vcf9
```

> ⚠️ Passing a **comma list to `-Component` only works when the script is dot-run
> or via `pwsh -Command`**. With `pwsh -File` a comma list becomes one string —
> pass a single `-Component`, or repeat the build per component.

> ℹ️ `Compatibility/` (the interop/upgrade matrix from `vvs.broadcom.com`) is the
> one thing this does **not** fetch — it needs the vvs OAuth / activation code.
> It is day-2 lifecycle data and does **not** gate bring-up. Add it later with one
> pass of the official tool, or copy the two files from another depot.

---

## Step 4 — Stand up the web server (once)

If nginx isn't serving the depot yet:
```bash
sudo bash create_vcf9_depot_server_v5.sh \
     --fqdn <depot-fqdn> --ip <depot-ip> --web-server nginx
```
This publishes `https://<depot-ip>/` (443, self-signed SAN=FQDN+IP) with basic
auth. Note the depot user/password it prints.

---

## Step 5 — Fix permissions + verify serving

After any copy/build, make sure ownership/permissions (and SELinux on RHEL) are
right, then reload and verify:
```bash
sudo bash sync-vcf-depot.sh --local \
     --verify-url https://localhost/PROD/metadata/manifest/v1/vcfManifest.json
# HTTP 200 (or 401 if basic-auth) = serving OK
```
See `COPY_TO_DEPOT.md` for the manual equivalent.

---

## Step 6 — Point the VCF Installer at the depot

In the VCF Installer, configure the offline depot. The four things that trip
people up (full detail in `INSTALLER_CONNECT_TROUBLESHOOTING.md`):

1. Credentials go under **`offlineAccount:{username,password}`**, not
   `depotConfiguration`.
2. Depot URL must be the **IP**, `https://<depot-ip>` — an FQDN returns
   "invalid URL".
3. Import the depot **CA** into the installer, then on Photon run
   `rehash_ca_certificates.sh` (its `c_rehash` is absent) so the system trust
   updates.
4. **Pre-download** the required bundles into the installer
   (`PATCH /v1/bundles/{id}` `{"bundleDownloadSpec":{"downloadNow":true}}`)
   before bring-up validation, or it fails `FAILED_TO_RETRIEVE_COMPONENT_BINARY`.

---

## Quick reference

| Task | Command |
| --- | --- |
| See everything the token exposes | `pwsh My-VcfDepot.ps1 -TokenFile token.txt -Summary` |
| INSTALL bundles only | `... -Type INSTALL -Summary` |
| Build bring-up depot in place | `... -BuildDepot -OutDir /opt/vcf-depot/vcf9` |
| Add one component | `... -Component VSP -Type INSTALL -Download -OutDir /opt/vcf-depot/vcf9` |
| Fix perms + verify serving | `sudo bash sync-vcf-depot.sh --local --verify-url <url>` |

Full script docs: `MY_VCF_DEPOT.md`. Download-tool alternative: `VCF_DOWNLOAD_TOOL.md`.
End-to-end with the official tool: `END_TO_END.md`.
