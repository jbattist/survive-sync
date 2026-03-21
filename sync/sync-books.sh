#!/usr/bin/env bash
# sync-books.sh — download EPUBs from Project Gutenberg and Standard Ebooks
# Ingests new files into the Calibre library via `calibredb add`.
# Skips files already present by output filename.
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
TMP_DIR="/tmp/survive-books-$$"

GUTENBERG_BASE="https://www.gutenberg.org/ebooks"
STDEBOOKS_BASE="https://standardebooks.org/ebooks"

added=0; skipped=0; failed=0

log()  { echo "[BOOK][$(date '+%H:%M:%S')] $*" | tee -a "${LOG_FILE}"; }
fail() { log "FAIL $*"; (( failed++ )) || true; }

mkdir -p "${TMP_DIR}" "${EPUB_DIR}" "${CALIBRE_LIB}"
trap 'rm -rf "${TMP_DIR}"' EXIT

calibredb_add() {
    local file="$1"
    if command -v calibredb &>/dev/null; then
        calibredb add \
            --with-library "${CALIBRE_LIB}" \
            --dont-add-duplicates \
            "${file}" 2>&1 | tee -a "${LOG_FILE}" || \
            log "WARN: calibredb add failed for $(basename "${file}") (non-fatal)"
    else
        log "WARN: calibredb not found; EPUB copied to epub dir only"
    fi
}

# ── process each book ─────────────────────────────────────────────────────────
while IFS=$'\t' read -r source id_or_slug local_base category priority title; do
    [[ -z "${source}" || "${source}" == \#* ]] && continue
    source="${source// /}"
    id_or_slug="${id_or_slug// /}"
    local_base="${local_base// /}"

    dest_file="${EPUB_DIR}/${local_base}.epub"

    if [[ -f "${dest_file}" ]]; then
        # File already downloaded — skip download but still ensure it's in the Calibre library.
        # (EPUBs may have been downloaded before Calibre was configured, or the library wiped.)
        log "SKIP download ${local_base} (already on disk, ensuring in library)"
        calibredb_add "${dest_file}"
        (( skipped++ )) || true
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
    calibredb_add "${dest_file}"
    (( added++ )) || true

done < <(grep -v '^[[:space:]]*$' "${CONF}")

log "Done: added=${added} skipped=${skipped} failed=${failed}"
(( failed > 0 )) && exit 1 || exit 0
