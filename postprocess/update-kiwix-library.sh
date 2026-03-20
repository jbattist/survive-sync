#!/usr/bin/env bash
# update-kiwix-library.sh — rebuild the Kiwix library.xml after ZIM changes
# kiwix-serve reads this file on startup to know which ZIMs to serve.
set -euo pipefail

ZIM_DIR="/srv/offline/kiwix/zim"
LIBRARY_XML="/srv/offline/kiwix/library.xml"

log() { echo "[POSTPROCESS][kiwix-library] $*"; }

if ! command -v kiwix-manage &>/dev/null; then
    log "WARN: kiwix-manage not found — library.xml not updated"
    log "      Install: sudo pacman -S kiwix-tools"
    exit 0
fi

if [[ ! -d "${ZIM_DIR}" ]]; then
    log "WARN: ZIM directory does not exist: ${ZIM_DIR}"
    exit 0
fi

zim_count=$(find "${ZIM_DIR}" -name "*.zim" | wc -l)
if [[ "${zim_count}" -eq 0 ]]; then
    log "No ZIM files found in ${ZIM_DIR} — skipping library rebuild"
    exit 0
fi

log "Rebuilding library.xml from ${zim_count} ZIM file(s)..."

# Start fresh — kiwix-manage add is additive, so we wipe and rebuild
rm -f "${LIBRARY_XML}"

while IFS= read -r -d '' zim_file; do
    log "  Adding: $(basename "${zim_file}")"
    kiwix-manage "${LIBRARY_XML}" add "${zim_file}" || \
        log "  WARN: kiwix-manage failed for $(basename "${zim_file}")"
done < <(find "${ZIM_DIR}" -name "*.zim" -print0 | sort -z)

if [[ -f "${LIBRARY_XML}" ]]; then
    log "library.xml updated ($(wc -l < "${LIBRARY_XML}") lines)"
else
    log "WARN: library.xml was not created"
fi
