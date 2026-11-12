# requiem — storage decommissioning pipeline

`requiem` is the final-form workflow built on top of AFDW. Where `afdw.sh`
focuses on the wipe, `requiem` treats *decommissioning a drive* as the whole job:

```
identify → PLAN → [ recover → archive → sanitize → verify → certificate ]
```

## Safety model: plan first, apply explicitly

By default `requiem` **only plans**. It identifies the device, shows the exact
erasure method and commands it *would* run, and inventories what it *would*
preserve — and changes nothing. You must pass `--apply` to execute. Even then it
re-verifies the device by serial number and makes you type the path and `ERASE`.

```bash
sudo ./requiem /dev/sdb            # PLAN only — destroys nothing
sudo ./requiem /dev/sdb --apply    # preserve, then wipe, then certify
```

## The six stages

1. **identify** — resolves the device to a stable `/dev/disk/by-id` path, reads
   model/serial/size, classifies the media (`nvme-ssd` / `sata-ssd` / `hdd` /
   `usb` / `mmc`) and **refuses the system disk** (override: `--genius`).
2. **plan** — chooses the erasure method and prints it (see below). Nothing runs.
3. **recover** *(opt-in, `--recover`)* — forensic recovery of deleted files,
   optional full `ddrescue` image, optional signature carving. Read-only.
4. **archive** *(default on)* — inventories live files, shows a categorized
   report, copies the worth-keeping ones out with a sha256 `MANIFEST.tsv`.
5. **sanitize** — runs the chosen primitive. Aborts the whole run *before* this
   point if recover/archive failed, so nothing is destroyed on error.
6. **verify + certificate** — samples the device to confirm the erase, then
   writes a **NIST SP 800-88** style certificate (JSON + printable text).

## Media-correct erasure (the forensic part)

`--method auto` (default) picks the *most effective primitive the media and
connection actually allow*, because overwriting is **not** the strongest option
on an SSD:

| Media | auto picks (best→fallback) | NIST |
|-------|----------------------------|------|
| NVMe SSD (direct) | crypto-erase → TRIM → overwrite | Purge → Clear |
| SATA SSD (direct) | ATA secure-erase → TRIM → overwrite | Purge → Clear |
| HDD | single-pass overwrite | Clear |
| USB-bridged SSD | TRIM → overwrite (random) | Clear |
| SD / eMMC | TRIM → overwrite | Clear |

Why: on an SSD the FTL, wear-leveling and over-provisioning hide copies of data
from any LBA overwrite. **Crypto-erase / firmware sanitize** reach those cells;
plain `dd` does not. Firmware commands usually don't pass through a **USB
bridge**, so for a bridged drive `requiem` uses TRIM (or overwrite) and *says so* —
and recommends attaching the drive directly for `--method crypto`/`secure-erase`.

Force a specific method with `--method crypto|sanitize|secure-erase|trim|overwrite-random|overwrite-zero`.

## The certificate

Each applied run writes `requiem-cert-<serial>-<stamp>.{json,txt}` recording the
device identity, the method **actually** applied (not an inflated claim), its
NIST 800-88 category, the verification result, and where preserved data went.
Useful as proof of disposal (e.g. GDPR) or for an ITAD hand-off.

## Layout

```
requiem                orchestrator (plan → apply)
lib/common.sh           logging, dry-run runner, helpers
lib/identify.sh         device id, media class, system-disk guard
lib/sanitize.sh         per-media method selection + apply
lib/verify.sh           post-wipe sampling (zero / entropy)
lib/certificate.sh      NIST 800-88 certificate (JSON + TXT)
prewipe-archive.sh      archive gate (reused)
prewipe-recover.sh      forensic recovery (reused)
tests/run.sh            loop-device + fixture test harness
```

## Tests

```bash
bash tests/run.sh          # pure-logic + fixture tests (no root needed)
sudo bash tests/run.sh     # also runs a real loop-device end-to-end erase+verify
```

The harness builds virtual disks (`truncate` + `losetup`) and fixture trees — it
never touches a physical drive.

## Status / roadmap

Implemented: identify, plan/apply, media-correct sanitize selection, verify,
certificate, recover/archive reuse, test harness. Next: recovery carving against
the `ddrescue` image (not the live drive), post-copy re-hash of archives, PDF
certificate, and native macOS (`diskutil`) / Windows (PowerShell) back-ends — or
a bootable Linux USB image as the cross-OS delivery.
