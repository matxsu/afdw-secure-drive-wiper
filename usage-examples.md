# Here you will find copy & paste style commands that will teach you how to use AFDW. These are only some examples:

**Note:** The normal guided run (no flags) does an encrypted-noise fill, attempts controller discard (or zero-fallback), then creates a single partition and formats **exFAT** to mimic “factory fresh.”
You can customize behavior with the flags below.

---

## AFDW Usage Examples

### 1) Guided (interactive) run — “factory fresh” (noise + zero/discard + exFAT)

```bash
sudo ./afdw.sh
```

### 2) Non-interactive “factory fresh” (no prompts; be careful!)

```bash
sudo ./afdw.sh --device /dev/sdb --non-interactive --erase-confirm ERASE
```

### 3) Noise + Zero, but **skip formatting** (leave raw wiped media)

```bash
sudo ./afdw.sh --device /dev/sdb --no-format
```

Tip: add `--fast` to auto-skip noise if DISCARD/TRIM isn’t supported.

### 4) **Noise only** (no zero, no format)

```bash
sudo ./afdw.sh --device /dev/sdb --noise-only
```

If you want to format afterwards without wiping again, run:

```bash
sudo ./afdw.sh --device /dev/sdb --skip-wipe
```

### 5) **Zero only** (fastest single pass), no format

```bash
sudo ./afdw.sh --device /dev/sdb --zero-only
```

### 6) **Format only** (no wiping): make a single partition and exFAT

* MBR (msdos; default):

```bash
sudo ./afdw.sh --device /dev/sdb --skip-wipe --force-format
```

* GPT with Microsoft Basic Data + custom label:

```bash
sudo ./afdw.sh --device /dev/sdb --skip-wipe --gpt --label CUSTOM --label-text "ARCHIVE01" --force-format
```

### 7) Force (re)format even if a filesystem is detected

```bash
sudo ./afdw.sh --device /dev/sdb --force-format
```

### 8) Use GPT instead of MBR (applies to the format step)

```bash
sudo ./afdw.sh --device /dev/sdb --gpt
```

### 9) Custom exFAT volume label (A–Z0–9 up to 11 chars, uppercased)

```bash
sudo ./afdw.sh --device /dev/sdb --label CUSTOM --label-text "MEDIA_01"
```

### 10) Strict verification (fail the run if any verify step fails)

```bash
sudo ./afdw.sh --device /dev/sdb --strict
```

### 11) FAST mode (if DISCARD unsupported, auto-skip noise to save time)

```bash
sudo ./afdw.sh --device /dev/sdb --fast
```

### 12) Dry-run (show what would happen; no writes)

```bash
./afdw.sh --device /dev/sdb --dry-run
```

### 13) Dependency doctor (no writes) / Auto-install deps (Debian/Ubuntu)

```bash
./afdw.sh --doctor
sudo ./afdw.sh --install-deps
```

### 14) Power-off suppression (don’t power-off/eject at the end)

```bash
sudo ./afdw.sh --device /dev/sdb --no-poweroff
```

### 15) Danger: allow system disk (root) — only if you really know what you’re doing

```bash
sudo ./afdw.sh --device /dev/sda --genius
```

---

## Notes

* Replace `/dev/sdb` with the correct device (e.g., `/dev/mmcblk0` for SD cards).
  The interactive flow lists disks up front.
* If `pv` is installed, AFDW shows live **progress % and ETA** during long writes. Otherwise, `dd` shows a simpler progress counter.
* For a label only, or to switch MBR↔GPT without wiping, use **format-only** examples (`--skip-wipe`).

---

# Pre-wipe data preservation (recover → archive → wipe)

Before destroying anything, AFDW can run two optional stages so you never lose
something that mattered. The full order of a run is:

```
   [1] FORENSIC RECOVERY  (opt-in)  →  [2] ARCHIVE GATE  (default on)  →  [3] WIPE
   recover deleted files /            inventory live files, show         the irreversible
   image a failing drive /            what's there, copy the             erase you already
   carve by signature                 worth-keeping ones out             had before
```

Both stages are **read-only** on the target and are driven by `AFDW_*`
environment variables (see the headers of `prewipe-archive.sh` and
`prewipe-recover.sh`) or the `--archive-*` / `--recover*` flags.

### A) Just the archive gate (default) — see what's on a drive and keep the good bits

```bash
sudo ./afdw.sh --device /dev/sdb
# → scans /dev/sdb, prints an inventory, asks:
#   "Archive these files to ~/old-archive now? [y]es / [n]o / [a]bort"
# then wipes only after you've decided.
```

### B) Inventory only — look, don't copy, don't wipe yet

```bash
sudo ./afdw.sh --device /dev/sdb --archive-dry-run --skip-wipe
```

### C) Unattended: archive everything matched, then wipe, no prompts

```bash
sudo ./afdw.sh --device /dev/sdb --non-interactive --erase-confirm ERASE \
  --archive-auto --archive-dest /mnt/backup/old-drives
```

### D) Pick what counts as "worth keeping" (profiles)

```bash
# only documents; cap any single file at 200 MiB
sudo AFDW_ARCHIVE_MAX_FILE_MB=200 ./afdw.sh --device /dev/sdb --archive-profile documents

# everything, but skip caches and a total cap of 50 GiB
sudo AFDW_ARCHIVE_EXCLUDE='*/Cache/*:*/tmp/*' AFDW_ARCHIVE_MAX_TOTAL_GB=50 \
     ./afdw.sh --device /dev/sdb --archive-profile all
```

Profiles: `personal` (default = documents + media + keychains), `documents`,
`media`, `dev`, `all`, `none`. Add your own types with
`AFDW_ARCHIVE_INCLUDE="psd:ai:raw"`.

### E) Recover deleted files first, then archive, then wipe

```bash
sudo ./afdw.sh --device /dev/sdb --recover
```

### F) Full rescue of a drive you're about to retire (image + undelete + carve)

```bash
sudo ./afdw.sh --device /dev/sdb \
  --recover-image --recover-carve \
  --recover-dest /mnt/backup/rescue \
  --archive-auto
# [1] clones the whole disk with ddrescue, undeletes per-filesystem, and carves
#     by signature; [2] archives live files; [3] then (and only then) wipes.
```

### G) Recover without wiping (rescue only)

```bash
# the recovery module also runs standalone:
sudo ./prewipe-recover.sh --image --carve --dest /mnt/backup/rescue /dev/sdb
# or the archive module on its own:
sudo ./prewipe-archive.sh --profile personal --dest ~/old-archive /dev/sdb
```

### H) Preview every tool command without touching the drive

```bash
sudo ./afdw.sh --device /dev/sdb --recover-image --recover-carve --dry-run
# prints the exact ddrescue/photorec/ntfsundelete commands it *would* run.
```

---

## Sample inventory output

```
================ PRE-WIPE INVENTORY ================
Matched 1284 files, 7.43 G total:
   documents      412 files   318.44 M
   images         690 files   2.11 G
   video           41 files   4.87 G
   audio          128 files   126.90 M
   keys             3 files   11.20 K
===================================================
Largest matched files:
       1.93 G  /mnt/src/home/me/Videos/trip-2023.mp4
       ...
This is your LAST chance to keep this data before the wipe destroys it.
Archive these files to /home/me/old-archive now? [y]es / [n]o-continue-to-wipe / [a]bort-everything:
```

Every archive run also writes, next to the copied files:
`MANIFEST.tsv` (sha256 + size + mtime + path of each file) and
`ARCHIVE-SUMMARY.txt`.

---

## Cross-platform coverage (which drives this can read)

The preservation stages read the drive's **filesystem**, so a disk from any OS
works when attached to the Linux host running AFDW:

| Source OS | Filesystems handled | Needs (install if missing) |
|-----------|--------------------|----------------------------|
| Windows   | NTFS, exFAT, FAT32 | `ntfs-3g`, `exfatprogs` |
| macOS     | HFS+ (rw-RO), APFS (read, best-effort) | `hfsprogs`; `apfs-fuse` for APFS |
| Linux     | ext2/3/4, btrfs, xfs, f2fs, vfat | in-kernel |

Recovery tools used when present (install for best results):
`gddrescue`/`ddrescue` (imaging), `testdisk`+`photorec` (carving),
`ntfsundelete` (NTFS undelete), `extundelete`/`ext4magic` (ext undelete),
`sleuthkit` (`tsk_recover`, filesystem-agnostic undelete), `foremost`/`scalpel`
(carving). Each is optional — AFDW tells you what to install and continues.

> The AFDW wiper itself runs on **Linux** (it uses `/dev/sdX`, `lsblk`,
> `blkdiscard`). To wipe a Mac/Windows internal disk, boot the machine from a
> Linux USB (or attach the disk to a Linux box) and run AFDW there. Native
> macOS (`diskutil`) and Windows (PowerShell) wipers are on the roadmap.
