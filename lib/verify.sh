#!/usr/bin/env bash
# lib/verify.sh — post-sanitize verification by sampling the raw device.
# SPDX-License-Identifier: MIT
#
# Reads small samples from the start, middle and end of the device and checks
# that they match the expected post-wipe pattern:
#   • overwrite-zero / TRIM-that-zeroes → all 0x00
#   • overwrite-random / crypto-erase   → high entropy (not constant, not text)
# Populates DC_VERIFY_OK (1/0) and DC_VERIFY_NOTES.

# Fraction of non-zero bytes in a sample read at MiB offset $2 from $1.
dc_ver_nonzero_at() {
  local dev="$1" off="$2"
  dd if="$dev" bs=1M skip="$off" count=1 status=none 2>/dev/null | tr -d '\000' | wc -c
}
# Count distinct byte values in a sample (entropy proxy): >200 ≈ random-looking.
dc_ver_distinct_at() {
  local dev="$1" off="$2"
  dd if="$dev" bs=1M skip="$off" count=1 status=none 2>/dev/null \
    | od -An -tu1 | tr ' ' '\n' | awk 'NF' | sort -un | wc -l
}

# dc_verify <device> <expected: zero|entropy>
dc_verify() {
  local dev="$1" expect="${2:-zero}"
  DC_VERIFY_OK=1; DC_VERIFY_NOTES=""
  local bytes mib mid last
  bytes="$(blockdev --getsize64 "$dev" 2>/dev/null || stat -c %s "$dev" 2>/dev/null || echo 0)"
  mib=$(( bytes / 1024 / 1024 ))
  [[ $mib -lt 3 ]] && { DC_VERIFY_OK=0; DC_VERIFY_NOTES="device too small to sample"; return 1; }
  mid=$(( mib / 2 )); last=$(( mib - 1 ))

  local o nz dcount pos label
  for pos in 0 "$mid" "$last"; do
    case "$pos" in 0) label=start;; "$mid") label=middle;; *) label=end;; esac
    nz="$(dc_ver_nonzero_at "$dev" "$pos")"
    if [[ "$expect" == "zero" ]]; then
      if [[ "${nz:-1}" -eq 0 ]]; then
        DC_VERIFY_NOTES+="[$label:00 OK] "
      else
        DC_VERIFY_OK=0; DC_VERIFY_NOTES+="[$label:NONZERO FAIL] "
      fi
    else
      dcount="$(dc_ver_distinct_at "$dev" "$pos")"
      if [[ "${dcount:-0}" -ge 200 ]]; then
        DC_VERIFY_NOTES+="[$label:entropy OK ($dcount/256)] "
      else
        DC_VERIFY_OK=0; DC_VERIFY_NOTES+="[$label:low-entropy FAIL ($dcount/256)] "
      fi
    fi
  done
  [[ $DC_VERIFY_OK -eq 1 ]] && return 0 || return 1
}
