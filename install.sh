#!/usr/bin/env bash
# install.sh — deploy survive-sync to the field node (Raspberry Pi 5 / EndeavourOS ARM)
#
# Run this script on the Pi after cloning or copying the survive-sync directory:
#
#   git clone <repo> ~/survive-sync
#   cd ~/survive-sync
#   sudo bash install.sh
#
# Or copy the directory over SSH and run:
#   rsync -av survive-sync/ pi@survive:~/survive-sync/
#   ssh pi@survive 'cd ~/survive-sync && sudo bash install.sh'
#
# What this script does:
#   1.  Checks dependencies; installs tilemaker, mbtileserver, kiwix-tools, calibre, yt-dlp if missing
#   2.  Formats and mounts the USB data drive at /srv/offline (label: survive-data)
#   3.  Creates all required directories under /srv/offline
#   4.  Copies scripts, configs, and portal assets to /srv/offline
#   5.  Downloads MapLibre GL JS and OpenMapTiles fonts for offline map viewer
#   6.  Downloads MapLibre GL JS and OpenMapTiles fonts for offline map viewer
#   7.  Installs systemd units for srv-offline.mount, mbtileserver, kiwix, calibre-server, survive-sync
#   8.  Patches /etc/caddy/Caddyfile to add map tile and download routes
#   9.  Patches /etc/nftables.conf to allow port 8082 (mbtileserver)
#   10. Reloads services
#
# Idempotent — safe to re-run after updates.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── colour helpers ─────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[install]${NC} $*"; }
warn()  { echo -e "${YELLOW}[install WARN]${NC} $*"; }
error() { echo -e "${RED}[install ERROR]${NC} $*" >&2; }
die()   { error "$*"; exit 1; }

# ── root check ────────────────────────────────────────────────────────────────
[[ "${EUID}" -eq 0 ]] || die "Run with sudo: sudo bash install.sh"

# ── target paths ──────────────────────────────────────────────────────────────
OFFLINE_ROOT="/srv/offline"
SCRIPTS_DST="${OFFLINE_ROOT}/scripts"
PORTAL_DST="${OFFLINE_ROOT}/portal"
MAPS_TILES_DIR="${OFFLINE_ROOT}/maps/tiles"
# MAPS_DL_DIR: same as MAPS_TILES_DIR — Caddy's /maps/download/ route serves .mbtiles from here
FONTS_DIR="${PORTAL_DST}/maps/fonts"
SYSTEMD_DIR="/etc/systemd/system"
CADDY_CONF="/etc/caddy/Caddyfile"
NFTABLES_CONF="/etc/nftables.conf"

# ── step 1: check / install extra packages ────────────────────────────────────
info "Step 1: Checking extra dependencies"

install_aur_pkg() {
    local pkg="$1"
    if pacman -Qi "${pkg}" &>/dev/null; then
        info "  ${pkg}: already installed"
        return
    fi
    warn "  ${pkg}: not installed — attempting AUR install via yay/paru"
    if command -v yay &>/dev/null; then
        sudo -u "${SUDO_USER:-nobody}" yay -S --noconfirm "${pkg}" || \
            warn "  yay install failed for ${pkg} — install manually: yay -S ${pkg}"
    elif command -v paru &>/dev/null; then
        sudo -u "${SUDO_USER:-nobody}" paru -S --noconfirm "${pkg}" || \
            warn "  paru install failed for ${pkg} — install manually: paru -S ${pkg}"
    else
        warn "  No AUR helper found.  Install ${pkg} manually:"
        warn "    yay -S ${pkg}   OR   paru -S ${pkg}"
    fi
}

# tilemaker — converts OSM PBF to MBTiles
# The AUR package declares arch=('x86_64') only, so on aarch64 (Pi 5) we build from source.
install_tilemaker() {
    if command -v tilemaker &>/dev/null; then
        info "  tilemaker: already installed"
        return 0
    fi

    local arch
    arch=$(uname -m)

    if [[ "${arch}" == "aarch64" || "${arch}" == arm* ]]; then
        info "  tilemaker: aarch64 — building from source (AUR pkg is x86_64 only)"

        info "  Installing tilemaker build dependencies via pacman..."
        pacman -S --noconfirm --needed \
            base-devel cmake git \
            boost boost-libs \
            protobuf \
            shapelib \
            rapidjson \
            luajit \
            sqlite \
            zlib 2>&1 | tee -a /dev/null || \
            warn "  Some tilemaker deps may have failed — attempting build anyway"

        local build_dir
        build_dir=$(mktemp -d /tmp/tilemaker-build-XXXXXX)
        trap 'rm -rf "${build_dir}"' RETURN

        info "  Cloning tilemaker source..."
        git clone --depth=1 https://github.com/systemed/tilemaker.git "${build_dir}" || {
            warn "  tilemaker clone failed — maps module will be skipped"
            return 1
        }

        info "  Configuring tilemaker (cmake)..."
        cmake -S "${build_dir}" -B "${build_dir}/build" \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_INSTALL_PREFIX=/usr \
            2>&1 || { warn "  tilemaker cmake failed"; return 1; }

        info "  Building tilemaker ($(nproc) cores — may take several minutes)..."
        cmake --build "${build_dir}/build" --parallel "$(nproc)" \
            2>&1 || { warn "  tilemaker build failed"; return 1; }

        cmake --install "${build_dir}/build" 2>&1 || { warn "  tilemaker install failed"; return 1; }

        # Install the openmaptiles config/process files to the standard location
        # so sync-maps.sh can find them without downloading them at runtime
        mkdir -p /usr/share/tilemaker
        cp -r "${build_dir}/resources/." /usr/share/tilemaker/ 2>/dev/null || \
            warn "  Could not copy tilemaker resources to /usr/share/tilemaker/"

        if command -v tilemaker &>/dev/null; then
            info "  tilemaker: built and installed from source"
        else
            warn "  tilemaker binary not found after build — maps module will be skipped"
        fi
    else
        install_aur_pkg tilemaker
    fi
}
install_tilemaker

# mbtileserver — serves MBTiles over HTTP
# It's a Go binary so it compiles on aarch64, but the AUR pkg may declare x86_64 only.
# On aarch64: skip AUR and go straight to `go install`.
if ! command -v mbtileserver &>/dev/null; then
    _arch=$(uname -m)
    _installed=false

    if [[ "${_arch}" != "aarch64" && "${_arch}" != arm* ]]; then
        install_aur_pkg mbtileserver
        command -v mbtileserver &>/dev/null && _installed=true
    fi

    if [[ "${_installed}" == false ]]; then
        # Build from source via Go (works on all architectures)
        if command -v go &>/dev/null; then
            info "  Installing mbtileserver via go install..."
            GOPATH=/usr/local go install github.com/consbio/mbtileserver@latest && \
                _installed=true || \
                warn "  go install failed for mbtileserver"
            # Ensure binary is on PATH
            for _bin in /usr/local/bin/mbtileserver /root/go/bin/mbtileserver; do
                [[ -f "${_bin}" ]] && ln -sf "${_bin}" /usr/bin/mbtileserver && break || true
            done
        else
            warn "  Go not found and AUR skipped — installing Go to build mbtileserver..."
            pacman -S --noconfirm --needed go 2>&1 | tee -a /dev/null && \
                GOPATH=/usr/local go install github.com/consbio/mbtileserver@latest && \
                { ln -sf /usr/local/bin/mbtileserver /usr/bin/mbtileserver 2>/dev/null || true; \
                  _installed=true; } || \
                warn "  mbtileserver install failed — install manually: go install github.com/consbio/mbtileserver@latest"
        fi
    fi

    command -v mbtileserver &>/dev/null && \
        info "  mbtileserver: installed" || \
        warn "  mbtileserver not found — map tile serving will not work"
else
    info "  mbtileserver: already installed"
fi

# kiwix-tools — ZIM file server (kiwix-serve + kiwix-manage)
if ! command -v kiwix-serve &>/dev/null; then
    info "  Installing kiwix-tools..."
    # Try official repos first, then AUR
    pacman -S --noconfirm --needed kiwix-tools 2>/dev/null || install_aur_pkg kiwix-tools
    command -v kiwix-serve &>/dev/null && \
        info "  kiwix-tools: installed" || \
        warn "  kiwix-tools not found — install manually: yay -S kiwix-tools"
else
    info "  kiwix-tools: already installed"
fi

# calibre — ebook library server
if ! command -v calibre-server &>/dev/null; then
    info "  Installing calibre..."
    pacman -S --noconfirm --needed calibre 2>/dev/null || \
        warn "  calibre install failed — install manually: sudo pacman -S calibre"
    command -v calibre-server &>/dev/null && \
        info "  calibre: installed" || \
        warn "  calibre-server not found after install attempt"
else
    info "  calibre: already installed"
fi

# yt-dlp — video downloader
if ! command -v yt-dlp &>/dev/null; then
    info "  Installing yt-dlp..."
    if pacman -Qi yt-dlp &>/dev/null; then
        info "  yt-dlp: already installed via pacman"
    else
        # Try pacman community/extra repo first
        pacman -S --noconfirm yt-dlp 2>/dev/null || true
        # Fallback: pip install
        if ! command -v yt-dlp &>/dev/null; then
            pip install --break-system-packages -q yt-dlp || \
                warn "  yt-dlp install failed — install manually: sudo pacman -S yt-dlp"
        fi
    fi
else
    info "  yt-dlp: already installed ($(yt-dlp --version 2>/dev/null || echo unknown))"
fi

# caddy — reverse proxy and portal web server
if ! command -v caddy &>/dev/null; then
    info "  Installing caddy..."
    pacman -S --noconfirm --needed caddy 2>/dev/null || \
        warn "  caddy install failed — install manually: sudo pacman -S caddy"
    command -v caddy &>/dev/null && \
        info "  caddy: installed" || \
        warn "  caddy not found after install attempt"
else
    info "  caddy: already installed ($(caddy version 2>/dev/null | head -1 || echo unknown))"
fi

# ── step 2: set up USB data drive ─────────────────────────────────────────────
info "Step 2: Setting up USB data drive (/srv/offline)"

USB_DEV="/dev/sda"
USB_LABEL="survive-data"

setup_usb_drive() {
    if [[ ! -b "${USB_DEV}" ]]; then
        warn "  ${USB_DEV} not found — /srv/offline will use the SD card for now"
        warn "  Connect the USB drive and re-run install.sh to move content to USB"
        return 0
    fi

    # Check if already labelled — whole disk or first partition
    local use_dev=""
    for candidate in "${USB_DEV}" "${USB_DEV}1"; do
        if [[ -b "${candidate}" ]] && \
           blkid -s LABEL -o value "${candidate}" 2>/dev/null | grep -qx "${USB_LABEL}"; then
            use_dev="${candidate}"
            break
        fi
    done

    if [[ -z "${use_dev}" ]]; then
        info "  Formatting ${USB_DEV} as ext4 (label: ${USB_LABEL})..."
        warn "  *** ALL EXISTING DATA ON ${USB_DEV} WILL BE ERASED ***"
        # Format the whole disk directly — simpler for a dedicated single-purpose drive
        mkfs.ext4 -F -L "${USB_LABEL}" -m 1 "${USB_DEV}" || {
            warn "  mkfs.ext4 failed — /srv/offline will remain on SD card"
            return 0
        }
        use_dev="${USB_DEV}"
        info "  Formatted: ${use_dev} (ext4, label=${USB_LABEL})"
    else
        info "  ${use_dev}: already formatted (label=${USB_LABEL})"
    fi

    # Pre-install the systemd mount unit so we can start it right now.
    # Step 7 will copy it again from the repo (idempotent).
    cp "${SCRIPT_DIR}/systemd/srv-offline.mount" "${SYSTEMD_DIR}/"
    systemctl daemon-reload

    mkdir -p /srv/offline

    if mountpoint -q /srv/offline 2>/dev/null; then
        info "  /srv/offline: already mounted"
    else
        systemctl start srv-offline.mount && \
            info "  /srv/offline: mounted from ${use_dev}" || \
            warn "  Mount failed — check: systemctl status srv-offline.mount"
    fi

    mountpoint -q /srv/offline && \
        systemctl enable srv-offline.mount 2>/dev/null && \
        info "  srv-offline.mount: enabled (auto-mounts at boot)" || true
}
setup_usb_drive

# ── step 3: create directory structure ────────────────────────────────────────
info "Step 3: Creating directory structure under ${OFFLINE_ROOT}"

# Ensure library user exists (spec §6)
if ! id library &>/dev/null; then
    useradd -r -m -d /var/lib/library -s /usr/bin/nologin library
    info "  Created system user: library"
else
    info "  User library: exists"
fi

dirs=(
    "${OFFLINE_ROOT}/portal/splash"
    "${OFFLINE_ROOT}/kiwix/zim"
    "${OFFLINE_ROOT}/pdfs/00-start-here"
    "${OFFLINE_ROOT}/pdfs/01-medical"
    "${OFFLINE_ROOT}/pdfs/02-water"
    "${OFFLINE_ROOT}/pdfs/03-food"
    "${OFFLINE_ROOT}/pdfs/04-agriculture"
    "${OFFLINE_ROOT}/pdfs/05-shelter"
    "${OFFLINE_ROOT}/pdfs/06-power"
    "${OFFLINE_ROOT}/pdfs/07-repair"
    "${OFFLINE_ROOT}/pdfs/08-comms"
    "${OFFLINE_ROOT}/pdfs/09-navigation"
    "${OFFLINE_ROOT}/pdfs/10-security"
    "${OFFLINE_ROOT}/pdfs/11-reference"
    "${OFFLINE_ROOT}/pdfs/12-technology"
    "${OFFLINE_ROOT}/books/epub"
    "${OFFLINE_ROOT}/books/calibre-library"
    "${OFFLINE_ROOT}/maps/tiles"
    "${OFFLINE_ROOT}/maps/pbf"
    "${OFFLINE_ROOT}/maps/topo"
    "${OFFLINE_ROOT}/maps/printable"
    "${OFFLINE_ROOT}/maps/geojson"
    "${OFFLINE_ROOT}/video/first-aid"
    "${OFFLINE_ROOT}/video/repair"
    "${OFFLINE_ROOT}/video/power"
    "${OFFLINE_ROOT}/video/food"
    "${OFFLINE_ROOT}/video/morale"
    "${OFFLINE_ROOT}/indexes"
    "${OFFLINE_ROOT}/metadata"
    "${OFFLINE_ROOT}/scripts/sync"
    "${OFFLINE_ROOT}/scripts/config"
    "${OFFLINE_ROOT}/scripts/postprocess"
    "${OFFLINE_ROOT}/scripts/admin"
    "${OFFLINE_ROOT}/logs"
    "${OFFLINE_ROOT}/incoming"
    "${OFFLINE_ROOT}/staging"
    "${OFFLINE_ROOT}/releases"
    "${FONTS_DIR}"
    "${PORTAL_DST}/maps"
)

for d in "${dirs[@]}"; do
    mkdir -p "${d}"
done
info "  Directories: OK"

# Create a stub kiwix library.xml if one does not exist yet.
# kiwix-serve refuses to start without this file; real entries are added by
# update-kiwix-library.sh after each sync.
KIWIX_LIBRARY="/srv/offline/kiwix/library.xml"
if [[ ! -f "${KIWIX_LIBRARY}" ]]; then
    cat > "${KIWIX_LIBRARY}" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<library version="20110515" current="" id=""/>
XML
    info "  Created stub kiwix library.xml"
else
    info "  kiwix library.xml: already present"
fi

# ── step 4: copy scripts and configs ──────────────────────────────────────────
info "Step 4: Copying scripts and configs"

cp -r "${SCRIPT_DIR}/sync/."        "${SCRIPTS_DST}/sync/"
cp -r "${SCRIPT_DIR}/config/."      "${SCRIPTS_DST}/config/"
cp -r "${SCRIPT_DIR}/postprocess/." "${SCRIPTS_DST}/postprocess/"

# Also copy existing spec admin scripts if present in the repo
if [[ -d "${SCRIPT_DIR}/admin" ]]; then
    cp -r "${SCRIPT_DIR}/admin/." "${SCRIPTS_DST}/admin/"
fi

chmod +x "${SCRIPTS_DST}/sync/"*.sh
chmod +x "${SCRIPTS_DST}/postprocess/"*.sh
[[ -d "${SCRIPTS_DST}/admin" ]] && chmod +x "${SCRIPTS_DST}/admin/"*.sh || true

# Copy portal maps viewer
cp -r "${SCRIPT_DIR}/portal/." "${PORTAL_DST}/"

info "  Scripts and portal assets: OK"

# ── step 5: download MapLibre GL JS (offline dependency) ─────────────────────
info "Step 5: Downloading MapLibre GL JS for offline map viewer"

MAPLIBRE_JS="${PORTAL_DST}/maps/maplibre-gl.js"
MAPLIBRE_CSS="${PORTAL_DST}/maps/maplibre-gl.css"

if [[ -f "${MAPLIBRE_JS}" ]] && [[ -s "${MAPLIBRE_JS}" ]]; then
    info "  MapLibre GL JS: already present"
else
    info "  Fetching latest MapLibre GL JS release..."
    ML_VERSION=$(curl -sf --max-time 15 \
        "https://api.github.com/repos/maplibre/maplibre-gl-js/releases/latest" \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'].lstrip('v'))" \
        2>/dev/null) || ML_VERSION="4.5.2"
    info "  MapLibre GL JS version: ${ML_VERSION}"

    ML_BASE="https://github.com/maplibre/maplibre-gl-js/releases/download/v${ML_VERSION}"
    curl -L --max-time 120 -o "${MAPLIBRE_JS}"  "${ML_BASE}/maplibre-gl.js"  || \
        warn "  Failed to download maplibre-gl.js — map viewer requires manual install"
    curl -L --max-time 30  -o "${MAPLIBRE_CSS}" "${ML_BASE}/maplibre-gl.css" || \
        warn "  Failed to download maplibre-gl.css"
fi

# ── step 6: download OpenMapTiles fonts for map labels ────────────────────────
info "Step 6: Downloading OpenMapTiles fonts for offline map labels"

# Check if fonts are already installed (look for any .pbf glyph file)
if find "${FONTS_DIR}" -name "*.pbf" -print -quit 2>/dev/null | grep -q .; then
    info "  Fonts: already present"
else
    info "  Fetching OpenMapTiles fonts..."
    FONTS_TMP="/tmp/omtfonts-$$.zip"

    # Resolve the latest release asset URL via the GitHub API (same pattern as MapLibre above).
    # Falls back to the known-good v2.0 release if the API is unreachable.
    FONTS_ASSET_URL=$(curl -sf --max-time 15 \
        "https://api.github.com/repos/openmaptiles/fonts/releases/latest" \
        | python3 -c "
import sys, json
data = json.load(sys.stdin)
tag = data.get('tag_name', 'v2.0').lstrip('v')
assets = data.get('assets', [])
# Prefer an asset whose name is exactly 'v<tag>.zip'
wanted = f'v{tag}.zip'
for a in assets:
    if a.get('name') == wanted:
        print(a['browser_download_url'])
        sys.exit(0)
# Fallback: construct the URL from the tag directly
print(f'https://github.com/openmaptiles/fonts/releases/download/v{tag}/v{tag}.zip')
" 2>/dev/null) || FONTS_ASSET_URL="https://github.com/openmaptiles/fonts/releases/download/v2.0/v2.0.zip"

    info "  Fonts URL: ${FONTS_ASSET_URL}"

    if curl -L --max-time 300 -o "${FONTS_TMP}" "${FONTS_ASSET_URL}" 2>/dev/null; then
        # Validate that what we downloaded is actually a zip before calling unzip
        if python3 -c "
import sys
with open('${FONTS_TMP}', 'rb') as f:
    magic = f.read(4)
sys.exit(0 if magic == b'PK\x03\x04' else 1)
" 2>/dev/null; then
            info "  Extracting fonts..."
            unzip -q -o "${FONTS_TMP}" -d "${FONTS_DIR}/" || \
                warn "  unzip failed — fonts may be incomplete; extract manually to ${FONTS_DIR}/"
            rm -f "${FONTS_TMP}"
            font_count=$(find "${FONTS_DIR}" -name "*.pbf" | wc -l)
            info "  Fonts installed: ${font_count} glyph files"
        else
            warn "  Downloaded file is not a valid zip (got HTML redirect or error page)."
            warn "  Map labels will not render until fonts are installed."
            warn "  To fix: download ${FONTS_ASSET_URL}"
            warn "  and extract to ${FONTS_DIR}/"
            rm -f "${FONTS_TMP}"
        fi
    else
        warn "  Fonts download failed.  Map labels will not render."
        warn "  To fix later: download https://github.com/openmaptiles/fonts/releases"
        warn "  and extract to ${FONTS_DIR}/"
        rm -f "${FONTS_TMP}" 2>/dev/null || true
    fi
fi

# ── step 7: install systemd units ─────────────────────────────────────────────
info "Step 7: Installing systemd units"

cp "${SCRIPT_DIR}/systemd/srv-offline.mount"       "${SYSTEMD_DIR}/"
cp "${SCRIPT_DIR}/systemd/kiwix.service"           "${SYSTEMD_DIR}/"
cp "${SCRIPT_DIR}/systemd/calibre-server.service"  "${SYSTEMD_DIR}/"
cp "${SCRIPT_DIR}/systemd/mbtileserver.service"    "${SYSTEMD_DIR}/"
cp "${SCRIPT_DIR}/systemd/survive-sync.service"    "${SYSTEMD_DIR}/"
cp "${SCRIPT_DIR}/systemd/survive-sync.timer"      "${SYSTEMD_DIR}/"

systemctl daemon-reload

systemctl enable --now kiwix.service && \
    info "  kiwix.service: enabled and started" || \
    warn "  kiwix.service: enable failed (check: systemctl status kiwix)"

systemctl enable --now calibre-server.service && \
    info "  calibre-server.service: enabled and started" || \
    warn "  calibre-server.service: enable failed (check: systemctl status calibre-server)"

systemctl enable --now mbtileserver.service && \
    info "  mbtileserver.service: enabled and started" || \
    warn "  mbtileserver.service: enable failed (check: systemctl status mbtileserver)"

systemctl enable survive-sync.timer && \
    info "  survive-sync.timer: enabled" || \
    warn "  survive-sync.timer: enable failed"

# Start the timer (does not start the service immediately)
systemctl start survive-sync.timer 2>/dev/null || true

info "  Systemd units: OK"
info "  Next sync: $(systemctl show survive-sync.timer --property=NextElapseUSecRealtime 2>/dev/null | cut -d= -f2 || echo unknown)"
info "  Manual trigger: systemctl start survive-sync.service"

# ── step 8: install / patch Caddyfile ────────────────────────────────────────
info "Step 8: Configuring Caddy"

# Always write our Caddyfile — the caddy package ships a default that we need
# to replace.  Back up the existing file if it doesn't already contain our config.
if [[ -f "${CADDY_CONF}" ]] && ! grep -q '/srv/offline/portal' "${CADDY_CONF}"; then
    cp "${CADDY_CONF}" "${CADDY_CONF}.bak-$(date +%Y%m%d%H%M%S)"
    info "  Backed up existing Caddyfile"
fi

if grep -q 'maps/tiles' "${CADDY_CONF}" 2>/dev/null && \
   grep -q '/srv/offline/portal' "${CADDY_CONF}" 2>/dev/null; then
    info "  Caddyfile: already configured for SURVIVE"
else
    mkdir -p "$(dirname "${CADDY_CONF}")"
    cat > "${CADDY_CONF}" <<'CADDYFILE'
# SURVIVE offline library — Caddy portal and reverse proxy
# Generated by install.sh

:80 {
    # Map tile proxy — mbtileserver on port 8082
    handle /maps/tiles/* {
        uri strip_prefix /maps/tiles
        reverse_proxy 127.0.0.1:8082
    }

    # Map file downloads (.mbtiles for OsmAnd / Locus Map)
    handle /maps/download/* {
        root * /srv/offline/maps/tiles
        uri strip_prefix /maps/download
        file_server
    }

    # Portal — static files
    root * /srv/offline/portal
    file_server
}
CADDYFILE
    info "  Caddyfile written to ${CADDY_CONF}"
    _caddy_reload=true
fi

# Enable and start Caddy; reload config if we just wrote a new Caddyfile
systemctl enable --now caddy 2>/dev/null && \
    info "  caddy.service: enabled and started" || \
    warn "  caddy enable failed — check: systemctl status caddy"

if [[ "${_caddy_reload:-false}" == true ]]; then
    systemctl reload caddy 2>/dev/null || systemctl restart caddy 2>/dev/null && \
        info "  caddy: reloaded with new config" || \
        warn "  caddy reload failed — run: sudo systemctl restart caddy"
fi

# ── step 9: open firewall ports for survive services ─────────────────────────
info "Step 9: Opening firewall ports (80, 8080, 8081, 8082)"

SURVIVE_PORTS=(80 8080 8081 8082)

if systemctl is-active --quiet firewalld 2>/dev/null; then
    # firewalld is running — use firewall-cmd (editing nftables.conf directly
    # is ineffective because firewalld owns the nftables ruleset)
    info "  firewalld detected — using firewall-cmd"
    firewall-cmd --permanent --add-service=http 2>/dev/null || true
    for port in 8080 8081 8082; do
        firewall-cmd --permanent --add-port="${port}/tcp" 2>/dev/null || true
    done
    firewall-cmd --reload 2>/dev/null && \
        info "  firewalld: ports opened and reloaded" || \
        warn "  firewall-cmd reload failed — run manually: sudo firewall-cmd --reload"
elif [[ -f "${NFTABLES_CONF}" ]]; then
    # Plain nftables — patch the config file directly
    if grep -q 'allow survive services' "${NFTABLES_CONF}"; then
        info "  nftables: survive ports already present"
    else
        info "  Patching nftables config..."
        cp "${NFTABLES_CONF}" "${NFTABLES_CONF}.bak-$(date +%Y%m%d%H%M%S)"

        python3 - "${NFTABLES_CONF}" <<'PYEOF'
import sys, re

path = sys.argv[1]
with open(path) as f:
    content = f.read()

SURVIVE_PORTS = ['80', '8080', '8081', '8082']
NEW_RULE = '    tcp dport { ' + ', '.join(SURVIVE_PORTS) + ' } accept comment "allow survive services"\n'

# Pattern 1: existing tcp dport list — append our missing ports
def add_to_dport_list(m):
    inner = m.group(1)
    ports = [p.strip() for p in inner.split(',')]
    for p in SURVIVE_PORTS:
        if p not in ports:
            ports.append(p)
    return 'tcp dport { ' + ', '.join(ports) + ' } accept'

new_content, n = re.subn(r'tcp dport \{([^}]+)\} accept', add_to_dport_list, content)
if n > 0:
    with open(path, 'w') as f:
        f.write(new_content)
    print(f"nftables: added survive ports to existing tcp dport list ({n} match(es))")
    sys.exit(0)

# Pattern 2: individual tcp dport rules — insert after the last one
new_content, n = re.subn(
    r'([ \t]*tcp dport \S+ accept[^\n]*\n)(?![ \t]*tcp dport)',
    r'\1' + NEW_RULE,
    content
)
if n > 0:
    with open(path, 'w') as f:
        f.write(new_content)
    print("nftables: inserted survive ports rule after existing tcp dport rule")
    sys.exit(0)

# Fallback: insert before closing brace of chain input
new_content, n = re.subn(
    r'(chain input \{[^}]+?)([ \t]*\})',
    lambda m: m.group(1) + NEW_RULE + m.group(2),
    content, flags=re.DOTALL
)
if n > 0:
    with open(path, 'w') as f:
        f.write(new_content)
    print("nftables: inserted survive ports rule into chain input block")
    sys.exit(0)

print("WARNING: could not find insertion point in nftables config")
print("Add this rule manually inside the 'chain input' block:")
print(f"  {NEW_RULE.strip()}")
PYEOF

        if systemctl is-active --quiet nftables 2>/dev/null; then
            nft -f "${NFTABLES_CONF}" && \
                info "  nftables: reloaded with survive ports" || \
                warn "  nftables reload failed — run: sudo nft -f ${NFTABLES_CONF}"
        else
            info "  nftables: config updated (not active — enable with: systemctl enable --now nftables)"
        fi
    fi
else
    warn "  No firewalld or nftables config found — open ports manually:"
    warn "  tcp ports: 80, 8080, 8081, 8082"
fi

# ── step 10: ownership ────────────────────────────────────────────────────────
info "Step 10: Setting ownership"
chown -R library:library "${OFFLINE_ROOT}"
info "  ${OFFLINE_ROOT}: owned by library:library"

# ── step 11: allow library user to restart services via sudo ──────────────────
info "Step 11: Configuring sudo for service restarts"

SUDOERS_FILE="/etc/sudoers.d/survive-sync"
cat > "${SUDOERS_FILE}" <<'SUDOERS'
# Allow the library user to restart content services after a sync
library ALL=(root) NOPASSWD: /usr/bin/systemctl restart kiwix.service
library ALL=(root) NOPASSWD: /usr/bin/systemctl restart calibre-server.service
library ALL=(root) NOPASSWD: /usr/bin/systemctl restart caddy.service
library ALL=(root) NOPASSWD: /usr/bin/systemctl restart mbtileserver.service
SUDOERS
chmod 0440 "${SUDOERS_FILE}"
info "  Sudoers: ${SUDOERS_FILE}"

# ── summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  survive-sync install complete${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
echo ""
echo "Scripts installed to:  ${SCRIPTS_DST}"
echo "Portal assets:         ${PORTAL_DST}/maps/"
echo "Map tiles directory:   ${MAPS_TILES_DIR}"
echo "Fonts directory:       ${FONTS_DIR}"
echo ""
echo "Systemd units installed:"
echo "  srv-offline.mount      (auto-mounts USB drive at /srv/offline on boot)"
echo "  kiwix.service          (port 8080 — Wikipedia/ZIM)"
echo "  calibre-server.service (port 8081 — books)"
echo "  mbtileserver.service   (running now on port 8082 — map tiles)"
echo "  survive-sync.service   (oneshot — runs sync-all.sh)"
echo "  survive-sync.timer     (weekly, Sunday 02:00)"
echo ""
echo "Run a sync manually:"
echo "  systemctl start survive-sync.service"
echo "  journalctl -u survive-sync -f"
echo ""
echo "Or run individual modules:"
echo "  SYNC_MODULES='pdfs books' systemctl start survive-sync.service"
echo ""
echo "Map viewer: http://192.168.50.1/maps/"
echo ""
echo "Next steps:"
echo "  1. Ensure Pi is in sync mode (ethernet/wifi connected to internet)"
echo "  2. Run: systemctl start survive-sync.service"
echo "  3. Monitor: journalctl -u survive-sync -f"
echo "  4. Wikipedia ZIM is ~100 GB — first sync will take hours"
echo ""
