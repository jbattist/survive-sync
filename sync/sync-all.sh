#!/usr/bin/env bash
# sync-all.sh — master orchestrator for the survive library sync agent
# Runs all content modules in sequence, then runs postprocess steps.
# Designed to be called by the survive-sync.service systemd unit.
#
# Usage:
#   sudo -u library /srv/offline/scripts/sync/sync-all.sh
#   systemctl start survive-sync.service
#
# Environment:
#   SYNC_MODULES  space-separated list of modules to run (default: all)
#                 e.g.  SYNC_MODULES="zim pdfs" sync-all.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$(cd "${SCRIPT_DIR}/../config" && pwd)"
POSTPROCESS_DIR="$(cd "${SCRIPT_DIR}/../postprocess" && pwd)"
OFFLINE_ROOT="/srv/offline"
LOG_DIR="${OFFLINE_ROOT}/logs"
LOG_FILE="${LOG_DIR}/sync-$(date +%Y-%m-%d).log"

# ── USB drive check ───────────────────────────────────────────────────────────
# All content lives on the USB drive.  Abort immediately if it is not mounted
# rather than filling the SD card or silently writing to the wrong place.
if ! mountpoint -q "${OFFLINE_ROOT}" 2>/dev/null; then
    echo "[$(date '+%H:%M:%S')] FATAL: ${OFFLINE_ROOT} is not mounted." >&2
    echo "[$(date '+%H:%M:%S')] Is the USB drive connected?" >&2
    echo "[$(date '+%H:%M:%S')] Check: systemctl status srv-offline.mount" >&2
    echo "[$(date '+%H:%M:%S')] To mount manually: systemctl start srv-offline.mount" >&2
    exit 1
fi

MODULES="${SYNC_MODULES:-zim pdfs books maps video}"

# ── sync portal files ─────────────────────────────────────────────────────────
# Keep the live portal up to date with whatever was deployed by install.sh.
# This means a `git pull && sudo bash install.sh` on the Pi automatically
# propagates updated portal files on the next sync run.
PORTAL_SRC="${SCRIPT_DIR}/../portal"
if [[ -d "${PORTAL_SRC}" ]]; then
    mkdir -p "${OFFLINE_ROOT}/portal"
    cp -r "${PORTAL_SRC}/." "${OFFLINE_ROOT}/portal/"
fi

# ── helpers ───────────────────────────────────────────────────────────────────
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "${LOG_FILE}"; }
hr()  { echo "────────────────────────────────────────────────" | tee -a "${LOG_FILE}"; }

# ── preflight ─────────────────────────────────────────────────────────────────
mkdir -p "${LOG_DIR}"
log "╔══════════════════════════════════════════════════╗"
log "║  SURVIVE SYNC  $(date '+%Y-%m-%d %H:%M:%S')           ║"
log "╚══════════════════════════════════════════════════╝"
log "Modules to run: ${MODULES}"
log "Log: ${LOG_FILE}"
hr

# Check for internet connectivity (required for all download modules)
if ! curl -sf --max-time 10 https://download.kiwix.org/ >/dev/null 2>&1; then
    log "ERROR: No internet connectivity detected.  Aborting sync."
    log "To run in offline-only mode, use SYNC_MODULES='' sync-all.sh"
    exit 1
fi
log "Internet connectivity: OK"
hr

# ── run modules ───────────────────────────────────────────────────────────────
declare -A MODULE_STATUS
declare -A MODULE_DURATION

for module in ${MODULES}; do
    module_script="${SCRIPT_DIR}/sync-${module}.sh"
    if [[ ! -x "${module_script}" ]]; then
        log "WARN: Module script not found or not executable: ${module_script} — skipping"
        MODULE_STATUS["${module}"]="SKIP"
        continue
    fi

    log "▶  Starting module: ${module}"
    t_start=$(date +%s)

    if bash "${module_script}" \
            --config "${CONFIG_DIR}" \
            --log "${LOG_FILE}"; then
        MODULE_STATUS["${module}"]="OK"
    else
        MODULE_STATUS["${module}"]="FAIL"
        log "ERROR: Module ${module} exited with non-zero status"
    fi

    t_end=$(date +%s)
    MODULE_DURATION["${module}"]=$(( t_end - t_start ))
    log "◀  Finished module: ${module} [${MODULE_DURATION[${module}]}s]"
    hr
done

# ── postprocess ───────────────────────────────────────────────────────────────
log "▶  Running postprocess steps"

for pp in update-kiwix-library update-catalog rebuild-indexes; do
    pp_script="${POSTPROCESS_DIR}/${pp}.sh"
    if [[ -x "${pp_script}" ]]; then
        log "   Running ${pp}..."
        bash "${pp_script}" 2>&1 | tee -a "${LOG_FILE}" || \
            log "WARN: ${pp} failed (non-fatal)"
    fi
done
hr

# ── restart services ──────────────────────────────────────────────────────────
log "▶  Restarting content services"
for svc in kiwix.service calibre-server.service caddy.service mbtileserver.service; do
    if systemctl is-active --quiet "${svc}" 2>/dev/null; then
        # library user has NOPASSWD sudo rights for these exact restart commands
        sudo systemctl restart "${svc}" && log "   Restarted ${svc}" || \
            log "   WARN: Failed to restart ${svc}"
    else
        log "   SKIP restart ${svc} (not active)"
    fi
done
hr

# ── summary ───────────────────────────────────────────────────────────────────
log "SYNC COMPLETE — Summary:"
for module in ${MODULES}; do
    status="${MODULE_STATUS[${module}]:-SKIP}"
    duration="${MODULE_DURATION[${module}]:-0}"
    log "  ${module}: ${status} (${duration}s)"
done
log "Finished at $(date '+%Y-%m-%d %H:%M:%S')"
