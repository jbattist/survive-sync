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
#   1.  Checks dependencies; installs tilemaker, mbtileserver, kiwix-tools, calibre, yt-dlp, poppler, pagefind, jellyfin if missing
#   2.  Formats and mounts the USB data drive at /srv/offline (label: survive-data)
#   2b. Configures NFS mount for TrueNAS book share (truenas.home:/mnt/hdd/books → /mnt/truenas-books)
#   3.  Creates all required directories under /srv/offline
#   4.  Copies scripts, configs, and portal assets to /srv/offline
#   5.  Downloads MapLibre GL JS and OpenMapTiles fonts for offline map viewer
#   6.  Downloads OpenMapTiles fonts for offline map labels
#   7.  Installs systemd units for srv-offline.mount, mbtileserver, kiwix, calibre-server, jellyfin, survive-sync
#   8.  Patches /etc/caddy/Caddyfile to add map tile and download routes
#   9.  Patches /etc/nftables.conf to allow port 8082 (mbtileserver)
#   10. Sets ownership of /srv/offline
#   11. Configures sudo for library user service restarts
#   12. Installs /etc/profile.d/survive-welcome.sh (login banner)
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
    if command -v tilemaker &>/dev/null && tilemaker --version &>/dev/null 2>&1; then
        info "  tilemaker: already installed"
        return 0
    elif command -v tilemaker &>/dev/null; then
        warn "  tilemaker: binary found but broken (missing shared libs?) — rebuilding"
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
    pacman -S --noconfirm --needed kiwix-tools || install_aur_pkg kiwix-tools
    command -v kiwix-serve &>/dev/null && \
        info "  kiwix-tools: installed" || \
        warn "  kiwix-tools not found — install manually: yay -S kiwix-tools"
else
    info "  kiwix-tools: already installed"
fi

# calibre — ebook library server
if ! command -v calibre-server &>/dev/null; then
    info "  Installing calibre..."
    pacman -S --noconfirm --needed calibre || \
        warn "  calibre install failed — run: sudo pacman -Sy calibre"
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
    pacman -S --noconfirm --needed caddy || \
        warn "  caddy install failed — run: sudo pacman -Sy caddy"
    command -v caddy &>/dev/null && \
        info "  caddy: installed" || \
        warn "  caddy not found after install attempt"
else
    info "  caddy: already installed ($(caddy version 2>/dev/null | head -1 || echo unknown))"
fi

# poppler — provides pdftotext, used by the PDF search indexer
if ! command -v pdftotext &>/dev/null; then
    info "  Installing poppler (pdftotext for PDF search)..."
    pacman -S --noconfirm --needed poppler || \
        warn "  poppler install failed — PDF search indexing will be skipped"
else
    info "  pdftotext (poppler): already installed"
fi

# pagefind — static full-text search index generator for the PDF portal
# Install via GitHub release binary (aarch64-musl) — the pip package does not
# reliably place a usable binary on aarch64.
if ! command -v pagefind &>/dev/null; then
    info "  Installing pagefind (static PDF search) from GitHub release..."
    _pf_version=$(curl -sf --max-time 15 \
        "https://api.github.com/repos/CloudCannon/pagefind/releases/latest" \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'].lstrip('v'))" \
        2>/dev/null) || _pf_version="1.3.0"
    info "  pagefind version: ${_pf_version}"
    _pf_url="https://github.com/CloudCannon/pagefind/releases/download/v${_pf_version}/pagefind-v${_pf_version}-aarch64-unknown-linux-musl.tar.gz"
    _pf_tmp=$(mktemp /tmp/pagefind-XXXXXX.tar.gz)
    if curl -L --max-time 60 -o "${_pf_tmp}" "${_pf_url}" 2>/dev/null; then
        tar -xzf "${_pf_tmp}" -C /usr/local/bin/ pagefind 2>/dev/null || \
            tar -xzf "${_pf_tmp}" -C /usr/local/bin/ 2>/dev/null || true
        chmod +x /usr/local/bin/pagefind 2>/dev/null || true
        rm -f "${_pf_tmp}"
        command -v pagefind &>/dev/null && \
            info "  pagefind: installed ($(pagefind --version 2>/dev/null || echo unknown))" || \
            warn "  pagefind binary not found after install — PDF search will be skipped"
    else
        rm -f "${_pf_tmp}"
        warn "  pagefind download failed — PDF search portal will not be built"
        warn "  To install manually: download from https://github.com/CloudCannon/pagefind/releases"
        warn "  and place the aarch64-unknown-linux-musl binary at /usr/local/bin/pagefind"
    fi
else
    info "  pagefind: already installed ($(pagefind --version 2>/dev/null || echo unknown))"
fi

# jellyfin — media server for offline movie playback
# The AUR 'jellyfin' package depends on aspnet-runtime-2.1 which is x86_64-only.
# On aarch64 we download the official glibc arm64 tarball from
# repo.jellyfin.org and install it to /opt/jellyfin.
# Note: use arm64 (glibc), NOT arm64-musl — EndeavourOS uses glibc.
install_jellyfin() {
    local install_dir="/opt/jellyfin"
    local data_dir="/var/lib/jellyfin"
    local cache_dir="/var/cache/jellyfin"
    local log_dir="/var/log/jellyfin"
    local config_dir="/etc/jellyfin"

    # Already installed check — verify binary exists AND actually executes
    local current_ver
    current_ver=$("${install_dir}/jellyfin" --version 2>/dev/null | awk '{print $1}')
    if [[ -n "${current_ver}" ]]; then
        info "  jellyfin: already installed (${current_ver})"
        return 0
    elif [[ -e "${install_dir}/jellyfin" ]]; then
        warn "  jellyfin binary missing or broken (size=$(stat -c%s "${install_dir}/jellyfin" 2>/dev/null || echo '?') bytes) — reinstalling..."
        rm -rf "${install_dir}"
    fi

    info "  jellyfin: not found — installing from official arm64 (glibc) tarball..."

    # Resolve latest stable version
    local jf_version
    jf_version=$(curl -sf --max-time 15 \
        "https://repo.jellyfin.org/files/server/linux/stable/" \
        | grep -oP 'v\K[0-9]+\.[0-9]+\.[0-9]+' | sort -V | tail -1 \
        2>/dev/null) || jf_version="10.11.6"
    info "  jellyfin version: ${jf_version}"

    local jf_url="https://repo.jellyfin.org/files/server/linux/stable/v${jf_version}/arm64/jellyfin_${jf_version}-arm64.tar.gz"
    local jf_tmp
    jf_tmp=$(mktemp /tmp/jellyfin-XXXXXX.tar.gz)

    if ! curl -L --max-time 300 -o "${jf_tmp}" "${jf_url}" 2>/dev/null; then
        warn "  jellyfin download failed — install manually:"
        warn "    ${jf_url}"
        rm -f "${jf_tmp}"
        return 1
    fi

    # Validate zip magic
    if ! python3 -c "
import sys
with open('${jf_tmp}','rb') as f: magic=f.read(2)
sys.exit(0 if magic==b'\x1f\x8b' else 1)
" 2>/dev/null; then
        warn "  jellyfin: downloaded file is not a valid gzip archive — skipping"
        rm -f "${jf_tmp}"
        return 1
    fi

    rm -rf "${install_dir}"
    mkdir -p "${install_dir}"
    tar -xzf "${jf_tmp}" -C "${install_dir}" --strip-components=1
    rm -f "${jf_tmp}"

    if [[ ! -x "${install_dir}/jellyfin" ]]; then
        warn "  jellyfin binary not found after extract — check tarball structure"
        return 1
    fi

    # Create jellyfin system user if needed
    if ! id jellyfin &>/dev/null; then
        useradd -r -m -d "${data_dir}" -s /usr/bin/nologin jellyfin
        info "  Created system user: jellyfin"
    fi

    # Create required directories
    mkdir -p "${data_dir}" "${cache_dir}" "${log_dir}" "${config_dir}"
    chown -R jellyfin:jellyfin "${data_dir}" "${cache_dir}" "${log_dir}" "${config_dir}" "${install_dir}"

    info "  jellyfin: installed to ${install_dir}"
}
install_jellyfin

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

    # Check if already labelled — whole disk or first partition.
    # Use blkid -p (direct probe, bypasses stale udev cache) for reliability.
    local use_dev=""
    for candidate in "${USB_DEV}" "${USB_DEV}1"; do
        if [[ -b "${candidate}" ]] && \
           blkid -p -s LABEL -o value "${candidate}" 2>/dev/null | grep -qx "${USB_LABEL}"; then
            use_dev="${candidate}"
            break
        fi
    done

    # Fallback: check lsblk in case blkid cache is cold
    if [[ -z "${use_dev}" ]]; then
        for candidate in "${USB_DEV}" "${USB_DEV}1"; do
            if [[ -b "${candidate}" ]] && \
               lsblk -no LABEL "${candidate}" 2>/dev/null | grep -qx "${USB_LABEL}"; then
                use_dev="${candidate}"
                break
            fi
        done
    fi

    if [[ -z "${use_dev}" ]]; then
        # Safety gate: if ANY filesystem signature exists on the device, refuse to format.
        # This prevents accidental data loss on a drive that simply has a different label.
        local existing_type
        existing_type=$(blkid -p -s TYPE -o value "${USB_DEV}" 2>/dev/null || true)
        if [[ -n "${existing_type}" ]]; then
            warn "  SAFETY STOP: ${USB_DEV} has an existing ${existing_type} filesystem"
            warn "  but its label is not '${USB_LABEL}'. Refusing to format."
            warn "  If this is the correct drive, relabel it manually:"
            warn "    e2label ${USB_DEV} ${USB_LABEL}"
            warn "  Then re-run install.sh."
            return 0
        fi

        # Truly blank disk — safe to format
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

# ── step 2b: configure NFS mount for TrueNAS book share ──────────────────────
info "Step 2b: Configuring NFS mount for TrueNAS book share"

NFS_HOST="truenas.home"
NFS_EXPORT="/mnt/hdd/books"
NFS_MOUNT="/mnt/truenas-books"
NFS_FSTAB_ENTRY="${NFS_HOST}:${NFS_EXPORT}  ${NFS_MOUNT}  nfs  ro,soft,timeo=30,retrans=2,noauto,x-systemd.automount,x-systemd.mount-timeout=30  0  0"
NFS_FSTAB_MARKER="survive-sync: truenas book share"

# Ensure nfs-utils is installed
if ! command -v mount.nfs &>/dev/null; then
    info "  Installing nfs-utils..."
    pacman -S --noconfirm --needed nfs-utils || \
        warn "  nfs-utils install failed — NFS mount will not work"
fi

mkdir -p "${NFS_MOUNT}"

# Add fstab entry (idempotent — only once)
if grep -qF "${NFS_FSTAB_MARKER}" /etc/fstab 2>/dev/null; then
    info "  fstab: NFS entry already present"
else
    {
        echo ""
        echo "# ${NFS_FSTAB_MARKER}"
        echo "${NFS_FSTAB_ENTRY}"
    } >> /etc/fstab
    info "  fstab: added NFS entry (${NFS_HOST}:${NFS_EXPORT} → ${NFS_MOUNT})"
fi

# Attempt a test mount to verify connectivity (non-fatal)
if mountpoint -q "${NFS_MOUNT}" 2>/dev/null; then
    info "  ${NFS_MOUNT}: already mounted"
else
    info "  Testing NFS connectivity to ${NFS_HOST}..."
    if mount -t nfs -o ro,soft,timeo=30,retrans=2 \
            "${NFS_HOST}:${NFS_EXPORT}" "${NFS_MOUNT}" 2>/dev/null; then
        EPUB_COUNT=$(find "${NFS_MOUNT}" -maxdepth 3 -name "*.epub" 2>/dev/null | wc -l)
        info "  ${NFS_MOUNT}: mounted OK — ${EPUB_COUNT} EPUB(s) visible"
    else
        warn "  ${NFS_MOUNT}: could not mount now (TrueNAS may be offline)"
        warn "  The fstab entry uses x-systemd.automount — it will mount on first access"
        warn "  To test manually: sudo mount ${NFS_MOUNT}"
    fi
fi

# ── step 2c: NFS mount for TrueNAS classics video share ───────────────────────
info "Step 2c: Configuring NFS mount for TrueNAS classics share"

CLASSICS_NFS_EXPORT="/mnt/hdd/media-classics"
CLASSICS_NFS_MOUNT="/mnt/media-classics"
CLASSICS_FSTAB_ENTRY="${NFS_HOST}:${CLASSICS_NFS_EXPORT}  ${CLASSICS_NFS_MOUNT}  nfs  ro,soft,timeo=30,retrans=2,noauto,x-systemd.automount,x-systemd.mount-timeout=30  0  0"
CLASSICS_FSTAB_MARKER="survive-sync: truenas classics share"

mkdir -p "${CLASSICS_NFS_MOUNT}"

if grep -qF "${CLASSICS_FSTAB_MARKER}" /etc/fstab 2>/dev/null; then
    info "  fstab: classics NFS entry already present"
else
    {
        echo ""
        echo "# ${CLASSICS_FSTAB_MARKER}"
        echo "${CLASSICS_FSTAB_ENTRY}"
    } >> /etc/fstab
    info "  fstab: added NFS entry (${NFS_HOST}:${CLASSICS_NFS_EXPORT} → ${CLASSICS_NFS_MOUNT})"
fi

if mountpoint -q "${CLASSICS_NFS_MOUNT}" 2>/dev/null; then
    info "  ${CLASSICS_NFS_MOUNT}: already mounted"
else
    info "  Testing NFS connectivity for classics share..."
    if mount -t nfs -o ro,soft,timeo=30,retrans=2 \
            "${NFS_HOST}:${CLASSICS_NFS_EXPORT}" "${CLASSICS_NFS_MOUNT}" 2>/dev/null; then
        VID_COUNT=$(find "${CLASSICS_NFS_MOUNT}" -maxdepth 2 \( -name "*.mkv" -o -name "*.mp4" -o -name "*.avi" \) 2>/dev/null | wc -l)
        info "  ${CLASSICS_NFS_MOUNT}: mounted OK — ${VID_COUNT} video file(s) visible"
    else
        warn "  ${CLASSICS_NFS_MOUNT}: could not mount now (TrueNAS may be offline)"
        warn "  The fstab entry uses x-systemd.automount — it will mount on first access"
        warn "  To test manually: sudo mount ${CLASSICS_NFS_MOUNT}"
    fi
fi


# ── step 3: create directory structure ────────────────────────────────────────
info "Step 3: Creating directory structure under ${OFFLINE_ROOT}"

# Ensure library user exists (spec §6)
if ! id library &>/dev/null; then
    useradd -r -m -d /var/lib/library -s /usr/bin/nologin library
    info "  Created system user: library"
else
    info "  User library: exists"
fi

# jellyfin reads media from /srv/offline — add it to the library group
usermod -aG library jellyfin 2>/dev/null && \
    info "  jellyfin added to library group (can read /srv/offline)" || \
    warn "  Could not add jellyfin to library group — media scans may fail"

# joe needs library group membership to write logs during interactive sync runs
usermod -aG library joe 2>/dev/null && \
    info "  joe added to library group (can write logs interactively)" || \
    warn "  Could not add joe to library group — interactive sync logs may not write"

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
    "${OFFLINE_ROOT}/pdfs/13-cbrn"
    "${OFFLINE_ROOT}/pdfs/14-transport"
    "${OFFLINE_ROOT}/pdfs/15-leadership"
    "${OFFLINE_ROOT}/pdfs/16-maritime"
    "${OFFLINE_ROOT}/pdfs/17-weather"
    "${OFFLINE_ROOT}/pdfs/18-firearms"
    "${OFFLINE_ROOT}/pdfs/19-logistics"
    "${OFFLINE_ROOT}/pdfs/20-classics"
    "${OFFLINE_ROOT}/pdfs/21-engineering"
    "${OFFLINE_ROOT}/pdfs/22-usmc"
    "${OFFLINE_ROOT}/books/epub"
    "${OFFLINE_ROOT}/books/calibre-library"
    "${OFFLINE_ROOT}/maps/tiles"
    "${OFFLINE_ROOT}/maps/pbf"
    "${OFFLINE_ROOT}/maps/topo"
    "${OFFLINE_ROOT}/video/first-aid"
    "${OFFLINE_ROOT}/video/repair"
    "${OFFLINE_ROOT}/video/power"
    "${OFFLINE_ROOT}/video/food"
    "${OFFLINE_ROOT}/video/morale"
    "${OFFLINE_ROOT}/video/agriculture"
    "${OFFLINE_ROOT}/video/shelter"
    "${OFFLINE_ROOT}/video/classics"
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

# Initialize Calibre library if not already done.
# calibre-server refuses to start if metadata.db doesn't exist — it does NOT
# auto-create the library from an empty directory.
CALIBRE_LIB="${OFFLINE_ROOT}/books/calibre-library"
if [[ ! -f "${CALIBRE_LIB}/metadata.db" ]]; then
    info "  Initializing empty Calibre library..."
    chown library:library "${CALIBRE_LIB}"
    _dummy=$(mktemp /tmp/calibre-init-XXXXXX.txt)
    echo "init" > "${_dummy}"
    sudo -u library calibredb add --with-library "${CALIBRE_LIB}" "${_dummy}" \
        > /dev/null 2>&1 && \
        sudo -u library calibredb remove --with-library "${CALIBRE_LIB}" 1 \
        > /dev/null 2>&1 || true
    rm -f "${_dummy}"
    [[ -f "${CALIBRE_LIB}/metadata.db" ]] && \
        info "  Calibre library: initialized (empty)" || \
        warn "  Calibre library init failed — books service may not start"
else
    info "  Calibre library: already present"
fi

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

find "${SCRIPTS_DST}/sync"        -maxdepth 1 -name "*.sh" -exec chmod +x {} +
find "${SCRIPTS_DST}/postprocess" -maxdepth 1 -name "*.sh" -exec chmod +x {} +
find "${SCRIPTS_DST}/admin"       -maxdepth 1 -name "*.sh" -exec chmod +x {} + 2>/dev/null || true

# Copy portal assets — both to live location and to scripts dir (so sync-all.sh can re-deploy)
cp -r "${SCRIPT_DIR}/portal/." "${PORTAL_DST}/"
mkdir -p "${SCRIPTS_DST}/portal"
cp -r "${SCRIPT_DIR}/portal/." "${SCRIPTS_DST}/portal/"

info "  Scripts and portal assets: OK"

# ── step 5: download MapLibre GL JS (offline dependency) ─────────────────────
info "Step 5: Downloading MapLibre GL JS for offline map viewer"

MAPLIBRE_JS="${PORTAL_DST}/maps/maplibre-gl.js"
MAPLIBRE_CSS="${PORTAL_DST}/maps/maplibre-gl.css"

if [[ -f "${MAPLIBRE_JS}" ]] && [[ $(stat -c%s "${MAPLIBRE_JS}" 2>/dev/null || echo 0) -gt 100000 ]]; then
    info "  MapLibre GL JS: already present"
else
    info "  Fetching latest MapLibre GL JS release..."
    ML_VERSION=$(curl -sf --max-time 15 \
        "https://api.github.com/repos/maplibre/maplibre-gl-js/releases/latest" \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'].lstrip('v'))" \
        2>/dev/null) || ML_VERSION="5.21.0"
    info "  MapLibre GL JS version: ${ML_VERSION}"

    # Since v5, MapLibre ships a single dist.zip instead of individual files.
    ML_ZIP_URL="https://github.com/maplibre/maplibre-gl-js/releases/download/v${ML_VERSION}/dist.zip"
    ML_TMP_ZIP="$(mktemp /tmp/maplibre-dist-XXXXXX.zip)"
    if curl -L --max-time 120 -o "${ML_TMP_ZIP}" "${ML_ZIP_URL}"; then
        unzip -p "${ML_TMP_ZIP}" dist/maplibre-gl.js  > "${MAPLIBRE_JS}"  || warn "  dist/maplibre-gl.js not found in dist.zip"
        unzip -p "${ML_TMP_ZIP}" dist/maplibre-gl.css > "${MAPLIBRE_CSS}" || warn "  dist/maplibre-gl.css not found in dist.zip"
        rm -f "${ML_TMP_ZIP}"
    else
        warn "  Failed to download MapLibre dist.zip — map viewer requires manual install"
        rm -f "${ML_TMP_ZIP}"
    fi
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
cp "${SCRIPT_DIR}/systemd/survive-books.service"   "${SYSTEMD_DIR}/"
cp "${SCRIPT_DIR}/systemd/survive-books.timer"     "${SYSTEMD_DIR}/"
cp "${SCRIPT_DIR}/systemd/jellyfin.service"        "${SYSTEMD_DIR}/"

systemctl daemon-reload

# Explicitly restart each service so updated unit files (and any changed flags)
# take effect immediately, not just on next boot.
for svc in kiwix.service calibre-server.service mbtileserver.service; do
    systemctl enable "${svc}" 2>/dev/null || true
    systemctl reset-failed "${svc}" 2>/dev/null || true
    systemctl restart "${svc}" && \
        info "  ${svc}: enabled and restarted" || \
        warn "  ${svc}: restart failed (check: systemctl status ${svc})"
done

# Jellyfin — enable and start (tarball install to /opt/jellyfin)
if [[ -x /opt/jellyfin/jellyfin ]]; then
    systemctl enable jellyfin 2>/dev/null || true
    systemctl reset-failed jellyfin 2>/dev/null || true
    systemctl restart jellyfin && \
        info "  jellyfin.service: enabled and restarted" || \
        warn "  jellyfin.service: restart failed (check: systemctl status jellyfin)"
fi

systemctl enable survive-sync.timer && \
    info "  survive-sync.timer: enabled" || \
    warn "  survive-sync.timer: enable failed"

systemctl enable survive-books.timer && \
    info "  survive-books.timer: enabled (hourly NAS book ingest)" || \
    warn "  survive-books.timer: enable failed"

# Start the timers (does not start the services immediately)
systemctl start survive-sync.timer 2>/dev/null || true
systemctl start survive-books.timer 2>/dev/null || true

info "  Systemd units: OK"
info "  Next sync: $(systemctl show survive-sync.timer --property=NextElapseUSecRealtime 2>/dev/null | cut -d= -f2 || echo unknown)"
info "  Manual trigger: systemctl start survive-sync.service"

# ── step 8: install / patch Caddyfile ────────────────────────────────────────
info "Step 8: Configuring Caddy"

# Always write our Caddyfile — backs up the existing file first if it doesn't
# already look like ours (no survive-sync marker).
mkdir -p "$(dirname "${CADDY_CONF}")"
if [[ -f "${CADDY_CONF}" ]] && ! grep -q 'survive-sync' "${CADDY_CONF}"; then
    cp "${CADDY_CONF}" "${CADDY_CONF}.bak-$(date +%Y%m%d%H%M%S)"
    info "  Backed up existing Caddyfile"
fi
cat > "${CADDY_CONF}" <<'CADDYFILE'
# SURVIVE offline library — Caddy portal and reverse proxy
# survive-sync — generated by install.sh

:80 {
    # Wikipedia — Kiwix ZIM server (urlroot /wiki)
    handle /wiki* {
        reverse_proxy 127.0.0.1:8080
    }

    # Books — Calibre content server (url-prefix /books)
    handle /books* {
        reverse_proxy 127.0.0.1:8081
    }

    # Map tile proxy — mbtileserver on port 8082
    handle /maps/tiles/* {
        uri strip_prefix /maps/tiles
        reverse_proxy 127.0.0.1:8082
    }

    # Map file downloads (.mbtiles for OsmAnd / Locus Map)
    handle /maps/download/* {
        root * /srv/offline/maps/tiles
        uri strip_prefix /maps/download
        file_server browse
    }

    # Topo map downloads (USGS GeoPDF quads for ATAK / offline use)
    handle /maps/topo/* {
        root * /srv/offline/maps/topo
        uri strip_prefix /maps/topo
        file_server browse
    }

    # PDF guides and manuals
    handle /pdfs/* {
        root * /srv/offline/pdfs
        uri strip_prefix /pdfs
        file_server browse
    }

    # Video files
    handle /video/* {
        root * /srv/offline/video
        uri strip_prefix /video
        file_server browse
    }

    # Portal — static files
    root * /srv/offline/portal
    file_server
}
CADDYFILE
info "  Caddyfile written to ${CADDY_CONF}"

# Enable and (re)start Caddy — always restart so the running process picks up
# the current Caddyfile, regardless of whether we wrote it this run or a
# previous one.
systemctl enable caddy 2>/dev/null || true
# Reset any systemd failure count before restarting — if caddy previously crashed
# and hit the restart rate-limit, systemd will refuse to start it without this.
systemctl reset-failed caddy.service 2>/dev/null || true
systemctl restart caddy && \
    info "  caddy.service: restarted OK" || \
    warn "  caddy restart failed — check: systemctl status caddy"

# ── step 9: firewall ──────────────────────────────────────────────────────────
# survive is a trusted LAN appliance — the edge router (UDR7 / Beryl AX)
# provides perimeter protection. A local host firewall only causes pain.
info "Step 9: Disabling local firewall (edge router provides protection)"
systemctl disable --now nftables 2>/dev/null || true
systemctl disable --now firewalld 2>/dev/null || true
nft flush ruleset 2>/dev/null || true
info "  nftables/firewalld disabled and ruleset flushed"

# ── step 10: ownership ────────────────────────────────────────────────────────
info "Step 10: Setting ownership"
chown -R library:library "${OFFLINE_ROOT}"
chmod 775 "${OFFLINE_ROOT}/logs"
info "  ${OFFLINE_ROOT}: owned by library:library"
info "  ${OFFLINE_ROOT}/logs: group-writable (775)"

# ── step 11: allow library user to restart services via sudo ──────────────────
info "Step 11: Configuring sudo for service restarts"

SUDOERS_FILE="/etc/sudoers.d/survive-sync"
cat > "${SUDOERS_FILE}" <<'SUDOERS'
# Allow the library user to restart content services after a sync
library ALL=(root) NOPASSWD: /usr/bin/systemctl restart kiwix.service
library ALL=(root) NOPASSWD: /usr/bin/systemctl restart calibre-server.service
library ALL=(root) NOPASSWD: /usr/bin/systemctl restart caddy.service
library ALL=(root) NOPASSWD: /usr/bin/systemctl restart mbtileserver.service
# Allow stop/start for calibre-server (needed by sync-books.sh to avoid library lock conflict)
library ALL=(root) NOPASSWD: /usr/bin/systemctl stop calibre-server.service
library ALL=(root) NOPASSWD: /usr/bin/systemctl start calibre-server.service
# Allow starting the NFS automount units for NAS shares
library ALL=(root) NOPASSWD: /usr/bin/systemctl start mnt-truenas-books.mount
library ALL=(root) NOPASSWD: /usr/bin/systemctl start mnt-media-classics.mount
SUDOERS
chmod 0440 "${SUDOERS_FILE}"
info "  Sudoers: ${SUDOERS_FILE}"

# ── step 12: install login welcome message ────────────────────────────────────
info "Step 12: Installing login welcome script"
WELCOME_SRC="${SCRIPT_DIR}/scripts/survive-welcome.sh"
WELCOME_DST="/etc/profile.d/survive-welcome.sh"
if [[ -f "${WELCOME_SRC}" ]]; then
    install -m 0644 "${WELCOME_SRC}" "${WELCOME_DST}"
    info "  Installed: ${WELCOME_DST}"
else
    warn "  ${WELCOME_SRC} not found — skipping"
fi

# ── summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  survive-sync install complete${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
echo ""
echo "Scripts installed to:  ${SCRIPTS_DST}"
echo "Portal:                http://survive.travel  (or http://192.168.8.2)"
echo "Map tiles directory:   ${MAPS_TILES_DIR}"
echo "NFS book share:        ${NFS_MOUNT:-/mnt/truenas-books}  (ro, automount on access)"
echo "NFS classics share:    ${CLASSICS_NFS_MOUNT:-/mnt/media-classics}  (ro, automount on access)"
echo ""
echo "Systemd units installed:"
echo "  srv-offline.mount      (auto-mounts USB drive at /srv/offline on boot)"
echo "  kiwix.service          (port 8080 — Wikipedia/ZIM)"
echo "  calibre-server.service (port 8081 — books)"
echo "  mbtileserver.service   (port 8082 — map tiles)"
echo "  jellyfin.service       (port 8096 — classic movies)"
echo "  survive-sync.service   (oneshot — runs sync-all.sh)"
echo "  survive-sync.timer     (weekly, Sunday 02:00)"
echo "  survive-books.service  (oneshot — runs sync-books.sh only)"
echo "  survive-books.timer    (every 30 min — NAS book ingest)"
echo ""
echo "Run a sync manually:"
echo "  sudo systemctl start survive-sync.service"
echo "  journalctl -u survive-sync -f"
echo ""
echo "Books-only sync:"
echo "  sudo systemctl start survive-books.service"
echo "  journalctl -u survive-books -f"
echo ""
echo "Or run individual modules:"
echo "  sudo SYNC_MODULES='pdfs books' systemctl start survive-sync.service"
echo ""
echo "Next steps:"
echo "  1. Open http://survive.travel:8096 and complete Jellyfin setup wizard"
echo "  2. Add /srv/offline/video/classics/ as a Jellyfin media library"
echo "  3. Run a full sync: sudo systemctl start survive-sync.service"
echo "  4. Wikipedia ZIM is ~100 GB — first sync will take hours"
echo ""
