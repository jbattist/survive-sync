#!/usr/bin/env bash
# sync-pdfs.sh — download curated PDFs listed in pdf-sources.conf
# Skips files whose SHA-256 matches the stored hash record.
# Normalizes filenames per spec: category__source__title__year.pdf
#
# Called by sync-all.sh with:
#   sync-pdfs.sh --config <config_dir> --log <log_file>
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

CONF="${CONFIG_DIR}/pdf-sources.conf"
PDF_ROOT="/srv/offline/pdfs"
HASH_FILE="/srv/offline/metadata/sha256sums-pdfs.txt"
TMP_DIR="/tmp/survive-pdfs-$$"

added=0; skipped=0; failed=0

log()  { echo "[PDF][$(date '+%H:%M:%S')] $*" | tee -a "${LOG_FILE}"; }
fail() { log "FAIL $*"; (( failed++ )) || true; }

mkdir -p "${TMP_DIR}" "${PDF_ROOT}" "/srv/offline/metadata"
trap 'rm -rf "${TMP_DIR}"' EXIT

# Load existing hash records into associative array
declare -A KNOWN_HASHES
if [[ -f "${HASH_FILE}" ]]; then
    while IFS='  ' read -r hash path; do
        KNOWN_HASHES["${path}"]="${hash}"
    done < "${HASH_FILE}"
fi

save_hash() {
    local file="$1"
    local hash
    hash=$(sha256sum "${file}" | awk '{print $1}')
    # Update or append in hash file
    local rel_path="${file#/srv/offline/}"
    # Remove old entry if present
    sed -i "\|${rel_path}$|d" "${HASH_FILE}" 2>/dev/null || true
    echo "${hash}  ${rel_path}" >> "${HASH_FILE}"
}

# ── process each PDF ──────────────────────────────────────────────────────────
while IFS=$'\t' read -r url local_filename category_dir priority description; do
    # Skip comments and blank lines
    [[ -z "${url}" || "${url}" == \#* ]] && continue
    # Trim whitespace
    url="${url// /}"
    local_filename="${local_filename// /}"
    category_dir="${category_dir// /}"

    dest_dir="${PDF_ROOT}/${category_dir}"
    dest_file="${dest_dir}/${local_filename}"
    rel_path="${dest_file#/srv/offline/}"

    mkdir -p "${dest_dir}"

    # Skip if file exists and hash matches
    if [[ -f "${dest_file}" ]]; then
        stored_hash="${KNOWN_HASHES[${rel_path}]:-}"
        if [[ -n "${stored_hash}" ]]; then
            current_hash=$(sha256sum "${dest_file}" | awk '{print $1}')
            if [[ "${current_hash}" == "${stored_hash}" ]]; then
                log "SKIP ${local_filename}"
                (( skipped++ )) || true
                continue
            fi
        else
            # File exists but no hash record — compute and record it, skip download
            save_hash "${dest_file}"
            log "SKIP ${local_filename} (exists, hash recorded)"
            (( skipped++ )) || true
            continue
        fi
    fi

    log "ADD ${local_filename}"
    tmp_file="${TMP_DIR}/${local_filename}"

    # Download with wget; -q suppresses progress noise in logs
    # --tries=1: no retries — if the server is down/rate-limiting, fail fast and
    #   move on; the next sync will pick it up.  Retrying here just burns time.
    # --timeout=30: connection + read timeout per attempt
    # Note: pipe through tee to capture wget stderr to log, but check wget's exit
    #   code via PIPESTATUS[0] — tee always exits 0 and would mask wget failures.
    wget -q \
        --timeout=30 \
        --tries=1 \
        --user-agent="survive-sync/1.0" \
        -O "${tmp_file}" \
        "${url}" 2>&1 | tee -a "${LOG_FILE}" || true
    wget_rc=${PIPESTATUS[0]}

    if (( wget_rc != 0 )); then
        fail "${local_filename}: wget failed (exit ${wget_rc}) for ${url}"
        rm -f "${tmp_file}"
        continue
    fi

    # Basic sanity: must be > 10 KB and look like a PDF
    size=$(stat -c%s "${tmp_file}" 2>/dev/null || echo 0)
    header=$(head -c 4 "${tmp_file}" 2>/dev/null || echo "")
    if (( size < 10240 )) || [[ "${header}" != "%PDF" ]]; then
        fail "${local_filename}: not a valid PDF (${size} bytes) — server likely returned an error page"
        rm -f "${tmp_file}"
        continue
    fi

    mv "${tmp_file}" "${dest_file}"
    save_hash "${dest_file}"
    (( added++ )) || true

done < <(grep -v '^[[:space:]]*$' "${CONF}")

log "Done: added=${added} skipped=${skipped} failed=${failed}"
(( failed > 0 )) && exit 1 || exit 0
