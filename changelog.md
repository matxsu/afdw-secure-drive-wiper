# Changelog

All notable changes to this project will be documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## \[Unreleased]

### Added — requiem pipeline (final form)

* **`requiem`**: a plan→apply decommissioning pipeline on top of AFDW —
  `identify → plan → recover → archive → sanitize → verify → certificate`.
  Default runs **plan only** (destroys nothing); `--apply` executes.
* **Stable-ID device identification + system-disk guard** (`lib/identify.sh`):
  resolves `/dev/disk/by-id`, serial, media class (nvme/sata-ssd/hdd/usb/mmc),
  refuses the running system disk, and re-verifies by serial before wiping.
* **Media-correct sanitization** (`lib/sanitize.sh`): `--method auto` chooses the
  most effective primitive per media — NVMe crypto-erase / ATA secure-erase
  (Purge) → TRIM → overwrite (Clear) — and is honest that USB bridges can't issue
  firmware erase. Explicit `--method` override supported.
* **Post-wipe verification** (`lib/verify.sh`) and a **NIST SP 800-88 certificate**
  (`lib/certificate.sh`, JSON + printable TXT) recording the method actually used.
* **Test harness** (`tests/run.sh`): 34 pure-logic/fixture assertions plus an
  optional real loop-device erase+verify under root. Never touches a physical disk.
* **`docs/REQUIEM.md`** documenting the pipeline, the media-correct method table and
  the forensic rationale.

### Added

* **Pre-wipe archive gate** (`prewipe-archive.sh`): before any destructive step,
  AFDW now inventories the target, shows a categorized report (documents / images
  / video / audio / keys), and offers to copy worth-keeping files to a safe
  destination — with a per-file `MANIFEST.tsv` (sha256) and summary. Driven by
  `AFDW_ARCHIVE_*` env vars and `--archive-*` / `--no-archive` flags. Default: on.
* **Forensic recovery stage** (`prewipe-recover.sh`): optional, runs first.
  Undeletes deleted files (NTFS → `ntfsundelete`, ext → `extundelete`/`ext4magic`,
  any → Sleuth Kit `tsk_recover`), clones failing drives with `ddrescue`/`dd`, and
  signature-carves with `photorec`/`foremost`/`scalpel`. Degrades gracefully and
  names the package to install when a tool is missing. Driven by `AFDW_RECOVER_*`
  env vars and `--recover*` flags. Default: off (opt-in).
* **Cross-platform media support**: read-only mounting now tries filesystem-aware
  drivers so drives from Windows (NTFS/exFAT), macOS (HFS+/APFS, best-effort) and
  Linux (ext/btrfs/xfs/f2fs) can all be scanned and preserved.
* Both stages are fully **read-only** on the source and honor `--dry-run`.

### Notes

* New run order: **recover (opt-in) → archive (default) → wipe**. If a requested
  recovery/archive step fails, AFDW aborts *before* wiping (nothing is destroyed).

---

## \[1.3.0] - 2025-09-17

### Added

* **Zero-pass fallback** triggered automatically if discard verification fails.
* **Progress/ETA** via `pv` for long writes (noise and zero passes), with automatic fallback to `dd status=progress` when `pv` isn’t available.
* **Pre-partition gap wipe** helper that’s **MBR/GPT-aware** and respects protective/primary/backup GPT areas.

# Previous version (1.2) had a big problem where it wasn't correctly formatting the drive in exFat. It was wiping fine but would hang on volume ID.
# This was because we were racing the kernel/udev (partition node not ready yet) and hadn’t set the partition type,
# so blkid/lsblk didn’t report exFAT reliably; we fixed that by adding the partprobe/udevadm settle/rescan loop and setting the type (MBR=0x07, GPT=msftdata).
# After that, the only remaining “fail” was our own verifier flagging the pre-partition gap while --skip-wipe was on, which we changed to SKIP
# (and only FAIL in --strict).
# In my pursuit to find that problem, I added some features and a more robust method of formatting and being mindful of different setups:

* **Verification suite**:

  * Protective **MBR 0x55AA** signature check.
  * **Pre-partition gap** erased check (now SKIP when `--skip-wipe`, FAIL only in `--strict`).
  * Middle/last MiB erased checks.
  * Partition table type matches requested **MBR/GPT**.
  * exFAT filesystem presence, **label** format, **UUID** format (####-####), **1MiB alignment**, and **readable sample** inside partition.
  * MBR **0x07** / GPT **Microsoft Basic Data (EBD0A0A2-…)** partition type validation.
* **Robust partition re-read** flow: `partprobe`, `udevadm settle`, `partx`, `kpartx` (if present), `blockdev --rereadpt`, and **MMC rescan** fallback.
* **Safety checks**: refuse to run in **WSL** or **containers**; refuse **system/root disk** unless `--genius`.
* **Non-interactive mode** with `--device` + `--erase-confirm ERASE`.
* **FAST mode** (`--fast`): if DISCARD unsupported, skip noise pass.
* **Skip/limit modes**: `--skip-wipe`, `--noise-only`, `--zero-only`.
* **Formatting controls**: `--no-format`, `--force-format`, `--gpt`, label modes (`--label RANDOM|CUSTOM`, `--label-text`).
* **mkfs selection**: prefer `mkfs.exfat` (exfatprogs), fallback to `mkexfatfs` (exfat-utils) with **SPC** computed from cluster size & sector size.
* **Cluster-size** auto-pick for exFAT based on partition size (16K/32K/64K/128K).
* **Post-format snapshot** (`lsblk`, `blkid`) and **EXFAT** signature verification.
* **JSON logging** (device metadata, modes, timings) + per-run **text verification log**.
* **Power-off/eject** on success via `udisksctl` (if available).
* **Doctor mode** (`--doctor`) to check environment/deps.
* **Auto-install** optional (`--install-deps`) for Debian/Ubuntu.
* **Trap cleanup** on signals (flush/sync before exit).

### Changed

* Dependency checks tightened; clearer guidance; optional auto-install.
* Partition creation standardizes on **1MiB start**; MBR type set via `sfdisk`; GPT `msftdata` flag set via `parted`.
* Label handling: RANDOM generator (A–Z0–9) or CUSTOM (sanitized, upcased, ≤11 chars).
* Exit codes clarified: **0** success, **2** when verification fails under `--strict`.
* Output styling consolidated under `info/warn/die`; color can be disabled with `--no-color`.

### Fixed

* Race conditions after partitioning by adding multiple re-read paths + MMC rescan.
* Correct **SPC** calculation for `mkexfatfs` when sector size ≠ 512.
* Accurate handling of **pre-partition gap** for both MBR and GPT disks.
* Ensured verification respects `--skip-wipe` (reports SKIP; only FAILs in `--strict`).

---

*(Previous releases for reference)*

## \[1.2] - 2025-09-12

### Added

* Improved dependency checks and clearer README instructions for first-time users.
* Enhanced unmount logic: recursive unmount + lazy fallback for stubborn mounts.
* Double-confirmation safety flow refined (full path + explicit `ERASE` keyword).
* Additional error handling and user feedback messages.

### Changed

* Reorganized and simplified code structure for readability.
* Adjusted script to run cleanly under `bash`.
* Updated README.md with usage instructions and quickstart notes.

---

## \[1.1] - 2025-09-10

### Added

* Flush and sync step before unmount to ensure all writes are committed.
* Initial README.md with TL;DR and usage overview.

### Changed

* Streamlined prompts and confirmations to reduce accidental misuse.
* Minor code cleanups and comments for maintainability.

---

## \[1.0] - 2025-09-08

### Added

* Initial release of **AFDW (Anti-Forensic Drive Wiper)**.
* Core functionality:

  * Detect and list disks.
  * Require full-path confirmation.
  * Securely wipe drives using multiple passes.
  * Basic unmounting routine.
* MIT license.
