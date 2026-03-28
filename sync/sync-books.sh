#!/usr/bin/env bash
# sync-books.sh — download EPUBs from Project Gutenberg and Standard Ebooks
# Ingests new files into the Calibre library via `calibredb add`.
# Tracks ingested slugs in a local archive file (like yt-dlp) to avoid
# re-adding books and to stay compatible with any calibredb version.
#
# Called by sync-all.sh with:
#   sync-books.sh --config <config_dir> --log <log_file>
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

CONF="${CONFIG_DIR}/book-list.conf"
EPUB_DIR="/srv/offline/books/epub"
CALIBRE_LIB="/srv/offline/books/calibre-library"
# Archive file tracks slugs already ingested into the Calibre library.
# One slug per line.  Prevents re-adding books on every sync run and avoids
# depending on any specific calibredb flag (--dont-add-duplicates and
# --dont-notify-gui were both removed in newer Calibre versions).
INGEST_ARCHIVE="/srv/offline/books/.calibre-ingested.txt"
TMP_DIR="/tmp/survive-books-$$"

GUTENBERG_BASE="https://www.gutenberg.org/ebooks"
STDEBOOKS_BASE="https://standardebooks.org/ebooks"
NFS_BOOKS_DIR="/mnt/truenas-books"

added=0; skipped=0; failed=0

log()  { echo "[BOOK][$(date '+%H:%M:%S')] $*" | tee -a "${LOG_FILE}"; }
fail() { log "FAIL $*"; (( failed++ )) || true; }

mkdir -p "${TMP_DIR}" "${EPUB_DIR}" "${CALIBRE_LIB}"
touch "${INGEST_ARCHIVE}"
trap 'rm -rf "${TMP_DIR}"' EXIT

# ── calibre-server management ─────────────────────────────────────────────────
# calibredb cannot open the library while calibre-server has it locked.
# Stop the server before any ingest, restart it on exit (even on error).
CALIBRE_WAS_RUNNING=false
if systemctl is-active --quiet calibre-server 2>/dev/null; then
    CALIBRE_WAS_RUNNING=true
    log "Stopping calibre-server for library ingest..."
    sudo systemctl stop calibre-server.service
fi
_restart_calibre() {
    rm -rf "${TMP_DIR}"
    if ${CALIBRE_WAS_RUNNING}; then
        log "Restarting calibre-server..."
        sudo systemctl start calibre-server.service || true
    fi
}
trap '_restart_calibre' EXIT

# Returns 0 if slug has already been ingested into the Calibre library.
already_ingested() {
    grep -qxF "$1" "${INGEST_ARCHIVE}"
}

# Adds file to Calibre library and records the slug in the archive on success.
calibredb_add() {
    local file="$1"
    local slug="$2"
    if command -v calibredb &>/dev/null; then
        if calibredb add \
                --with-library "${CALIBRE_LIB}" \
                "${file}" 2>&1 | tee -a "${LOG_FILE}"; then
            echo "${slug}" >> "${INGEST_ARCHIVE}"
        else
            log "WARN: calibredb add failed for $(basename "${file}") (non-fatal)"
        fi
    else
        log "WARN: calibredb not found; EPUB copied to epub dir only"
        # Still mark as ingested so we don't keep retrying on every run
        echo "${slug}" >> "${INGEST_ARCHIVE}"
    fi
}

# ── process each book ─────────────────────────────────────────────────────────
while IFS=$'\t' read -r source id_or_slug local_base category priority title; do
    [[ -z "${source}" || "${source}" == \#* ]] && continue
    source="${source// /}"
    id_or_slug="${id_or_slug// /}"
    local_base="${local_base// /}"

    dest_file="${EPUB_DIR}/${local_base}.epub"

    # If already ingested into Calibre, nothing to do.
    if already_ingested "${local_base}"; then
        log "SKIP ${local_base} (in library)"
        (( skipped++ )) || true
        continue
    fi

    # EPUB on disk but not yet ingested (e.g. downloaded before Calibre was
    # set up, or the ingest archive was wiped).  Skip re-download, add only.
    if [[ -f "${dest_file}" ]]; then
        log "INGEST ${title:-${local_base}} (on disk, not yet in library)"
        calibredb_add "${dest_file}" "${local_base}"
        (( added++ )) || true
        continue
    fi

    log "ADD ${title:-${local_base}}"
    tmp_file="${TMP_DIR}/${local_base}.epub"

    case "${source}" in
        gutenberg)
            # Primary: .epub.images format (best quality)
            url="${GUTENBERG_BASE}/${id_or_slug}.epub.images"
            # Fallback: plain .epub
            fallback_url="${GUTENBERG_BASE}/${id_or_slug}.epub"

            if wget -q --timeout=30 --tries=2 \
                    --user-agent="survive-sync/1.0" \
                    -O "${tmp_file}" "${url}" 2>&1 | tee -a "${LOG_FILE}"; then
                : # ok
            else
                log "  Primary URL failed, trying fallback..."
                wget -q --timeout=30 --tries=2 \
                    --user-agent="survive-sync/1.0" \
                    -O "${tmp_file}" "${fallback_url}" 2>&1 | tee -a "${LOG_FILE}" || \
                    { fail "${local_base}: both Gutenberg URLs failed"; rm -f "${tmp_file}"; continue; }
            fi
            ;;

        standardebooks)
            # Standard Ebooks URL: /ebooks/{author}/{title}[/{translator}]/downloads/{author}_{title}.epub
            # id_or_slug is the full path like  author-name/book-title  or  author/title/translator
            # The download filename always uses only the first two path segments (author_title.epub)
            IFS='/' read -r se_author se_title _se_rest <<< "${id_or_slug}"
            slug_filename="${se_author}_${se_title}"
            url="${STDEBOOKS_BASE}/${id_or_slug}/downloads/${slug_filename}.epub"

            wget -q --timeout=30 --tries=2 \
                --user-agent="survive-sync/1.0 (offline library)" \
                -O "${tmp_file}" "${url}" 2>&1 | tee -a "${LOG_FILE}" || \
                { fail "${local_base}: Standard Ebooks download failed (${url})"; rm -f "${tmp_file}"; continue; }
            ;;

        *)
            fail "${local_base}: unknown source '${source}'"
            continue
            ;;
    esac

    # Validate: must be > 5 KB and start with PK (EPUB is a ZIP)
    size=$(stat -c%s "${tmp_file}" 2>/dev/null || echo 0)
    header=$(head -c 2 "${tmp_file}" 2>/dev/null || echo "")
    if (( size < 5120 )) || [[ "${header}" != "PK" ]]; then
        fail "${local_base}: download invalid (${size} bytes, header='${header}')"
        rm -f "${tmp_file}"
        continue
    fi

    cp "${tmp_file}" "${dest_file}"
    calibredb_add "${dest_file}" "${local_base}"
    (( added++ )) || true

done < <(grep -v '^[[:space:]]*$' "${CONF}")

# ── NFS share scan ─────────────────────────────────────────────────────────────
# Copy any .epub files found on the TrueNAS share to the local EPUB dir and
# ingest them into the Calibre library.  The ingest archive (slug = stem of the
# filename) prevents re-adding books that are already in the library.
# The share is mounted read-only; we copy to /srv/offline/books/epub locally.
if [[ -d "${NFS_BOOKS_DIR}" ]] && mountpoint -q "${NFS_BOOKS_DIR}" 2>/dev/null; then
    log "Scanning NFS share: ${NFS_BOOKS_DIR}"
    nfs_added=0; nfs_skipped=0; nfs_failed=0

    while IFS= read -r nfs_epub; do
        nfs_base=$(basename "${nfs_epub}" .epub)
        dest_file="${EPUB_DIR}/${nfs_base}.epub"

        if already_ingested "${nfs_base}"; then
            log "SKIP ${nfs_base} (NFS, already in library)"
            (( nfs_skipped++ )) || true
            continue
        fi

        # If it somehow landed on disk already, just ingest
        if [[ -f "${dest_file}" ]]; then
            log "INGEST ${nfs_base} (NFS, on disk, not yet in library)"
            calibredb_add "${dest_file}" "${nfs_base}"
            (( nfs_added++ )) || true
            continue
        fi

        log "ADD ${nfs_base} (from NFS)"

        # Validate on the source before copying
        nfs_size=$(stat -c%s "${nfs_epub}" 2>/dev/null || echo 0)
        nfs_header=$(head -c 2 "${nfs_epub}" 2>/dev/null || echo "")
        if (( nfs_size < 5120 )) || [[ "${nfs_header}" != "PK" ]]; then
            fail "${nfs_base}: NFS file invalid (${nfs_size} bytes, header='${nfs_header}')"
            (( nfs_failed++ )) || true
            continue
        fi

        if cp "${nfs_epub}" "${dest_file}"; then
            calibredb_add "${dest_file}" "${nfs_base}"
            (( nfs_added++ )) || true
        else
            fail "${nfs_base}: cp from NFS failed"
            (( nfs_failed++ )) || true
        fi

    done < <(find "${NFS_BOOKS_DIR}" -name "*.epub" -type f 2>/dev/null | sort)

    log "NFS scan done: added=${nfs_added} skipped=${nfs_skipped} failed=${nfs_failed}"
    (( failed += nfs_failed )) || true
    (( added  += nfs_added  )) || true
    (( skipped += nfs_skipped )) || true
else
    log "NFS share not mounted (${NFS_BOOKS_DIR}) — skipping NFS scan"
fi

log "Done: added=${added} skipped=${skipped} failed=${failed}"
(( failed > 0 )) && exit 1 || exit 0
