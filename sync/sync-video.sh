#!/usr/bin/env bash
# sync-video.sh — download videos using yt-dlp from video-list.conf
# Uses yt-dlp's archive file to skip already-downloaded content.
# Max resolution: 720p to keep storage reasonable.
#
# Called by sync-all.sh with:
#   sync-video.sh --config <config_dir> --log <log_file>
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

CONF="${CONFIG_DIR}/video-list.conf"
VIDEO_ROOT="/srv/offline/video"
ARCHIVE_FILE="${VIDEO_ROOT}/.yt-dlp-archive.txt"

added=0; skipped=0; failed=0

log()  { echo "[VIDEO][$(date '+%H:%M:%S')] $*" | tee -a "${LOG_FILE}"; }
fail() { log "FAIL $*"; (( failed++ )) || true; }

# ── locate yt-dlp ─────────────────────────────────────────────────────────────
YTDLP=$(command -v yt-dlp 2>/dev/null || command -v yt_dlp 2>/dev/null || echo "")
if [[ -z "${YTDLP}" ]]; then
    log "ERROR: yt-dlp not found in PATH"
    log "       Install: sudo pacman -S yt-dlp  OR  pip install yt-dlp"
    exit 1
fi

mkdir -p "${VIDEO_ROOT}" "$(dirname "${ARCHIVE_FILE}")"
touch "${ARCHIVE_FILE}"

# Common yt-dlp options
YTDLP_OPTS=(
    --format "bestvideo[height<=720][ext=mp4]+bestaudio[ext=m4a]/bestvideo[height<=720]+bestaudio/best[height<=720]/best"
    --merge-output-format mp4
    --download-archive "${ARCHIVE_FILE}"
    --no-playlist                      # overridden for playlist type
    --embed-thumbnail
    --add-metadata
    --no-overwrites
    --no-update                        # suppress "update your yt-dlp" warning
    --retries 3
    --fragment-retries 3
    --retry-sleep 10
    --quiet
    --progress
    --console-title
)

ytdlp_download() {
    local type="$1"
    local url_or_id="$2"
    local dest_dir="$3"
    local extra_opts=()

    mkdir -p "${dest_dir}"

    # Construct full URL if bare video ID given
    local url="${url_or_id}"
    if [[ "${url_or_id}" =~ ^[a-zA-Z0-9_-]{11}$ ]]; then
        url="https://www.youtube.com/watch?v=${url_or_id}"
    fi

    case "${type}" in
        playlist)
            extra_opts=(
                --yes-playlist
                --playlist-end 20
                --output "${dest_dir}/%(playlist_index)02d-%(title)s.%(ext)s"
            )
            ;;
        channel)
            extra_opts=(
                --yes-playlist
                --playlist-end 10
                --output "${dest_dir}/%(title)s.%(ext)s"
            )
            ;;
        video|*)
            extra_opts=(
                --output "${dest_dir}/%(title)s.%(ext)s"
            )
            ;;
    esac

    # Run yt-dlp; capture exit code without failing the whole script
    local exit_code=0
    "${YTDLP}" "${YTDLP_OPTS[@]}" "${extra_opts[@]}" "${url}" \
        2>&1 | tee -a "${LOG_FILE}" || exit_code=$?

    return ${exit_code}
}

# ── process each entry ────────────────────────────────────────────────────────
while IFS=$'\t' read -r type id_or_url category subcategory title; do
    [[ -z "${type}" || "${type}" == \#* ]] && continue
    type="${type// /}"
    id_or_url="${id_or_url// /}"
    category="${category// /}"
    subcategory="${subcategory// /}"

    dest_dir="${VIDEO_ROOT}/${category}"

    log "Processing: ${title:-${id_or_url}} [${category}/${subcategory}]"

    if ytdlp_download "${type}" "${id_or_url}" "${dest_dir}" 2>&1; then
        (( added++ )) || true
    else
        # yt-dlp exit 101 = all videos already in archive (not a real failure)
        exit_code=$?
        if [[ ${exit_code} -eq 101 ]]; then
            log "SKIP ${title:-${id_or_url}} (already in archive)"
            (( skipped++ )) || true
        else
            fail "${title:-${id_or_url}}: yt-dlp exit ${exit_code}"
        fi
    fi

done < <(grep -v '^[[:space:]]*$' "${CONF}")

log "Done: added=${added} skipped=${skipped} failed=${failed}"
(( failed > 0 )) && exit 1 || exit 0
