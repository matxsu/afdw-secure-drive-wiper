#!/usr/bin/env bash
# lib/certificate.sh — emit a NIST SP 800-88 style erasure certificate.
# SPDX-License-Identifier: MIT
#
# Writes two files to $DC_CERT_DIR:
#   requiem-cert-<serial-or-dev>-<stamp>.json   (machine-readable)
#   requiem-cert-<serial-or-dev>-<stamp>.txt    (human/printable)
# Intended as proof of sanitization (e.g. GDPR disposal, ITAD hand-off).
# It records what *actually* ran — it does not inflate the method claimed.

# dc_certificate  (uses DC_* globals set by the pipeline)
dc_certificate() {
  local dir="${DC_CERT_DIR:-${DC_ARCHIVE_DEST:-.}}"
  mkdir -p "$dir" 2>/dev/null || { dc_warn "cannot create cert dir $dir"; return 1; }
  local stamp id json txt
  stamp="$(date +%Y%m%d_%H%M%S)"
  id="${DC_SERIAL:-$(basename "$DC_DEV")}"
  json="$dir/requiem-cert-${id}-${stamp}.json"
  txt="$dir/requiem-cert-${id}-${stamp}.txt"

  local verify_ok="${DC_VERIFY_OK:-0}" result="INCOMPLETE"
  [[ "${DC_SAN_APPLIED:-0}" == "1" && "$verify_ok" == "1" ]] && result="PASS"
  [[ "${DC_DRYRUN:-0}" == "1" ]] && result="PLAN-ONLY (no data destroyed)"

  {
    echo '{'
    printf '  "tool": "requiem", "version": "%s",\n' "$REQUIEM_VERSION"
    printf '  "timestamp": "%s",\n' "$(date -Is)"
    printf '  "operator": "%s",\n' "$(printf '%s' "${DC_OPERATOR:-unknown}" | dc_json_escape)"
    printf '  "device": {"path": "%s", "by_id": "%s", "model": "%s", "serial": "%s", "size_bytes": %s, "media": "%s", "bus": "%s"},\n' \
      "$DC_DEV" "${DC_BYID:-}" "$(printf '%s' "${DC_MODEL:-}" | dc_json_escape)" "${DC_SERIAL:-}" "${DC_SIZE_BYTES:-0}" "${DC_MEDIA:-}" "${DC_TRAN:-}"
    printf '  "sanitize": {"method": "%s", "nist_800_88": "%s", "description": "%s", "applied": %s},\n' \
      "${DC_SAN_METHOD:-}" "${DC_SAN_NIST:-}" "$(printf '%s' "${DC_SAN_DESC:-}" | dc_json_escape)" "$([[ "${DC_SAN_APPLIED:-0}" == 1 ]] && echo true || echo false)"
    printf '  "verification": {"passed": %s, "notes": "%s"},\n' \
      "$([[ "$verify_ok" == 1 ]] && echo true || echo false)" "$(printf '%s' "${DC_VERIFY_NOTES:-}" | dc_json_escape)"
    printf '  "preserved": {"recovered_dir": "%s", "archived_dir": "%s"},\n' "${DC_RECOVER_DEST:-}" "${DC_ARCHIVE_SETDIR:-}"
    printf '  "result": "%s"\n' "$result"
    echo '}'
  } >"$json"

  {
    echo "============================================================"
    echo " DATA SANITIZATION CERTIFICATE  (NIST SP 800-88 Rev.1 style)"
    echo "============================================================"
    echo " Tool / version : requiem $REQUIEM_VERSION"
    echo " Date           : $(date -Is)"
    echo " Operator       : ${DC_OPERATOR:-unknown}"
    echo "------------------------------------------------------------"
    echo " Device path    : $DC_DEV"
    echo " Stable ID      : ${DC_BYID:-<none>}"
    echo " Model          : ${DC_MODEL:-unknown}"
    echo " Serial         : ${DC_SERIAL:-unknown}"
    echo " Capacity       : $DC_SIZE_H (${DC_SIZE_BYTES} bytes)"
    echo " Media / bus    : ${DC_MEDIA} / ${DC_TRAN:-unknown}"
    echo "------------------------------------------------------------"
    echo " Method         : ${DC_SAN_METHOD:-none}"
    echo " NIST category  : ${DC_SAN_NIST:-none}   (Clear / Purge / Destroy)"
    echo " Description    : ${DC_SAN_DESC:-}"
    echo " Applied        : $([[ "${DC_SAN_APPLIED:-0}" == 1 ]] && echo yes || echo 'no (plan only)')"
    echo " Verification   : $([[ "$verify_ok" == 1 ]] && echo PASS || echo 'not passed') ${DC_VERIFY_NOTES:+- $DC_VERIFY_NOTES}"
    echo "------------------------------------------------------------"
    echo " Data preserved before erase:"
    echo "   recovered -> ${DC_RECOVER_DEST:-<none>}"
    echo "   archived  -> ${DC_ARCHIVE_SETDIR:-<none>}"
    echo "------------------------------------------------------------"
    echo " RESULT: $result"
    echo "============================================================"
  } >"$txt"

  DC_CERT_JSON="$json"; DC_CERT_TXT="$txt"
  dc_info "Certificate: ${BLU}${txt}${RST}"
  dc_info "Certificate: ${BLU}${json}${RST}"
  return 0
}
