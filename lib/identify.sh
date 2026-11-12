#!/usr/bin/env bash
# lib/identify.sh — resolve a target device, classify its media, and guard the
# system disk. Populates DC_* globals used by the rest of the pipeline.
# SPDX-License-Identifier: MIT

# dc_identify <device>
# Sets:
#   DC_DEV        canonical device path (e.g. /dev/sda, /dev/nvme0n1)
#   DC_BYID       a stable /dev/disk/by-id/* path (or "" if none)
#   DC_MODEL DC_SERIAL DC_SIZE_BYTES DC_SIZE_H DC_ROTA DC_TRAN
#   DC_MEDIA      one of: nvme-ssd | sata-ssd | hdd | usb | mmc | unknown
#   DC_IS_SYSTEM  1 if the device holds the running system, else 0
#   DC_FS_LIST    space-separated filesystem types found on its partitions
dc_identify() {
  local dev="$1"
  [[ -n "$dev" ]] || { dc_err "dc_identify: no device"; return 1; }
  [[ -b "$dev" ]] || { dc_err "Not a block device: $dev"; return 1; }
  DC_DEV="$dev"

  DC_MODEL="$(lsblk -dno MODEL "$dev" 2>/dev/null | sed 's/[[:space:]]*$//' || true)"
  DC_SERIAL="$(lsblk -dno SERIAL "$dev" 2>/dev/null | tr -d '[:space:]' || true)"
  DC_TRAN="$(lsblk -dno TRAN "$dev" 2>/dev/null | tr -d '[:space:]' || true)"
  DC_ROTA="$(lsblk -dno ROTA "$dev" 2>/dev/null | tr -d '[:space:]' || echo 0)"
  DC_SIZE_BYTES="$(blockdev --getsize64 "$dev" 2>/dev/null || echo 0)"
  DC_SIZE_H="$(dc_human "$DC_SIZE_BYTES")"

  # Stable by-id path (prefer wwn-, then any that resolves to this device).
  DC_BYID=""
  local link tgt base
  base="$(basename "$dev")"
  if [[ -d /dev/disk/by-id ]]; then
    while read -r link; do
      tgt="$(readlink -f "/dev/disk/by-id/$link" 2>/dev/null || true)"
      [[ "$(basename "$tgt")" == "$base" ]] || continue
      case "$link" in
        wwn-*) DC_BYID="/dev/disk/by-id/$link"; break ;;   # prefer WWN
        *)     [[ -z "$DC_BYID" ]] && DC_BYID="/dev/disk/by-id/$link" ;;
      esac
    done < <(ls -1 /dev/disk/by-id 2>/dev/null)
  fi

  # Filesystems present (helps the archive/recover stages and the report).
  DC_FS_LIST="$(lsblk -rno FSTYPE "$dev" 2>/dev/null | awk 'NF' | sort -u | tr '\n' ' ' | sed 's/ *$//')"

  # Media classification.
  case "$DC_TRAN" in
    nvme)        DC_MEDIA="nvme-ssd" ;;
    sata|ata)    [[ "$DC_ROTA" == "0" ]] && DC_MEDIA="sata-ssd" || DC_MEDIA="hdd" ;;
    usb)         DC_MEDIA="usb" ;;
    mmc|sd)      DC_MEDIA="mmc" ;;
    *)           if [[ "$base" == nvme* ]]; then DC_MEDIA="nvme-ssd";
                 elif [[ "$base" == mmcblk* ]]; then DC_MEDIA="mmc";
                 elif [[ "$DC_ROTA" == "0" ]]; then DC_MEDIA="sata-ssd";
                 else DC_MEDIA="unknown"; fi ;;
  esac

  # System-disk detection: the disk backing "/" (or any critical mount).
  DC_IS_SYSTEM=0
  local rootsrc rootdisk m
  rootsrc="$(findmnt -no SOURCE / 2>/dev/null || true)"
  if [[ -n "$rootsrc" ]]; then
    rootdisk="$(lsblk -no PKNAME "$rootsrc" 2>/dev/null | head -n1 || true)"
    [[ -n "$rootdisk" ]] && [[ "/dev/$rootdisk" == "$dev" ]] && DC_IS_SYSTEM=1
  fi
  # Also flag if any partition is mounted at a system path.
  if [[ $DC_IS_SYSTEM -eq 0 ]]; then
    while read -r m; do
      case "$m" in
        /|/boot|/boot/efi|/usr|/var|/home|/nix|/etc) DC_IS_SYSTEM=1; break ;;
      esac
    done < <(lsblk -rno MOUNTPOINT "$dev" 2>/dev/null | awk 'NF')
  fi
  return 0
}

# Pretty one-block summary of the identified device.
dc_identify_print() {
  echo -e "   ${BLD}Device:${RST}   $DC_DEV"
  echo -e "   ${BLD}By-id:${RST}    ${DC_BYID:-<none>}"
  echo -e "   ${BLD}Model:${RST}    ${DC_MODEL:-unknown}   ${BLD}Serial:${RST} ${DC_SERIAL:-unknown}"
  echo -e "   ${BLD}Size:${RST}     $DC_SIZE_H (${DC_SIZE_BYTES} bytes)"
  echo -e "   ${BLD}Bus:${RST}      ${DC_TRAN:-unknown}   ${BLD}Rotational:${RST} $DC_ROTA   ${BLD}Media:${RST} $DC_MEDIA"
  echo -e "   ${BLD}Filesystems:${RST} ${DC_FS_LIST:-<none>}"
  if [[ "$DC_IS_SYSTEM" == "1" ]]; then
    echo -e "   ${RED}${BLD}*** THIS IS (part of) THE RUNNING SYSTEM DISK ***${RST}"
  fi
}

# Re-verify, right before a destructive op, that the device still matches the
# serial captured earlier (defends against device-letter reshuffling).
dc_identify_reverify() {
  local dev="$1" expect_serial="$2" now
  now="$(lsblk -dno SERIAL "$dev" 2>/dev/null | tr -d '[:space:]' || true)"
  [[ -z "$expect_serial" ]] && return 0
  [[ "$now" == "$expect_serial" ]] || {
    dc_err "Device $dev serial changed ('$now' != expected '$expect_serial'). Aborting for safety."
    return 1
  }
  return 0
}
