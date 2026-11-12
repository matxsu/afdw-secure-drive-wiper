#!/usr/bin/env bash
# prewipe-recover.sh — Forensic RECOVERY stage for AFDW (runs before the wipe)
# SPDX-License-Identifier: MIT
#
# Purpose
# -------
# The archive phase (prewipe-archive.sh) rescues files that are still *live* on
# the filesystem. This stage goes deeper: it recovers what is important but NOT
# a normal readable file — deleted files, data on a damaged/failing drive, and
# (optionally) a full forensic image — BEFORE the drive is destroyed forever.
#
# Everything here is READ-ONLY on the source device. It only reads the raw block
# device / mounts read-only; it never writes to the drive being recovered.
#
# It orchestrates well-known FOSS forensic tools and degrades gracefully: if a
# tool is missing it says exactly what to install and continues with the rest.
#
# Three independent methods (each opt-in):
#   • IMAGE    — clone the whole device with GNU ddrescue (bad-sector aware) so
#                you can analyze it later at leisure. Falls back to dd.
#   • UNDELETE — filesystem-aware recovery of deleted files:
#                NTFS → ntfsundelete · ext2/3/4 → extundelete/ext4magic ·
#                any (via Sleuth Kit) → tsk_recover.
#   • CARVE    — signature-based carving that ignores the filesystem entirely:
#                photorec (preferred) / foremost / scalpel. Finds files even
#                when the directory structure is gone.
#
# Cross-platform media: the filesystem drivers above cover Windows (NTFS/exFAT),
# macOS (HFS+/APFS, best-effort) and Linux (ext/btrfs/xfs) drives attached to a
# Linux host. CARVE is filesystem-independent and works on anything.
#
# Environment variables
# ---------------------
#   AFDW_RECOVER          1|0  Master switch for this stage (default 0 = off).
#   AFDW_RECOVER_DEST     DIR  Output root (default: $AFDW_ARCHIVE_DEST/recovery
#                              else ${HOME}/old-archive/recovery).
#   AFDW_RECOVER_IMAGE    1|0  Make a ddrescue/dd clone of the device (default 0).
#   AFDW_RECOVER_UNDELETE 1|0  Filesystem-aware undelete of deleted files (default 1
#                              when AFDW_RECOVER=1).
#   AFDW_RECOVER_CARVE    1|0  Signature carving with photorec/foremost (default 0;
#                              it is thorough but slow and noisy).
#   AFDW_RECOVER_TYPES    LIST photorec/foremost file-type filter (e.g. "jpg,pdf,doc").
#   AFDW_RECOVER_MAX_GB   N    Refuse IMAGE if device > N GiB (0 = no limit, default 0).
#   AFDW_RECOVER_DRYRUN   1|0  Print the exact tool commands, run nothing (default 0).
#
# Return codes (pwr_run)
#   0  stage finished (recovered something, or nothing was requested) → safe to go on
#   10 a requested method failed hard (e.g. no space for the image) → caller aborts
#
# WARNING: recovery can take a long time and needs lots of free space at the
# destination (an image needs at least the full size of the source drive).

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -Eeuo pipefail
fi

############################################
#            Config resolution             #
############################################
pwr_cfg() {
  PWR_ENABLE="${AFDW_RECOVER:-0}"
  PWR_DEST="${AFDW_RECOVER_DEST:-${AFDW_ARCHIVE_DEST:-${HOME:-/root}/old-archive}/recovery}"
  PWR_IMAGE="${AFDW_RECOVER_IMAGE:-0}"
  PWR_UNDELETE="${AFDW_RECOVER_UNDELETE:-1}"
  PWR_CARVE="${AFDW_RECOVER_CARVE:-0}"
  PWR_TYPES="${AFDW_RECOVER_TYPES:-}"
  PWR_MAX_GB="${AFDW_RECOVER_MAX_GB:-0}"
  PWR_DRYRUN="${AFDW_RECOVER_DRYRUN:-0}"

  : "${RED:=}" "${GRN:=}" "${YLW:=}" "${BLU:=}" "${CYN:=}" "${BLD:=}" "${RST:=}"
  if [[ -t 1 && -z "${RST}" ]]; then
    RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLU=$'\e[34m'; CYN=$'\e[36m'; BLD=$'\e[1m'; RST=$'\e[0m'
  fi
}

pwr_info() { echo -e "${GRN}[recover]${RST} $*"; }
pwr_warn() { echo -e "${YLW}[recover]${RST} $*" >&2; }
pwr_err()  { echo -e "${RED}[recover]${RST} $*" >&2; }
pwr_have() { command -v "$1" >/dev/null 2>&1; }

# Run or (in dry-run) just print a command.
pwr_do() {
  if [[ "$PWR_DRYRUN" == "1" ]]; then
    echo "   [dry-run] $*"
    return 0
  fi
  eval "$@"
}

############################################
#        Method: full device image         #
############################################
pwr_image() {
  local device="$1" out="$PWR_DEST/image" dev base img map
  base="$(basename "$device")"
  img="$out/${base}.img"; map="$out/${base}.map"

  # Size guard.
  local bytes gib
  bytes="$(blockdev --getsize64 "$device" 2>/dev/null || echo 0)"
  gib=$(( bytes / 1024 / 1024 / 1024 ))
  if [[ "$PWR_MAX_GB" -gt 0 && $gib -gt "$PWR_MAX_GB" ]]; then
    pwr_warn "IMAGE skipped: device is ${gib} GiB > AFDW_RECOVER_MAX_GB=${PWR_MAX_GB}."
    return 0
  fi
  # Free-space guard at destination.
  local free_kb free_gb
  mkdir -p "$out" 2>/dev/null || { pwr_err "cannot create $out"; return 10; }
  free_kb="$(df -Pk "$out" | awk 'NR==2{print $4}')"; free_gb=$(( free_kb / 1024 / 1024 ))
  if [[ $free_gb -lt $gib ]]; then
    pwr_err "IMAGE needs ~${gib} GiB but destination has ${free_gb} GiB free. Aborting image."
    return 10
  fi

  if pwr_have ddrescue; then
    pwr_info "Imaging $device → $img with ddrescue (pass 1: fast, skip bad areas)..."
    pwr_do "ddrescue -n '$device' '$img' '$map'" || { pwr_err "ddrescue pass 1 failed"; return 10; }
    pwr_info "ddrescue pass 2: retry bad areas (-d -r3)..."
    pwr_do "ddrescue -d -r3 '$device' '$img' '$map'" || pwr_warn "ddrescue retry pass reported errors (partial image kept)."
  else
    pwr_warn "ddrescue not found (recommended for failing drives). Falling back to dd."
    pwr_info "Imaging $device → $img with dd (conv=noerror,sync)..."
    pwr_do "dd if='$device' of='$img' bs=8M conv=noerror,sync status=progress" || { pwr_err "dd imaging failed"; return 10; }
  fi
  pwr_info "Image written: ${BLU}${img}${RST} (mount later with: sudo mount -o ro,loop <img> /mnt)."
  return 0
}

############################################
#     Method: filesystem-aware undelete    #
############################################
pwr_undelete_part() {
  local part="$1" fstype out ok=0
  fstype="$(blkid -o value -s TYPE "$part" 2>/dev/null || echo unknown)"
  out="$PWR_DEST/undeleted/$(basename "$part")_${fstype}"
  mkdir -p "$out" 2>/dev/null || true
  pwr_info "Undelete on $part (fstype=$fstype) → $out"

  case "$fstype" in
    ntfs|ntfs3)
      if pwr_have ntfsundelete; then
        pwr_do "ntfsundelete '$part' -u -m '*' -d '$out'" && ok=1 || pwr_warn "ntfsundelete reported errors."
      else
        pwr_warn "Install 'ntfs-3g' (provides ntfsundelete) to recover deleted NTFS files."
      fi ;;
    ext2|ext3|ext4)
      if pwr_have extundelete; then
        pwr_do "extundelete '$part' --restore-all --output-dir '$out'" && ok=1 || pwr_warn "extundelete reported errors."
      elif pwr_have ext4magic; then
        pwr_do "ext4magic '$part' -r -d '$out'" && ok=1 || pwr_warn "ext4magic reported errors."
      else
        pwr_warn "Install 'extundelete' or 'ext4magic' to recover deleted ext2/3/4 files."
      fi ;;
    *)
      if pwr_have tsk_recover; then
        pwr_info "Using Sleuth Kit tsk_recover (filesystem-agnostic) for $fstype."
        pwr_do "tsk_recover -e '$part' '$out'" && ok=1 || pwr_warn "tsk_recover reported errors."
      else
        pwr_warn "No undelete tool for '$fstype'. Install 'sleuthkit' (tsk_recover) for broad support."
      fi ;;
  esac
  return 0
}

############################################
#     Method: signature carving (any FS)   #
############################################
pwr_carve() {
  local device="$1" out="$PWR_DEST/carved"
  mkdir -p "$out" 2>/dev/null || true
  if pwr_have photorec; then
    # photorec can run scripted: /log writes photorec.log, /d sets output dir,
    # /cmd <dev> <options>search runs non-interactively over the whole device.
    local opt="search"
    [[ -n "$PWR_TYPES" ]] && pwr_info "(photorec type filter '$PWR_TYPES' — configure via photorec.cfg if needed)"
    pwr_info "Carving $device with photorec → $out (this can take a long time)..."
    pwr_do "photorec /log /d '$out/recup_dir' /cmd '$device' '$opt'" || pwr_warn "photorec reported errors."
  elif pwr_have foremost; then
    pwr_info "Carving $device with foremost → $out ..."
    local t=""; [[ -n "$PWR_TYPES" ]] && t="-t '$PWR_TYPES'"
    pwr_do "foremost -i '$device' -o '$out/foremost' $t" || pwr_warn "foremost reported errors."
  elif pwr_have scalpel; then
    pwr_info "Carving $device with scalpel → $out ..."
    pwr_do "scalpel '$device' -o '$out/scalpel'" || pwr_warn "scalpel reported errors."
  else
    pwr_warn "No carver found. Install 'testdisk' (provides photorec) or 'foremost' for signature carving."
  fi
  return 0
}

############################################
#                 Orchestrate              #
############################################
pwr_run() {
  pwr_cfg
  local device="${1:-}"
  [[ -n "$device" ]] || { pwr_err "pwr_run: no device"; return 10; }
  if [[ "$PWR_ENABLE" != "1" ]]; then
    return 0   # stage disabled → silent, safe to continue
  fi
  [[ $EUID -eq 0 ]] || { pwr_err "recovery needs root (raw device access)."; return 10; }

  echo
  echo -e "${BLD}${CYN}=============== FORENSIC RECOVERY STAGE ===============${RST}"
  pwr_info "Source: ${BLD}${device}${RST}   Output: ${PWR_DEST}"
  pwr_info "Methods: image=${PWR_IMAGE} undelete=${PWR_UNDELETE} carve=${PWR_CARVE} (dry-run=${PWR_DRYRUN})"
  mkdir -p "$PWR_DEST" 2>/dev/null || { pwr_err "cannot create $PWR_DEST"; return 10; }

  local hard_fail=0

  # 1) IMAGE first (so later methods could even run against the image if desired).
  if [[ "$PWR_IMAGE" == "1" ]]; then
    pwr_image "$device" || hard_fail=1
  fi

  # 2) UNDELETE per partition.
  if [[ "$PWR_UNDELETE" == "1" ]]; then
    local -a parts=(); local n t
    while read -r n t; do [[ "$t" == "part" ]] && parts+=("/dev/$n"); done \
      < <(lsblk -rno NAME,TYPE "$device" 2>/dev/null | tail -n +2)
    [[ ${#parts[@]} -eq 0 ]] && parts=("$device")
    local p; for p in "${parts[@]}"; do pwr_undelete_part "$p"; done
  fi

  # 3) CARVE whole device.
  if [[ "$PWR_CARVE" == "1" ]]; then
    pwr_carve "$device"
  fi

  echo -e "${BLD}${CYN}======================================================${RST}"
  if [[ $hard_fail -eq 1 ]]; then
    pwr_err "A requested recovery method failed hard. Review before wiping."
    return 10
  fi
  pwr_info "Recovery stage complete. Review ${BLU}${PWR_DEST}${RST} before proceeding."
  return 0
}

############################################
#            Standalone runner             #
############################################
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  pwr_cfg
  AFDW_RECOVER=1
  DEV=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dest)     AFDW_RECOVER_DEST="$2"; shift 2;;
      --image)    AFDW_RECOVER_IMAGE=1; shift;;
      --carve)    AFDW_RECOVER_CARVE=1; shift;;
      --no-undelete) AFDW_RECOVER_UNDELETE=0; shift;;
      --types)    AFDW_RECOVER_TYPES="$2"; shift 2;;
      --dry-run)  AFDW_RECOVER_DRYRUN=1; shift;;
      -h|--help)  sed -n '2,60p' "$0"; exit 0;;
      /dev/*)     DEV="$1"; shift;;
      *)          echo "Unknown arg: $1" >&2; exit 1;;
    esac
  done
  [[ -n "$DEV" ]] || { echo "Usage: sudo $0 [--image] [--carve] [--no-undelete] [--types L] [--dest DIR] [--dry-run] /dev/sdX" >&2; exit 1; }
  pwr_run "$DEV"
  exit $?
fi
