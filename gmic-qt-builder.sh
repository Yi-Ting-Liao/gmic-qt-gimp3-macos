#!/usr/bin/env bash
set -euo pipefail

# ── Resolve script/project directories early ──────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Defaults (all overridable via env vars or CLI flags) ──────────────────
GIMP_APP="${GIMP_APP:-/Applications/GIMP.app}"
GMIC_VERSION="${GMIC_VERSION:-3.7.0}"
WORKDIR="${WORKDIR:-${PROJECT_DIR}/work}"
OUTDIR="${OUTDIR:-${PROJECT_DIR}/dist}"
MACPORTS_PREFIX="${MACPORTS_PREFIX:-/opt/local}"
QT_PREFIX="${QT_PREFIX:-${MACPORTS_PREFIX}/libexec/qt5}"
GIMP_HEADERS_DIR="${GIMP_HEADERS_DIR:-${MACPORTS_PREFIX}/include}"
GIMP_API_VERSION="${GIMP_API_VERSION:-3.0}"
SKIP_PORTS=0
SKIP_GIMP3_DEVEL=1
INSTALL_PLUGIN=0
CLEAN=0

# ── Logging helpers ───────────────────────────────────────────────────────
log()  { echo "[gmic-qt-builder] $*" >&2; }
warn() { echo "[gmic-qt-builder] WARNING: $*" >&2; }
die()  { echo "[gmic-qt-builder] ERROR: $*" >&2; exit 1; }

# ── Cleanup on error ─────────────────────────────────────────────────────
trap 'log "Build failed."' ERR

# ── Usage ─────────────────────────────────────────────────────────────────
usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Options:
  --gimp-app <path>       Path to GIMP.app (default: /Applications/GIMP.app)
  --gmic-version <ver>    G'MIC version (default: 3.7.0)
  --workdir <path>        Working directory
  --outdir <path>         Output directory for bundle/zip
  --macports-prefix <p>   MacPorts prefix (default: /opt/local)
  --skip-ports            Do not install MacPorts deps
  --skip-gimp3-devel      Do not attempt to install gimp3-devel (use source headers fallback)
  --install               Also copy bundle to user plugin directory
  --clean                 Remove workdir and build artifacts before building
  -h, --help              Show help
USAGE
}

# ── Argument parsing ─────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --gimp-app) GIMP_APP="$2"; shift 2;;
    --gmic-version) GMIC_VERSION="$2"; shift 2;;
    --workdir) WORKDIR="$2"; shift 2;;
    --outdir) OUTDIR="$2"; shift 2;;
    --macports-prefix) MACPORTS_PREFIX="$2"; QT_PREFIX="${MACPORTS_PREFIX}/libexec/qt5"; shift 2;;
    --skip-ports) SKIP_PORTS=1; shift;;
    --skip-gimp3-devel) SKIP_GIMP3_DEVEL=1; shift;;
    --install) INSTALL_PLUGIN=1; shift;;
    --clean) CLEAN=1; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown option: $1" >&2; usage; exit 1;;
  esac
done

# ── Helper functions ──────────────────────────────────────────────────────

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    die "Missing command: $1"
  fi
}

# Detect GIMP version from Info.plist (headless-safe) or gimp --version (fallback).
# Arguments: $1 = path to GIMP.app, $2 = path to gimp binary (optional)
detect_gimp_version() {
  local app="$1"
  local bin="${2:-}"
  local plist="$app/Contents/Info.plist"
  local ver=""
  # Method 1: PlistBuddy (works headless, no display needed)
  if [[ -f "$plist" ]] && command -v /usr/libexec/PlistBuddy >/dev/null 2>&1; then
    ver="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$plist" 2>/dev/null || true)"
  fi
  # Method 2: gimp --version (may fail in headless CI)
  if [[ -z "$ver" && -n "$bin" && -x "$bin" ]]; then
    ver="$("$bin" --version 2>/dev/null | awk '/version/ {print $NF; exit}' || true)"
  fi
  # No version detected — cannot continue safely
  if [[ -z "$ver" ]]; then
    die "Could not detect GIMP version from $app. Ensure Info.plist has CFBundleShortVersionString."
  fi
  echo "$ver"
}

# Resolve a dylib path by glob pattern. Returns the first match.
# Arguments: $1 = directory, $2 = glob pattern (e.g. "libpng*.dylib")
find_dylib() {
  local dir="$1"
  local pattern="$2"
  local result
  result="$(find "$dir" -maxdepth 1 -name "$pattern" -not -name '*-*' 2>/dev/null | head -1)"
  if [[ -z "$result" ]]; then
    die "Could not find dylib matching '$pattern' in $dir"
  fi
  echo "$result"
}

# Generate gimpversion.h from GIMP source tree.
# Arguments: $1 = GIMP source dir, $2 = destination header dir, $3 = GIMP version string
generate_gimpversion_h() {
  local gimp_src_dir="$1"
  local header_dst="$2"
  local src_version="$3"
  local template="$gimp_src_dir/libgimpbase/gimpversion.h.in"

  if [[ ! -f "$template" ]]; then
    warn "gimpversion.h.in template not found at $template; skipping generation."
    return
  fi

  local ver_major ver_minor ver_micro_rest ver_micro api_version
  IFS='.' read -r ver_major ver_minor ver_micro_rest <<< "$src_version"
  ver_micro="$(echo "$ver_micro_rest" | sed 's/[^0-9].*$//')"
  ver_major="${ver_major:-3}"
  ver_minor="${ver_minor:-0}"
  ver_micro="${ver_micro:-0}"
  api_version="${ver_major}.0"

  cat > "$header_dst/libgimpbase/gimpversion.h" <<EOF_GIMPVERSION
#ifndef __GIMP_VERSION_H__
#define __GIMP_VERSION_H__

/* gimpversion.h.in -> gimpversion.h
 * This file is configured by the build script.
 */
#if !defined (__GIMP_BASE_H_INSIDE__) && !defined (GIMP_BASE_COMPILATION)
#error "Only <libgimpbase/gimpbase.h> can be included directly."
#endif

G_BEGIN_DECLS

#define GIMP_MAJOR_VERSION                              (${ver_major})
#define GIMP_MINOR_VERSION                              (${ver_minor})
#define GIMP_MICRO_VERSION                              (${ver_micro})
#define GIMP_VERSION                                    "${src_version}"
#define GIMP_API_VERSION                                "${api_version}"

#define GIMP_CHECK_VERSION(major, minor, micro) \\
    (GIMP_MAJOR_VERSION > (major) || \\
     (GIMP_MAJOR_VERSION == (major) && GIMP_MINOR_VERSION > (minor)) || \\
     (GIMP_MAJOR_VERSION == (major) && GIMP_MINOR_VERSION == (minor) && \\
      GIMP_MICRO_VERSION >= (micro)))

G_END_DECLS

#endif /* __GIMP_VERSION_H__ */
EOF_GIMPVERSION
}

# ── Validate GIMP.app ────────────────────────────────────────────────────
[[ -d "$GIMP_APP" ]] || die "GIMP.app not found at: $GIMP_APP"

GIMP_BIN="$GIMP_APP/Contents/MacOS/gimp"
[[ -x "$GIMP_BIN" ]] || die "GIMP binary not found: $GIMP_BIN"

# Cache GIMP version (called once, reused everywhere)
GIMP_APP_VERSION="$(detect_gimp_version "$GIMP_APP" "$GIMP_BIN")"
log "Detected GIMP version: $GIMP_APP_VERSION"

# ── Clean mode ──────────────────────────────────────────────────────────
if [[ $CLEAN -eq 1 ]]; then
  log "Cleaning work and build directories..."
  rm -rf "$WORKDIR" "$OUTDIR"
fi

mkdir -p "$WORKDIR" "$OUTDIR"

# ── Architecture detection ────────────────────────────────────────────────
GIMP_ARCH="$(file "$GIMP_BIN")"
HOST_ARCH="$(uname -m)"

if echo "$GIMP_ARCH" | grep -q "x86_64"; then
  DETECTED_ARCH="x86_64"
elif echo "$GIMP_ARCH" | grep -q "arm64"; then
  DETECTED_ARCH="arm64"
else
  DETECTED_ARCH="$HOST_ARCH"
  warn "Could not detect GIMP.app architecture from binary: $GIMP_ARCH"
fi
if [[ "$DETECTED_ARCH" != "$HOST_ARCH" ]]; then
  warn "GIMP.app architecture ($DETECTED_ARCH) differs from host ($HOST_ARCH)."
  warn "Ensure MacPorts and GIMP.app architectures match (or use Rosetta)."
fi

# ── Install MacPorts dependencies ───────────────────────────────────────
if [[ $SKIP_PORTS -eq 0 ]]; then
  require_cmd port
  sudo port -N install cmake pkgconfig qt5-qtbase qt5-qttools fftw-3 libomp dbus gdk-pixbuf2 cairo gegl glib2
  if [[ $SKIP_GIMP3_DEVEL -eq 0 && ! -f "${GIMP_HEADERS_DIR}/gimp-${GIMP_API_VERSION}/libgimp/gimp.h" ]]; then
    sudo port -N install gimp3-devel || true
  fi
fi

require_cmd cmake
require_cmd pkg-config
require_cmd python3
require_cmd curl
require_cmd tar
require_cmd otool
require_cmd install_name_tool
require_cmd ditto

# ── GIMP headers fallback ────────────────────────────────────────────────
if [[ ! -f "${GIMP_HEADERS_DIR}/gimp-${GIMP_API_VERSION}/libgimp/gimp.h" ]]; then
  log "GIMP headers not found at: ${GIMP_HEADERS_DIR}/gimp-${GIMP_API_VERSION}"
  log "Falling back to GIMP source tarball headers..."

  # Derive download URL from detected version (e.g., 3.0.x → v3.0, 3.2.x → v3.2)
  IFS='.' read -r _gmajor _gminor _ <<< "$GIMP_APP_VERSION"
  GIMP_SRC_URL="https://download.gimp.org/pub/gimp/v${_gmajor}.${_gminor}/gimp-${GIMP_APP_VERSION}.tar.xz"

  GIMP_SRC_DIR="$WORKDIR/gimp-${GIMP_APP_VERSION}"
  GIMP_SRC_TAR="$WORKDIR/gimp-${GIMP_APP_VERSION}.tar.xz"
  if [[ ! -d "$GIMP_SRC_DIR" ]]; then
    log "Downloading GIMP source: $GIMP_SRC_URL"
    curl -L -o "$GIMP_SRC_TAR" "$GIMP_SRC_URL"
    tar -xJf "$GIMP_SRC_TAR" -C "$WORKDIR"
  fi

  HEADER_DST="$WORKDIR/gimp-headers/include/gimp-${GIMP_API_VERSION}"
  rm -rf "$WORKDIR/gimp-headers"
  mkdir -p "$HEADER_DST"

  # Dynamically scan for libgimp* directories in source
  found_headers=0
  for d in "$GIMP_SRC_DIR"/libgimp*; do
    if [[ -d "$d" ]]; then
      cp -R "$d" "$HEADER_DST/"
      found_headers=1
    fi
  done
  if [[ $found_headers -eq 0 ]]; then
    die "No libgimp* directories found in GIMP source: $GIMP_SRC_DIR"
  fi

  generate_gimpversion_h "$GIMP_SRC_DIR" "$HEADER_DST" "$GIMP_APP_VERSION"

  GIMP_HEADERS_DIR="$WORKDIR/gimp-headers/include"
  if [[ ! -f "${GIMP_HEADERS_DIR}/gimp-${GIMP_API_VERSION}/libgimp/gimp.h" ]]; then
    die "GIMP headers still missing after source fallback. Please install gimp3-devel via MacPorts."
  fi
fi

# ── Verify required pkg-config modules ──────────────────────────────────
missing_pkgs=()
for pkg in gdk-pixbuf-2.0 cairo gegl-0.4 glib-2.0 gobject-2.0; do
  if ! pkg-config --exists "$pkg" >/dev/null 2>&1; then
    missing_pkgs+=("$pkg")
  fi
done
if [[ ${#missing_pkgs[@]} -gt 0 ]]; then
  die "Missing pkg-config modules: ${missing_pkgs[*]}. Install via MacPorts: sudo port -N install gdk-pixbuf2 cairo gegl glib2 (or re-run without --skip-ports)."
fi

# ── Download G'MIC source ────────────────────────────────────────────────
GMIC_TARBALL="$WORKDIR/gmic_${GMIC_VERSION}.tar.gz"
GMIC_SRC="$WORKDIR/gmic-${GMIC_VERSION}"

if [[ ! -d "$GMIC_SRC" ]]; then
  log "Downloading G'MIC ${GMIC_VERSION}..."
  curl -L -o "$GMIC_TARBALL" "https://gmic.eu/files/source/gmic_${GMIC_VERSION}.tar.gz"
  tar -xzf "$GMIC_TARBALL" -C "$WORKDIR"
fi

# ── Generate pkg-config for GIMP.app ────────────────────────────────────
PKGDIR="$WORKDIR/gimpapp-pkgconfig"
mkdir -p "$PKGDIR"

sed -e "s|@GIMP_APP@|${GIMP_APP}|g" \
    -e "s|@GIMP_HEADERS_DIR@|${GIMP_HEADERS_DIR}|g" \
    -e "s|@HOME@|${HOME}|g" \
    -e "s|@GIMP_APP_VERSION@|${GIMP_APP_VERSION}|g" \
    "$SCRIPT_DIR/gimp-3.0.pc.in" > "$PKGDIR/gimp-${GIMP_API_VERSION}.pc"

export PKG_CONFIG_PATH="$PKGDIR:${MACPORTS_PREFIX}/lib/pkgconfig"

# ── Resolve dylib paths dynamically ────────────────────────────────────
GIMP_LIB_DIR="$GIMP_APP/Contents/Resources/lib"
PNG_LIBRARY="$(find_dylib "$GIMP_LIB_DIR" "libpng*.dylib")"
ZLIB_LIBRARY="$(find_dylib "$GIMP_LIB_DIR" "libz.*.dylib")"
CURL_LIBRARY="$(find_dylib "$GIMP_LIB_DIR" "libcurl.*.dylib")"

# ── CMake configure ─────────────────────────────────────────────────────
BUILD_DIR="$WORKDIR/build-gimpapp"
mkdir -p "$BUILD_DIR"

log "Configuring CMake..."
cmake -S "$GMIC_SRC/gmic-qt" -B "$BUILD_DIR" -G "Unix Makefiles" \
  -DGMIC_QT_HOST=gimp3 \
  -DENABLE_SYSTEM_GMIC=OFF \
  -DENABLE_LTO=OFF \
  -DGMIC_PATH="$GMIC_SRC/src" \
  -DGMIC_LIB_PATH="${MACPORTS_PREFIX}/lib" \
  -DCMAKE_PREFIX_PATH="${GIMP_APP}/Contents/Resources;${QT_PREFIX};${MACPORTS_PREFIX}" \
  -DCMAKE_INSTALL_PREFIX="${GIMP_APP}/Contents/Resources" \
  -DCMAKE_INSTALL_RPATH="${GIMP_APP}/Contents/Resources" \
  -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON \
  -DPNG_LIBRARY="$PNG_LIBRARY" \
  -DZLIB_LIBRARY="$ZLIB_LIBRARY" \
  -DCURL_LIBRARY="$CURL_LIBRARY" \
  -DFFTW3_INCLUDE_DIR="${MACPORTS_PREFIX}/include" \
  -DFFTW3_LIBRARY_CORE="${MACPORTS_PREFIX}/lib/libfftw3.dylib" \
  -DFFTW3_LIBRARY_THREADS="${MACPORTS_PREFIX}/lib/libfftw3_threads.dylib" \
  -DOpenMP_C_FLAGS="-Xclang -fopenmp -I${MACPORTS_PREFIX}/include/libomp" \
  -DOpenMP_CXX_FLAGS="-Xclang -fopenmp -I${MACPORTS_PREFIX}/include/libomp" \
  -DOpenMP_C_LIB_NAMES="omp" \
  -DOpenMP_CXX_LIB_NAMES="omp" \
  -DOpenMP_C_INCLUDE_DIR="${MACPORTS_PREFIX}/include/libomp" \
  -DOpenMP_CXX_INCLUDE_DIR="${MACPORTS_PREFIX}/include/libomp" \
  -DOpenMP_omp_LIBRARY="${MACPORTS_PREFIX}/lib/libomp/libomp.dylib" \
  -DOpenMP_libomp_LIBRARY="${MACPORTS_PREFIX}/lib/libomp/libomp.dylib"

# ── Build ─────────────────────────────────────────────────────────────────
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

log "Building with $JOBS parallel jobs..."
cmake --build "$BUILD_DIR" --parallel "$JOBS"

PLUGIN_BUILD_BIN="$BUILD_DIR/gmic_gimp_qt"
[[ -x "$PLUGIN_BUILD_BIN" ]] || die "Build output not found: $PLUGIN_BUILD_BIN"

# ── Bundle ────────────────────────────────────────────────────────────────
BUNDLE_DIR="$OUTDIR/gmic_gimp_qt"
rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR"

cp "$PLUGIN_BUILD_BIN" "$BUNDLE_DIR/gmic_gimp_qt"
PLUGIN_BIN="$BUNDLE_DIR/gmic_gimp_qt"

python3 "$SCRIPT_DIR/bundle_libs.py" \
  --bundle-dir "$BUNDLE_DIR" \
  --plugin-bin "$PLUGIN_BIN" \
  --qt-prefix "$QT_PREFIX" \
  --gimp-app "$GIMP_APP" \
  --macports-prefix "$MACPORTS_PREFIX"

# Include upstream license file in the bundle
GMIC_QT_COPYING="$GMIC_SRC/gmic-qt/COPYING"
if [[ -f "$GMIC_QT_COPYING" ]]; then
  cp "$GMIC_QT_COPYING" "$BUNDLE_DIR/COPYING"
else
  warn "COPYING file not found in gmic-qt source; license file not included in bundle."
fi

BUILD_ARCH="${DETECTED_ARCH:-$(uname -m)}"
ZIP_PATH="$OUTDIR/gmic-qt-gimp3-macos-${GMIC_VERSION}-${BUILD_ARCH}.zip"
rm -f "$ZIP_PATH"

ditto -c -k --sequesterRsrc --keepParent "$BUNDLE_DIR" "$ZIP_PATH"

log "Bundle: $BUNDLE_DIR"
log "Zip:    $ZIP_PATH"

# ── Optional install ────────────────────────────────────────────────────
if [[ $INSTALL_PLUGIN -eq 1 ]]; then
  PLUGIN_DIR="$HOME/Library/Application Support/GIMP/${GIMP_API_VERSION}/plug-ins"
  mkdir -p "$PLUGIN_DIR"
  rm -rf "$PLUGIN_DIR/gmic_gimp_qt"
  cp -R "$BUNDLE_DIR" "$PLUGIN_DIR/gmic_gimp_qt"
  chmod +x "$PLUGIN_DIR/gmic_gimp_qt/gmic_gimp_qt"
  xattr -dr com.apple.quarantine "$PLUGIN_DIR/gmic_gimp_qt" || true
  rm -f "$PLUGIN_DIR/../pluginrc" || true
  log "Installed to: $PLUGIN_DIR/gmic_gimp_qt"
fi
