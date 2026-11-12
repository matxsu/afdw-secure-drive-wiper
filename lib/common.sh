#!/usr/bin/env bash
# lib/common.sh — shared helpers for decom (decommission) toolkit
# SPDX-License-Identifier: MIT
# Sourced by decom.sh and the other lib/*.sh modules. Defines no side effects
# beyond function/variable definitions, so it is safe to source under set -e.

# ---- version -------------------------------------------------------------
DECOM_VERSION="2.0.0-dev"

# ---- colors (respect NO_COLOR and non-tty) -------------------------------
dc_init_colors() {
  if [[ -t 1 && -z "${NO_COLOR:-}" && "${DC_NO_COLOR:-0}" != "1" ]]; then
    RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLU=$'\e[34m'
    MAG=$'\e[35m'; CYN=$'\e[36m'; BLD=$'\e[1m'; DIM=$'\e[2m'; RST=$'\e[0m'
  else
    RED=; GRN=; YLW=; BLU=; MAG=; CYN=; BLD=; DIM=; RST=
  fi
}
dc_init_colors

# ---- logging -------------------------------------------------------------
# A run-wide log file can be set by the orchestrator via DC_LOG.
dc_logline() { [[ -n "${DC_LOG:-}" ]] && printf '%s %s\n' "$(date -Is)" "$*" >>"$DC_LOG" 2>/dev/null || true; }
dc_info() { echo -e "${GRN}==>${RST} $*"; dc_logline "INFO  $*"; }
dc_step() { echo -e "\n${BLD}${CYN}### $* ###${RST}"; dc_logline "STEP  $*"; }
dc_warn() { echo -e "${YLW}WARN:${RST} $*" >&2; dc_logline "WARN  $*"; }
dc_err()  { echo -e "${RED}ERROR:${RST} $*" >&2; dc_logline "ERROR $*"; }
dc_die()  { dc_err "$*"; exit 1; }
dc_have() { command -v "$1" >/dev/null 2>&1; }

# ---- dry-run aware command runner ----------------------------------------
# DC_DRYRUN=1 → print the command instead of running it. Returns the command's
# status when run, or 0 when printed.
dc_run() {
  if [[ "${DC_DRYRUN:-0}" == "1" ]]; then
    echo -e "   ${DIM}[plan] $*${RST}"
    return 0
  fi
  dc_logline "RUN   $*"
  eval "$@"
}

# ---- helpers -------------------------------------------------------------
dc_human() {
  awk -v b="${1:-0}" 'function h(x,  u,i){u="BKMGTPE";i=0;while(x>=1024&&i<6){x/=1024;i++}return sprintf("%.2f %s",x,substr(u,i+1,1))}BEGIN{print h(b)}'
}

dc_require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || dc_die "This action needs root (sudo)."; }

# Ask the user to type an exact token to proceed. $1 = prompt, $2 = required token.
dc_confirm_token() {
  local prompt="$1" token="$2" ans
  if [[ "${DC_ASSUME_YES:-0}" == "1" ]]; then return 0; fi
  [[ -t 0 ]] || { dc_err "Confirmation required but no TTY (use --yes to bypass, carefully)."; return 1; }
  echo -ne "$prompt"
  read -r ans
  [[ "$ans" == "$token" ]]
}

# JSON string escaper (minimal).
dc_json_escape() { sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' | tr -d '\n'; }
