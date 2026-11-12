#!/usr/bin/env bash
# tests/run.sh — requiem test harness. Exercises the pure logic on fixtures and,
# when run as root with losetup available, on real loop-device virtual disks.
# Never touches a physical drive. Exit non-zero if any assertion fails.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/requiem_tests.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   - $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL - $1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1 :: [$2]"; fi; }

export DC_NO_COLOR=1 NO_COLOR=1
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
source "$ROOT/lib/identify.sh"
source "$ROOT/lib/sanitize.sh"
source "$ROOT/lib/verify.sh"
source "$ROOT/lib/certificate.sh"

echo "== syntax: all scripts parse =="
for f in "$ROOT"/requiem "$ROOT"/prewipe-archive.sh "$ROOT"/prewipe-recover.sh "$ROOT"/lib/*.sh; do
  if bash -n "$f"; then ok "syntax $(basename "$f")"; else bad "syntax $(basename "$f")"; fi
done

echo "== dc_human =="
check "human 1024 = 1.00 K" '[[ "$(dc_human 1024)" == "1.00 K" ]]'
check "human 0 = 0.00 B"    '[[ "$(dc_human 0)" == "0.00 B" ]]'
check "human 1610612736 = 1.50 G" '[[ "$(dc_human 1610612736)" == "1.50 G" ]]'

echo "== sanitize method selection per media (auto) =="
# Stub capability probes so selection is deterministic without hardware.
dc_san_nvme_supports(){ return "${STUB_NVME:-1}"; }   # 0 = supported
dc_san_blkdiscard_ok(){ return "${STUB_TRIM:-1}"; }    # 0 = supported
dc_san_ata_secure_ok(){ return "${STUB_ATA:-1}"; }     # 0 = supported
DC_DEV=/dev/nvme9n1

DC_MEDIA=nvme-ssd; STUB_NVME=0; dc_sanitize_select auto
check "nvme+crypto-cap → nvme-crypto-erase" '[[ "$DC_SAN_METHOD" == "nvme-crypto-erase" && "$DC_SAN_NIST" == "Purge" ]]'

DC_MEDIA=nvme-ssd; STUB_NVME=1; STUB_TRIM=0; dc_sanitize_select auto
check "nvme no-fw but TRIM → blkdiscard-trim" '[[ "$DC_SAN_METHOD" == "blkdiscard-trim" ]]'

DC_MEDIA=nvme-ssd; STUB_NVME=1; STUB_TRIM=1; dc_sanitize_select auto
check "nvme no-fw no-TRIM → overwrite-random" '[[ "$DC_SAN_METHOD" == "overwrite-random" ]]'

DC_MEDIA=sata-ssd; STUB_ATA=0; dc_sanitize_select auto
check "sata-ssd+ata → ata-secure-erase (Purge)" '[[ "$DC_SAN_METHOD" == "ata-secure-erase" && "$DC_SAN_NIST" == "Purge" ]]'

DC_MEDIA=hdd; dc_sanitize_select auto
check "hdd → overwrite-zero" '[[ "$DC_SAN_METHOD" == "overwrite-zero" ]]'

DC_MEDIA=usb; STUB_TRIM=1; dc_sanitize_select auto
check "usb no-TRIM → overwrite-random" '[[ "$DC_SAN_METHOD" == "overwrite-random" ]]'

DC_MEDIA=usb; STUB_TRIM=0; dc_sanitize_select auto
check "usb+TRIM → blkdiscard-trim" '[[ "$DC_SAN_METHOD" == "blkdiscard-trim" ]]'

echo "== sanitize explicit method overrides =="
dc_sanitize_select crypto;          check "explicit crypto"        '[[ "$DC_SAN_METHOD" == "nvme-crypto-erase" ]]'
dc_sanitize_select secure-erase;    check "explicit secure-erase"  '[[ "$DC_SAN_METHOD" == "ata-secure-erase" ]]'
dc_sanitize_select trim;            check "explicit trim"          '[[ "$DC_SAN_METHOD" == "blkdiscard-trim" ]]'
dc_sanitize_select overwrite-zero;  check "explicit overwrite-zero" '[[ "$DC_SAN_METHOD" == "overwrite-zero" ]]'

echo "== verify: zero vs entropy patterns (on fixture files) =="
head -c 3200000 /dev/zero > "$TMP/zeros.bin"
head -c 3200000 /dev/urandom > "$TMP/rand.bin"
set +e
dc_verify "$TMP/zeros.bin" zero;    check "zeros pass as zero"     '[[ "$DC_VERIFY_OK" == "1" ]]'
dc_verify "$TMP/rand.bin"  zero;    check "random fails as zero"   '[[ "$DC_VERIFY_OK" == "0" ]]'
dc_verify "$TMP/rand.bin"  entropy; check "random pass as entropy" '[[ "$DC_VERIFY_OK" == "1" ]]'
dc_verify "$TMP/zeros.bin" entropy; check "zeros fail as entropy"  '[[ "$DC_VERIFY_OK" == "0" ]]'
set -e

echo "== certificate: JSON + TXT produced with key fields =="
DC_DEV=/dev/sdZ DC_BYID=/dev/disk/by-id/wwn-0xTEST DC_MODEL="TEST MODEL" DC_SERIAL=SER123 \
DC_SIZE_BYTES=512000000000 DC_SIZE_H="476.84 G" DC_MEDIA=usb DC_TRAN=usb \
DC_SAN_METHOD=blkdiscard-trim DC_SAN_NIST=Clear DC_SAN_DESC="TRIM" DC_SAN_APPLIED=1 \
DC_VERIFY_OK=1 DC_VERIFY_NOTES="[start:00 OK]" DC_OPERATOR="tester" DC_DRYRUN=0 \
DC_CERT_DIR="$TMP/cert" dc_certificate >/dev/null 2>&1
check "cert json exists"  '[[ -f "$DC_CERT_JSON" ]]'
check "cert txt exists"   '[[ -f "$DC_CERT_TXT" ]]'
check "cert json has serial" 'grep -q "SER123" "$DC_CERT_JSON"'
check "cert json valid-ish (jq)" '! command -v jq >/dev/null || jq . "$DC_CERT_JSON" >/dev/null'
check "cert txt says PASS" 'grep -q "RESULT: PASS" "$DC_CERT_TXT"'

echo "== archive module: scan/categorize/copy on a fixture tree =="
source "$ROOT/prewipe-archive.sh"
pwa_cfg
FS="$TMP/fs"; mkdir -p "$FS/home/u/Documents" "$FS/usr/share" "$FS/home/u/.cache"
echo hi > "$FS/home/u/Documents/a.pdf"
echo hi > "$FS/home/u/Documents/b.txt"
head -c 4096 /dev/urandom > "$FS/home/u/photo.jpg"
echo sys > "$FS/usr/share/doc.pdf"      # must be pruned (system tree)
echo junk > "$FS/home/u/.cache/x.pdf"   # must be pruned (cache)
pwa_build_find_expr "$(pwa_profile_exts personal)"
SCAN="$TMP/scan"; : > "$SCAN"; pwa_scan_mount "$FS" "$SCAN"
n="$(wc -l < "$SCAN")"
check "archive scan finds 3 user files (prunes usr + cache)" '[[ "$n" -eq 3 ]]'
check "archive scan excluded /usr" '! grep -q "/usr/share/doc.pdf" "$SCAN"'
check "archive scan excluded .cache" '! grep -q "/.cache/" "$SCAN"'

echo "== optional: loop-device end-to-end (root + losetup) =="
if [[ ${EUID:-$(id -u)} -eq 0 ]] && command -v losetup >/dev/null 2>&1; then
  IMG="$TMP/disk.img"; truncate -s 64M "$IMG"
  LOOP="$(losetup --find --show "$IMG" 2>/dev/null)"
  if [[ -n "${LOOP:-}" ]]; then
    DC_DEV="$LOOP"; dc_sanitize_select overwrite-zero
    DC_DRYRUN=0; set +e; dc_sanitize_apply; dc_verify "$LOOP" zero; set -e
    check "loop overwrite-zero verifies" '[[ "$DC_VERIFY_OK" == "1" ]]'
    losetup -d "$LOOP" 2>/dev/null || true
  else
    echo "  skip - could not attach loop device"
  fi
else
  echo "  skip - not root or losetup unavailable (pure-logic tests still ran)"
fi

echo
echo "==================================================="
echo "  RESULT: $PASS passed, $FAIL failed"
echo "==================================================="
[[ $FAIL -eq 0 ]]
