#!/usr/bin/env bash
# rebuild-indexes.sh — regenerate the three markdown index files from the catalog
#
# Outputs:
#   /srv/offline/indexes/top-25-essential.md   — P1 items only
#   /srv/offline/indexes/top-100-phone-first.md — P1+P2, mobile-formatted
#   /srv/offline/indexes/print-first-binder.md  — P1, formatted for printing
set -euo pipefail

CATALOG="/srv/offline/metadata/library_catalog.csv"
INDEX_DIR="/srv/offline/indexes"

log() { echo "[POSTPROCESS][indexes] $*"; }

mkdir -p "${INDEX_DIR}"

if [[ ! -f "${CATALOG}" ]]; then
    log "WARN: catalog not found at ${CATALOG} — skipping index rebuild"
    exit 0
fi

# ── shared helper: render a markdown table from catalog rows ──────────────────
build_index() {
    local out_file="$1"
    local title="$2"
    local description="$3"
    local priority_filter="$4"   # P1 | P1|P2 | all
    local max_rows="${5:-9999}"

    python3 - "${CATALOG}" "${out_file}" "${title}" "${description}" \
        "${priority_filter}" "${max_rows}" <<'PYEOF'
import sys, csv, os

catalog_file, out_file, title, description, priority_filter, max_rows = sys.argv[1:]
max_rows = int(max_rows)

priorities = set(priority_filter.split("|"))

rows = []
try:
    with open(catalog_file, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            if "all" in priorities or row.get("priority", "P3") in priorities:
                rows.append(row)
except Exception as e:
    print(f"[indexes] ERROR reading catalog: {e}", file=sys.stderr)
    sys.exit(1)

# Sort: priority P1 first, then category, then title
priority_order = {"P1": 0, "P2": 1, "P3": 2}
rows.sort(key=lambda r: (
    priority_order.get(r.get("priority","P3"), 2),
    r.get("category",""),
    r.get("title","")
))
rows = rows[:max_rows]

with open(out_file, "w", encoding="utf-8") as f:
    f.write(f"# {title}\n\n")
    f.write(f"{description}\n\n")
    f.write(f"_Generated: {__import__('datetime').date.today()}_  \n")
    f.write(f"_Entries: {len(rows)}_\n\n")
    f.write("---\n\n")

    current_category = None
    for row in rows:
        cat = row.get("category", "other")
        if cat != current_category:
            current_category = cat
            f.write(f"\n## {cat}\n\n")

        path = row.get("local_path", "")
        title_text = row.get("title", path)
        priority = row.get("priority", "")
        author = row.get("author_org", "")
        year = row.get("publication_year", "")
        summary = row.get("summary", "")
        media = row.get("media_type", "").split("/")[-1]

        meta_parts = [x for x in [author, year, media, priority] if x]
        meta = " · ".join(meta_parts)

        f.write(f"- **{title_text}**")
        if meta:
            f.write(f"  `{meta}`")
        if summary:
            f.write(f"  \n  _{summary}_")
        if path:
            f.write(f"  \n  `{path}`")
        f.write("\n")

print(f"[indexes] Wrote {len(rows)} entries to {out_file}")
PYEOF
}

# ── top-25-essential.md ───────────────────────────────────────────────────────
build_index \
    "${INDEX_DIR}/top-25-essential.md" \
    "Top 25 Essential Resources" \
    "P1 priority items — lifesaving and critical. These should be the first items reviewed, printed, or accessed in an emergency." \
    "P1" \
    25

# ── top-100-phone-first.md ────────────────────────────────────────────────────
build_index \
    "${INDEX_DIR}/top-100-phone-first.md" \
    "Top 100 Resources — Phone First" \
    "P1 and P2 priority items. This index is formatted for quick reference on a mobile phone. Open links from the portal at http://survive.travel" \
    "P1|P2" \
    100

# ── print-first-binder.md ─────────────────────────────────────────────────────
build_index \
    "${INDEX_DIR}/print-first-binder.md" \
    "Print-First Binder Index" \
    "P1 priority items to print and keep in the physical binder with the device. These are the documents that matter most when power or screens are unavailable." \
    "P1"

log "Index rebuild complete:"
log "  $(wc -l < "${INDEX_DIR}/top-25-essential.md") lines  → top-25-essential.md"
log "  $(wc -l < "${INDEX_DIR}/top-100-phone-first.md") lines → top-100-phone-first.md"
log "  $(wc -l < "${INDEX_DIR}/print-first-binder.md") lines → print-first-binder.md"

# ── PDF portal index page ──────────────────────────────────────────────────────
# Generate a human-readable /srv/offline/portal/pdfs/index.html listing all
# PDFs grouped by category.  Replaces Caddy's raw directory listing.
PDF_ROOT="/srv/offline/pdfs"
PORTAL_ROOT="/srv/offline/portal"
PDFS_INDEX="${PORTAL_ROOT}/pdfs/index.html"
PDF_SOURCES="/srv/offline/scripts/config/pdf-sources.conf"

log "Building PDF portal index page..."

mkdir -p "${PORTAL_ROOT}/pdfs"

python3 - "${PDF_ROOT}" "${PDF_SOURCES}" "${PDFS_INDEX}" <<'PYEOF'
import sys, os, re
from pathlib import Path
from datetime import date

pdf_root, sources_conf, out_path = sys.argv[1], sys.argv[2], sys.argv[3]

# ── parse pdf-sources.conf for titles and categories ──────────────────────────
meta = {}   # filename → {title, category, priority}
if os.path.isfile(sources_conf):
    with open(sources_conf, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) >= 5:
                fname   = parts[1].strip()
                cat_dir = parts[2].strip()
                pri     = parts[3].strip()
                desc    = parts[4].strip()
                meta[fname] = {"title": desc, "category": cat_dir, "priority": pri}

# ── scan actual PDF files on disk ─────────────────────────────────────────────
categories = {}   # cat_dir → list of {filename, title, priority, size_mb}
for cat_dir in sorted(os.listdir(pdf_root)):
    full_cat = os.path.join(pdf_root, cat_dir)
    if not os.path.isdir(full_cat):
        continue
    entries = []
    for fname in sorted(os.listdir(full_cat)):
        if not fname.lower().endswith(".pdf"):
            continue
        fpath = os.path.join(full_cat, fname)
        size_mb = os.path.getsize(fpath) / (1024 * 1024)
        info = meta.get(fname, {})
        title = info.get("title") or fname.replace("_", " ").replace("-", " ").rsplit(".", 1)[0]
        priority = info.get("priority", "")
        entries.append({
            "filename": fname,
            "title": title,
            "priority": priority,
            "size_mb": size_mb,
        })
    if entries:
        categories[cat_dir] = entries

total_pdfs = sum(len(v) for v in categories.values())

# ── pretty category label ──────────────────────────────────────────────────────
def cat_label(cat_dir):
    # "00-start-here" → "00 — Start Here"
    m = re.match(r"^(\d+)-(.+)$", cat_dir)
    if m:
        num = m.group(1)
        name = m.group(2).replace("-", " ").title()
        return f"{num} — {name}"
    return cat_dir.replace("-", " ").title()

# ── priority badge ─────────────────────────────────────────────────────────────
def pri_badge(p):
    colors = {"P1": "#c0392b", "P2": "#e67e22", "P3": "#7f8c8d"}
    if p in colors:
        return f'<span class="pri" style="background:{colors[p]}">{p}</span>'
    return ""

# ── HTML ───────────────────────────────────────────────────────────────────────
lines = []
lines.append("""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Guides &amp; Manuals — SURVIVE</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
           background: #1a1a1a; color: #e0e0e0; padding: 2rem 1rem; }
    header { text-align: center; margin-bottom: 2rem; }
    header h1 { font-size: 2rem; font-weight: 800; color: #ff4444; letter-spacing: 0.1em; }
    header p { color: #888; margin-top: 0.4rem; font-size: 0.9rem; }
    nav { text-align: center; margin-bottom: 2rem; }
    nav a { color: #aaa; text-decoration: none; margin: 0 0.75rem; font-size: 0.9rem; }
    nav a:hover { color: #fff; }
    .section { max-width: 860px; margin: 0 auto 2rem; }
    .section h2 { font-size: 1rem; font-weight: 700; color: #ff4444; text-transform: uppercase;
                  letter-spacing: 0.08em; border-bottom: 1px solid #333; padding-bottom: 0.4rem;
                  margin-bottom: 0.75rem; }
    ul { list-style: none; }
    li { padding: 0.45rem 0; border-bottom: 1px solid #2a2a2a; display: flex;
         align-items: baseline; gap: 0.6rem; flex-wrap: wrap; }
    li:last-child { border-bottom: none; }
    a.pdf { color: #cce; text-decoration: none; font-size: 0.9rem; flex: 1 1 auto; }
    a.pdf:hover { color: #fff; text-decoration: underline; }
    .pri { font-size: 0.7rem; font-weight: 700; color: #fff; border-radius: 3px;
           padding: 1px 5px; flex-shrink: 0; }
    .size { color: #555; font-size: 0.75rem; flex-shrink: 0; }
    footer { text-align: center; color: #444; font-size: 0.8rem; margin-top: 3rem; }
    footer a { color: #666; text-decoration: none; }
    footer a:hover { color: #aaa; }
  </style>
</head>
<body>
<header>
  <h1>Guides &amp; Manuals</h1>
  <p>SURVIVE Offline Library &mdash; """ + f"{total_pdfs} documents &mdash; generated {date.today()}" + """</p>
</header>
<nav>
  <a href="/">&#8592; Home</a>
  <a href="/search/">&#128269; Search Docs</a>
</nav>
""")

for cat_dir, entries in categories.items():
    label = cat_label(cat_dir)
    lines.append(f'<div class="section">\n  <h2>{label}</h2>\n  <ul>')
    for e in entries:
        href = f"/pdfs/{cat_dir}/{e['filename']}"
        badge = pri_badge(e["priority"])
        size = f"{e['size_mb']:.1f} MB" if e["size_mb"] >= 0.1 else ""
        lines.append(
            f'    <li>{badge}'
            f'<a class="pdf" href="{href}">{e["title"]}</a>'
            f'<span class="size">{size}</span></li>'
        )
    lines.append("  </ul>\n</div>")

lines.append(f"""<footer>
  <p><a href="/">SURVIVE</a> &mdash; <a href="/search/">Search Docs</a></p>
</footer>
</body>
</html>""")

os.makedirs(os.path.dirname(out_path), exist_ok=True)
with open(out_path, "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")

print(f"[POSTPROCESS][indexes] Wrote PDF index: {out_path} ({total_pdfs} PDFs in {len(categories)} categories)")
PYEOF

# ── Pagefind full-text search index ───────────────────────────────────────────
# Requires: pdftotext (poppler), pagefind
# Pipeline:
#   1. Extract text from each PDF with pdftotext → HTML stub in portal/search-index/
#   2. Run pagefind --site /srv/offline/portal → writes pagefind/ index there
#   3. Pagefind UI is at portal/search/index.html and loads /pagefind/pagefind-ui.js

SEARCH_STUBS="${PORTAL_ROOT}/search-index"

if ! command -v pdftotext &>/dev/null; then
    log "WARN: pdftotext not found — skipping PDF text extraction (install poppler)"
elif ! command -v pagefind &>/dev/null; then
    log "WARN: pagefind not found — skipping search index build (run: pip install 'pagefind[extended]')"
else
    log "Building Pagefind search index (pdftotext + pagefind)..."

    mkdir -p "${SEARCH_STUBS}"

    # Build HTML stubs from PDFs (one stub per PDF)
    stub_count=0
    fail_count=0
    for cat_dir in "${PDF_ROOT}"/*/; do
        cat_name=$(basename "${cat_dir}")
        stub_cat="${SEARCH_STUBS}/${cat_name}"
        mkdir -p "${stub_cat}"
        for pdf in "${cat_dir}"*.pdf; do
            [[ -f "${pdf}" ]] || continue
            fname=$(basename "${pdf}" .pdf)
            stub="${stub_cat}/${fname}.html"
            # Extract text (suppress errors for encrypted/image-only PDFs)
            text=$(pdftotext -q "${pdf}" - 2>/dev/null || true)
            if [[ -z "${text}" ]]; then
                fail_count=$((fail_count + 1))
                continue
            fi
            # Look up title from conf (use filename as fallback)
            title=$(python3 -c "
import sys
fname = sys.argv[1] + '.pdf'
try:
    with open('/srv/offline/scripts/config/pdf-sources.conf') as f:
        for line in f:
            if line.startswith('#') or not line.strip(): continue
            parts = line.split('\t')
            if len(parts) >= 5 and parts[1].strip() == fname:
                print(parts[4].strip()); sys.exit(0)
except: pass
print(fname.replace('_',' ').replace('-',' '))
" "${fname}" 2>/dev/null || echo "${fname}")
            href="/pdfs/${cat_name}/${fname}.pdf"
            # Write stub — pagefind indexes data-pagefind-body content and uses
            # the <title> for the result heading, <meta description> for snippet.
            cat > "${stub}" <<STUB
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>${title}</title>
  <meta name="description" content="${cat_name} — ${title}">
  <link rel="canonical" href="${href}">
</head>
<body data-pagefind-body>
  <h1 data-pagefind-meta="title">${title}</h1>
  <p data-pagefind-meta="url[href]"><a href="${href}">Open PDF</a></p>
  <div data-pagefind-weight="1">
${text}
  </div>
</body>
</html>
STUB
            stub_count=$((stub_count + 1))
        done
    done
    log "  Text extraction: ${stub_count} stubs written, ${fail_count} PDFs skipped (encrypted or image-only)"

    # Run Pagefind — index the whole portal directory
    log "  Running pagefind --site ${PORTAL_ROOT} ..."
    pagefind --site "${PORTAL_ROOT}" \
             --source "${SEARCH_STUBS}" \
             --output-path "${PORTAL_ROOT}/pagefind" \
             2>&1 | sed 's/^/[POSTPROCESS][pagefind] /' || \
        log "WARN: pagefind exited non-zero — search index may be incomplete"
    log "  Pagefind index written to ${PORTAL_ROOT}/pagefind/"
fi
