#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

GIMP_APP="${GIMP_APP:-/Applications/GIMP.app}"
GMIC_VERSION="${GMIC_VERSION:-3.7.0}"
WORKDIR="${WORKDIR:-${ROOT_DIR}/work}"
OUTDIR="${OUTDIR:-${ROOT_DIR}/dist}"
MACPORTS_PREFIX="${MACPORTS_PREFIX:-/opt/local}"
QT_PREFIX="${QT_PREFIX:-${MACPORTS_PREFIX}/libexec/qt5}"
GIMP_HEADERS_DIR="${MACPORTS_PREFIX}/include"
SKIP_PORTS=0
SKIP_GIMP3_DEVEL=0
INSTALL_PLUGIN=0

usage() {
  cat <<'USAGE'
Usage: build_gmic_qt_gimp3_macos.sh [options]

Options:
  --gimp-app <path>       Path to GIMP.app (default: /Applications/GIMP.app)
  --gmic-version <ver>    G'MIC version (default: 3.7.0)
  --workdir <path>        Working directory
  --outdir <path>         Output directory for bundle/zip
  --skip-ports            Do not install MacPorts deps
  --skip-gimp3-devel      Do not attempt to install gimp3-devel (use source headers fallback)
  --install               Also copy bundle to user plugin directory
  -h, --help              Show help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --gimp-app) GIMP_APP="$2"; shift 2;;
    --gmic-version) GMIC_VERSION="$2"; shift 2;;
    --workdir) WORKDIR="$2"; shift 2;;
    --outdir) OUTDIR="$2"; shift 2;;
    --skip-ports) SKIP_PORTS=1; shift;;
    --skip-gimp3-devel) SKIP_GIMP3_DEVEL=1; shift;;
    --install) INSTALL_PLUGIN=1; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown option: $1"; usage; exit 1;;
  esac
done

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing command: $1" >&2
    exit 1
  fi
}

# Detect GIMP version from Info.plist (headless-safe) or gimp --version (fallback)
detect_gimp_version() {
  local plist="$GIMP_APP/Contents/Info.plist"
  local ver=""
  # Method 1: PlistBuddy (works headless, no display needed)
  if [[ -f "$plist" ]] && command -v /usr/libexec/PlistBuddy >/dev/null 2>&1; then
    ver="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$plist" 2>/dev/null || true)"
  fi
  # Method 2: gimp --version (may fail in headless CI)
  if [[ -z "$ver" && -x "$GIMP_BIN" ]]; then
    ver="$("$GIMP_BIN" --version 2>/dev/null | awk '/version/ {print $NF; exit}' || true)"
  fi
  # No version detected — cannot continue safely
  if [[ -z "$ver" ]]; then
    echo "Error: Could not detect GIMP version from $GIMP_APP" >&2
    echo "Ensure GIMP.app has a valid Info.plist with CFBundleShortVersionString." >&2
    exit 1
  fi
  echo "$ver"
}

if [[ ! -d "$GIMP_APP" ]]; then
  echo "GIMP.app not found at: $GIMP_APP" >&2
  exit 1
fi

GIMP_BIN="$GIMP_APP/Contents/MacOS/gimp"
if [[ ! -x "$GIMP_BIN" ]]; then
  echo "GIMP binary not found: $GIMP_BIN" >&2
  exit 1
fi

mkdir -p "$WORKDIR" "$OUTDIR"

GIMP_ARCH="$(file "$GIMP_BIN")"
HOST_ARCH="$(uname -m)"
if echo "$GIMP_ARCH" | grep -q "x86_64"; then
  DETECTED_ARCH="x86_64"
elif echo "$GIMP_ARCH" | grep -q "arm64"; then
  DETECTED_ARCH="arm64"
else
  DETECTED_ARCH="$HOST_ARCH"
  echo "Warning: Could not detect GIMP.app architecture from binary:" >&2
  echo "$GIMP_ARCH" >&2
fi
if [[ "$DETECTED_ARCH" != "$HOST_ARCH" ]]; then
  echo "Warning: GIMP.app architecture ($DETECTED_ARCH) differs from host ($HOST_ARCH)." >&2
  echo "Ensure MacPorts and GIMP.app architectures match (or use Rosetta)." >&2
fi

if [[ $SKIP_PORTS -eq 0 ]]; then
  require_cmd port
  sudo port -N install cmake pkgconfig qt5-qtbase qt5-qttools fftw-3 libomp dbus gdk-pixbuf2 cairo gegl glib2
  if [[ $SKIP_GIMP3_DEVEL -eq 0 && ! -f "${GIMP_HEADERS_DIR}/gimp-3.0/libgimp/gimp.h" ]]; then
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

if [[ ! -f "${GIMP_HEADERS_DIR}/gimp-3.0/libgimp/gimp.h" ]]; then
  echo "GIMP headers not found at: ${GIMP_HEADERS_DIR}/gimp-3.0" >&2
  echo "Falling back to GIMP source tarball headers..." >&2

  GIMP_SRC_VERSION="$(detect_gimp_version)"
  GIMP_SRC_URL="https://download.gimp.org/pub/gimp/v3.0/gimp-${GIMP_SRC_VERSION}.tar.xz"

  GMIC_TMP_GIMP_SRC="$WORKDIR/gimp-${GIMP_SRC_VERSION}"
  GMIC_TMP_TAR="$WORKDIR/gimp-${GIMP_SRC_VERSION}.tar.xz"
  if [[ ! -d "$GMIC_TMP_GIMP_SRC" ]]; then
    echo "Downloading GIMP source: $GIMP_SRC_URL" >&2
    curl -L -o "$GMIC_TMP_TAR" "$GIMP_SRC_URL"
    tar -xJf "$GMIC_TMP_TAR" -C "$WORKDIR"
  fi

  HEADER_DST="$WORKDIR/gimp-headers/include/gimp-3.0"
  rm -rf "$WORKDIR/gimp-headers"
  mkdir -p "$HEADER_DST"
  for d in libgimp libgimpbase libgimpcolor libgimpconfig libgimpmath libgimpmodule libgimpthumb libgimpwidgets; do
    if [[ -d "$GMIC_TMP_GIMP_SRC/$d" ]]; then
      cp -R "$GMIC_TMP_GIMP_SRC/$d" "$HEADER_DST/"
    else
      echo "Missing header directory in GIMP source: $d" >&2
    fi
  done

  # Generate gimpversion.h from template
  if [[ -f "$GMIC_TMP_GIMP_SRC/libgimpbase/gimpversion.h.in" ]]; then
    IFS='.' read -r GIMP_VER_MAJOR GIMP_VER_MINOR GIMP_VER_MICRO_REST <<< "$GIMP_SRC_VERSION"
    GIMP_VER_MICRO="$(echo "$GIMP_VER_MICRO_REST" | sed 's/[^0-9].*$//')"
    GIMP_VER_MAJOR="${GIMP_VER_MAJOR:-3}"
    GIMP_VER_MINOR="${GIMP_VER_MINOR:-0}"
    GIMP_VER_MICRO="${GIMP_VER_MICRO:-0}"
    GIMP_API_VERSION="${GIMP_VER_MAJOR}.0"

    cat > "$HEADER_DST/libgimpbase/gimpversion.h" <<EOF_GIMPVERSION
#ifndef __GIMP_VERSION_H__
#define __GIMP_VERSION_H__

/* gimpversion.h.in -> gimpversion.h
 * This file is configured by the build script.
 */
#if !defined (__GIMP_BASE_H_INSIDE__) && !defined (GIMP_BASE_COMPILATION)
#error "Only <libgimpbase/gimpbase.h> can be included directly."
#endif

G_BEGIN_DECLS

#define GIMP_MAJOR_VERSION                              (${GIMP_VER_MAJOR})
#define GIMP_MINOR_VERSION                              (${GIMP_VER_MINOR})
#define GIMP_MICRO_VERSION                              (${GIMP_VER_MICRO})
#define GIMP_VERSION                                    "${GIMP_SRC_VERSION}"
#define GIMP_API_VERSION                                "${GIMP_API_VERSION}"

#define GIMP_CHECK_VERSION(major, minor, micro) \\
    (GIMP_MAJOR_VERSION > (major) || \\
     (GIMP_MAJOR_VERSION == (major) && GIMP_MINOR_VERSION > (minor)) || \\
     (GIMP_MAJOR_VERSION == (major) && GIMP_MINOR_VERSION == (minor) && \\
      GIMP_MICRO_VERSION >= (micro)))

G_END_DECLS

#endif /* __GIMP_VERSION_H__ */
EOF_GIMPVERSION
  fi

  GIMP_HEADERS_DIR="$WORKDIR/gimp-headers/include"
  if [[ ! -f "${GIMP_HEADERS_DIR}/gimp-3.0/libgimp/gimp.h" ]]; then
    echo "GIMP headers still missing after source fallback." >&2
    echo "Please install gimp3-devel via MacPorts." >&2
    exit 1
  fi
fi

# Verify required pkg-config modules (even in --skip-ports mode)
missing_pkgs=()
for pkg in gdk-pixbuf-2.0 cairo gegl-0.4 glib-2.0 gobject-2.0; do
  if ! pkg-config --exists "$pkg" >/dev/null 2>&1; then
    missing_pkgs+=("$pkg")
  fi
done
if [[ ${#missing_pkgs[@]} -gt 0 ]]; then
  echo "Missing pkg-config modules: ${missing_pkgs[*]}" >&2
  echo "Install via MacPorts (suggested): sudo port -N install gdk-pixbuf2 cairo gegl glib2" >&2
  echo "Or re-run without --skip-ports." >&2
  exit 1
fi

GMIC_TARBALL="$WORKDIR/gmic_${GMIC_VERSION}.tar.gz"
GMIC_SRC="$WORKDIR/gmic-${GMIC_VERSION}"

if [[ ! -d "$GMIC_SRC" ]]; then
  echo "Downloading G'MIC ${GMIC_VERSION}..."
  curl -L -o "$GMIC_TARBALL" "https://gmic.eu/files/source/gmic_${GMIC_VERSION}.tar.gz"
  tar -xzf "$GMIC_TARBALL" -C "$WORKDIR"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PKGDIR="$WORKDIR/gimpapp-pkgconfig"
mkdir -p "$PKGDIR"
GIMP_APP_VERSION="$(detect_gimp_version)"

sed -e "s|@GIMP_APP@|${GIMP_APP}|g" \
    -e "s|@GIMP_HEADERS_DIR@|${GIMP_HEADERS_DIR}|g" \
    -e "s|@HOME@|${HOME}|g" \
    -e "s|@GIMP_APP_VERSION@|${GIMP_APP_VERSION}|g" \
    "$SCRIPT_DIR/gimp-3.0.pc.in" > "$PKGDIR/gimp-3.0.pc"

export PKG_CONFIG_PATH="$PKGDIR:${MACPORTS_PREFIX}/lib/pkgconfig"

BUILD_DIR="$WORKDIR/build-gimpapp"
mkdir -p "$BUILD_DIR"

echo "Configuring CMake..."
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
  -DPNG_LIBRARY="${GIMP_APP}/Contents/Resources/lib/libpng16.16.dylib" \
  -DZLIB_LIBRARY="${GIMP_APP}/Contents/Resources/lib/libz.1.dylib" \
  -DCURL_LIBRARY="${GIMP_APP}/Contents/Resources/lib/libcurl.4.dylib" \
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

JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

echo "Building..."
cmake --build "$BUILD_DIR" --parallel "$JOBS"

PLUGIN_BUILD_BIN="$BUILD_DIR/gmic_gimp_qt"
if [[ ! -x "$PLUGIN_BUILD_BIN" ]]; then
  echo "Build output not found: $PLUGIN_BUILD_BIN" >&2
  exit 1
fi

BUNDLE_DIR="$OUTDIR/gmic_gimp_qt"
rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR"

# Copy main plugin binary
cp "$PLUGIN_BUILD_BIN" "$BUNDLE_DIR/gmic_gimp_qt"
PLUGIN_BIN="$BUNDLE_DIR/gmic_gimp_qt"

# Build bundle via Python helper
python3 "$SCRIPT_DIR/bundle_libs.py" \
  --bundle-dir "$BUNDLE_DIR" \
  --plugin-bin "$PLUGIN_BIN" \
  --qt-prefix "$QT_PREFIX" \
  --gimp-app "$GIMP_APP" \
  --macports-prefix "$MACPORTS_PREFIX"

# Clear quarantine
xattr -dr com.apple.quarantine "$BUNDLE_DIR" || true

BUILD_ARCH="${DETECTED_ARCH:-$(uname -m)}"
ZIP_PATH="$OUTDIR/gmic_gimp_qt-gimp3-macos-${GMIC_VERSION}-${BUILD_ARCH}-bundled.zip"
rm -f "$ZIP_PATH"

ditto -c -k --sequesterRsrc --keepParent "$BUNDLE_DIR" "$ZIP_PATH"

echo "Bundle: $BUNDLE_DIR"
echo "Zip:    $ZIP_PATH"

if [[ $INSTALL_PLUGIN -eq 1 ]]; then
  PLUGIN_DIR="$HOME/Library/Application Support/GIMP/3.0/plug-ins"
  rm -rf "$PLUGIN_DIR/gmic_gimp_qt"
  cp -R "$BUNDLE_DIR" "$PLUGIN_DIR/gmic_gimp_qt"
  chmod +x "$PLUGIN_DIR/gmic_gimp_qt/gmic_gimp_qt"
  xattr -dr com.apple.quarantine "$PLUGIN_DIR/gmic_gimp_qt" || true
  rm -f "$PLUGIN_DIR/../pluginrc" || true
  echo "Installed to: $PLUGIN_DIR/gmic_gimp_qt"
fi
