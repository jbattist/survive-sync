#!/usr/bin/env bash
# sync-zim.sh — download Kiwix ZIM files listed in zim-list.conf
# Checks the Kiwix download server directory listing for each slug,
# compares against locally installed files, downloads only if newer.
#
# Called by sync-all.sh with:
#   sync-zim.sh --config <config_dir> --log <log_file>
set -euo pipefail

# ── arg parsing ───────────────────────────────────────────────────────────────
CONFIG_DIR="/srv/offline/scripts/config"
LOG_FILE="/srv/offline/logs/sync-$(date +%Y-%m-%d).log"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --config) CONFIG_DIR="$2"; shift 2 ;;
        --log)    LOG_FILE="$2";   shift 2 ;;
        *) shift ;;
    esac
done

CONF="${CONFIG_DIR}/zim-list.conf"
ZIM_DIR="/srv/offline/kiwix/zim"
KIWIX_BASE="https://download.kiwix.org/zim"

added=0; skipped=0; failed=0

log()  { echo "[ZIM][$(date '+%H:%M:%S')] $*" | tee -a "${LOG_FILE}"; }
fail() { log "FAIL $*"; (( failed++ )) || true; }

mkdir -p "${ZIM_DIR}"

if [[ ! -f "${CONF}" ]]; then
    log "ERROR: Config not found: ${CONF}"
    exit 1
fi

# ── process each slug ─────────────────────────────────────────────────────────
while IFS='|' read -r slug subdir description; do
    # strip whitespace, skip comments and blank lines
    slug="${slug// /}"
    subdir="${subdir// /}"
    [[ -z "${slug}" || "${slug}" == \#* ]] && continue

    log "Checking ${slug} (subdir: ${subdir})"

    dir_url="${KIWIX_BASE}/${subdir}/"

    # Fetch directory listing and find newest file matching the slug
    remote_filename=$(
        curl -sf --max-time 30 "${dir_url}" 2>/dev/null \
        | grep -oP "${slug}_[0-9]{4}-[0-9]{2}\.zim(?=[^.])" 2>/dev/null \
        | sort -r \
        | head -1
    ) || true

    # Fallback: broader grep if the versioned pattern didn't match
    if [[ -z "${remote_filename}" ]]; then
        remote_filename=$(
            curl -sf --max-time 30 "${dir_url}" 2>/dev/null \
            | grep -oP "\"${slug}[^\"]*\.zim\"" \
            | tr -d '"' \
            | sort -r \
            | head -1
        ) || true
    fi

    if [[ -z "${remote_filename}" ]]; then
        fail "${slug}: no matching file found at ${dir_url}"
        continue
    fi

    local_file="${ZIM_DIR}/${remote_filename}"

    # Skip if we already have this exact filename (same version)
    if [[ -f "${local_file}" ]]; then
        log "SKIP ${slug}: ${remote_filename} already present"
        (( skipped++ )) || true
        continue
    fi

    # Remove old versions of this slug before downloading the new one
    old_files=( "${ZIM_DIR}/${slug}"*.zim )
    for old in "${old_files[@]}"; do
        [[ -f "${old}" ]] && { log "  Removing old version: $(basename "${old}")"; rm -f "${old}"; }
    done

    log "ADD ${slug}: downloading ${remote_filename} (~may be large)"
    download_url="${dir_url}${remote_filename}"

    aria2c \
        --dir="${ZIM_DIR}" \
        --out="${remote_filename}" \
        --continue=true \
        --max-connection-per-server=4 \
        --split=4 \
        --file-allocation=none \
        --retry-wait=10 \
        --max-tries=5 \
        --console-log-level=warn \
        "${download_url}" \
    && (( added++ )) || true

    # Verify the download completed (aria2c may exit 0 on partial)
    if [[ ! -s "${local_file}" ]]; then
        fail "${slug}: download produced empty/missing file"
        rm -f "${local_file}"
    fi

done < <(grep -v '^[[:space:]]*$' "${CONF}")

log "Done: added=${added} skipped=${skipped} failed=${failed}"
(( failed > 0 )) && exit 1 || exit 0
