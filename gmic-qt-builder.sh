#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

GIMP_APP="${GIMP_APP:-/Applications/GIMP.app}"
GMIC_VERSION="${GMIC_VERSION:-3.6.5}"
WORKDIR="${WORKDIR:-${ROOT_DIR}/work}"
OUTDIR="${OUTDIR:-${ROOT_DIR}/dist}"
MACPORTS_PREFIX="${MACPORTS_PREFIX:-/opt/local}"
QT_PREFIX="${QT_PREFIX:-${MACPORTS_PREFIX}/libexec/qt5}"
GIMP_HEADERS_DIR="${GIMP_HEADERS_DIR:-${MACPORTS_PREFIX}/include}"
GIMP_SRC_VERSION=""
GIMP_SRC_URL=""
SKIP_PORTS=0
SKIP_GIMP3_DEVEL=0
INSTALL_PLUGIN=0

usage() {
  cat <<'USAGE'
Usage: build_gmic_qt_gimp3_macos.sh [options]

Options:
  --gimp-app <path>       Path to GIMP.app (default: /Applications/GIMP.app)
  --gmic-version <ver>    G'MIC version (default: 3.6.5)
  --workdir <path>        Working directory
  --outdir <path>         Output directory for bundle/zip
  --gimp-headers <path>   Include dir that contains gimp-3.0 (default: /opt/local/include)
  --gimp-version <ver>    GIMP source version for headers fallback (default: detected from GIMP.app)
  --gimp-src-url <url>    Override GIMP source tarball URL
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
    --gimp-headers) GIMP_HEADERS_DIR="$2"; shift 2;;
    --gimp-version) GIMP_SRC_VERSION="$2"; shift 2;;
    --gimp-src-url) GIMP_SRC_URL="$2"; shift 2;;
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
if ! echo "$GIMP_ARCH" | grep -q "x86_64"; then
  echo "Warning: GIMP.app does not look like x86_64:" >&2
  echo "$GIMP_ARCH" >&2
  echo "If you are on Apple Silicon, ensure MacPorts and GIMP.app architectures match." >&2
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

  if [[ -z "$GIMP_SRC_VERSION" ]]; then
    # Try to parse version from GIMP.app
    GIMP_SRC_VERSION="$("$GIMP_BIN" --version | awk '/version/ {print $NF; exit}')"
  fi
  if [[ -z "$GIMP_SRC_VERSION" ]]; then
    GIMP_SRC_VERSION="3.0.6"
  fi

  if [[ -z "$GIMP_SRC_URL" ]]; then
    GIMP_SRC_URL="https://download.gimp.org/pub/gimp/v3.0/gimp-${GIMP_SRC_VERSION}.tar.xz"
  fi

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
    echo "Please install gimp3-devel or pass --gimp-headers <path>." >&2
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

PKGDIR="$WORKDIR/gimpapp-pkgconfig"
mkdir -p "$PKGDIR"
GIMP_APP_VERSION="$("$GIMP_BIN" --version | awk '/version/ {print $NF; exit}')"
if [[ -z "$GIMP_APP_VERSION" ]]; then
  GIMP_APP_VERSION="3.0.x"
fi

cat > "$PKGDIR/gimp-3.0.pc" <<EOF_PC
prefix=${GIMP_APP}/Contents/Resources
includedir=${GIMP_HEADERS_DIR}
libdir=\${prefix}/lib

datarootdir=\${prefix}/share
gimpdatadir=\${prefix}/share/gimp/3.0
gimplibdir=$HOME/Library/Application Support/GIMP/3.0
gimpsysconfdir=\${prefix}/etc/gimp/3.0
gimplocaledir=\${prefix}/share/locale

Name: GIMP
Description: GIMP Library (GIMP.app)
Version: ${GIMP_APP_VERSION}
Requires: gdk-pixbuf-2.0 >= 2.30.8, cairo >= 1.14.0, gegl-0.4 >= 0.4.50
Requires.private: gexiv2 >= 0.14.0, gio-2.0, lcms2 >= 2.8, glib-2.0 >= 2.70.0, gobject-2.0 >= 2.70.0, gio-unix-2.0, gmodule-no-export-2.0, pango >= 1.50.0, pangoft2 >= 1.50.0
Libs: -L\${libdir} -lgimp-3.0 -lgimpbase-3.0 -lgimpcolor-3.0 -lgimpconfig-3.0 -lgimpmath-3.0
Libs.private: -lm -L\${libdir} -lgimpmodule-3.0
Cflags: -I\${includedir}/gimp-3.0
EOF_PC

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
export BUNDLE_DIR PLUGIN_BIN QT_PREFIX GIMP_APP MACPORTS_PREFIX
python3 - <<'PY'
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

bundle_dir = Path(os.environ.get("BUNDLE_DIR", ""))
plugin_bin = Path(os.environ.get("PLUGIN_BIN", ""))
qt_prefix = Path(os.environ.get("QT_PREFIX", ""))
gimp_app = Path(os.environ.get("GIMP_APP", ""))
macports_prefix = Path(os.environ.get("MACPORTS_PREFIX", "/opt/local"))

if not bundle_dir or not plugin_bin.exists():
    print("Missing bundle_dir or plugin_bin", file=sys.stderr)
    sys.exit(1)

frameworks_dir = bundle_dir / "Frameworks"
plugins_dir = frameworks_dir / "plugins"
lib_dir = frameworks_dir / "lib"
frameworks_dir.mkdir(parents=True, exist_ok=True)
plugins_dir.mkdir(parents=True, exist_ok=True)
lib_dir.mkdir(parents=True, exist_ok=True)

qt_frameworks = ["QtCore", "QtGui", "QtWidgets", "QtNetwork", "QtDBus", "QtPrintSupport"]
qt_lib_dir = qt_prefix / "lib"
qt_plugins_dir = qt_prefix / "plugins"

# Explicit libs to bundle even if current binaries reference them via @rpath
explicit_libs = [
    macports_prefix / "lib/libfftw3.3.dylib",
    macports_prefix / "lib/libfftw3_threads.3.dylib",
    macports_prefix / "lib/libomp/libomp.dylib",
    macports_prefix / "lib/libdbus-1.3.dylib",
    # Fallbacks from GIMP.app (if present)
    gimp_app / "Contents/Resources/lib/libpng16.16.dylib",
    gimp_app / "Contents/Resources/lib/libz.1.dylib",
    gimp_app / "Contents/Resources/lib/libcurl.4.dylib",
]

# Copy Qt frameworks
for name in qt_frameworks:
    src = qt_lib_dir / f"{name}.framework"
    dst = frameworks_dir / f"{name}.framework"
    if not src.exists():
        print(f"Missing Qt framework: {src}", file=sys.stderr)
        sys.exit(1)
    if dst.exists():
        shutil.rmtree(dst)
    shutil.copytree(src, dst, symlinks=True)

# Copy Qt plugins
for sub in ["platforms", "styles", "imageformats", "iconengines"]:
    src = qt_plugins_dir / sub
    dst = plugins_dir / sub
    if src.exists():
        if dst.exists():
            shutil.rmtree(dst)
        shutil.copytree(src, dst, symlinks=True)

# Write qt.conf
qt_conf = bundle_dir / "qt.conf"
qt_conf.write_text("[Paths]\nPlugins = Frameworks/plugins\n", encoding="utf-8")

# Helper functions

def run(cmd):
    subprocess.run(cmd, check=True)


def otool_deps(path):
    out = subprocess.check_output(["otool", "-L", str(path)], text=True)
    deps = []
    for line in out.splitlines()[1:]:
        dep = line.strip().split(" ", 1)[0]
        deps.append(dep)
    return deps


def is_framework(dep):
    return ".framework/" in dep and dep.endswith(tuple(qt_frameworks))


def framework_name(dep):
    # /opt/local/libexec/qt5/lib/QtCore.framework/Versions/5/QtCore
    parts = dep.split("/")
    for part in parts:
        if part.endswith(".framework"):
            return part.replace(".framework", "")
    return None


def add_rpath_if_missing(binpath, rpath):
    out = subprocess.check_output(["otool", "-l", str(binpath)], text=True)
    if f"path {rpath} " in out:
        return
    run(["install_name_tool", "-add_rpath", rpath, str(binpath)])


def set_id(binpath, new_id):
    run(["install_name_tool", "-id", new_id, str(binpath)])


# Collect binaries to scan
binaries = set()
binaries.add(plugin_bin)

# Qt framework binaries
for name in qt_frameworks:
    fw_bin = frameworks_dir / f"{name}.framework/Versions/5/{name}"
    if fw_bin.exists():
        binaries.add(fw_bin)

# Qt plugin dylibs
for dylib in plugins_dir.rglob("*.dylib"):
    binaries.add(dylib)

# Copy explicit libs
for src in explicit_libs:
    if src.exists():
        dst = lib_dir / src.name
        if not dst.exists():
            shutil.copy2(src, dst)

# Recursively gather deps
queue = list(binaries)
seen = set(queue)

opt_local = str(macports_prefix)

while queue:
    item = queue.pop(0)
    for dep in otool_deps(item):
        if dep.startswith("@"):
            continue
        if dep.startswith(str(gimp_app)):
            continue
        if dep.startswith("/System") or dep.startswith("/usr/lib"):
            continue
        if dep.startswith(opt_local):
            # Copy .dylib into Frameworks root
            if dep.endswith(".dylib"):
                src = Path(dep)
                dst = lib_dir / src.name
                if not dst.exists():
                    shutil.copy2(src, dst)
                    seen.add(dst)
                    queue.append(dst)
            # Frameworks already copied
            continue

# Update binaries list with copied dylibs
for dylib in lib_dir.glob("*.dylib"):
    binaries.add(dylib)

# Fix install ids for copied dylibs
for dylib in lib_dir.glob("*.dylib"):
    set_id(dylib, f"@rpath/lib/{dylib.name}")

# Fix install ids for Qt frameworks
for name in qt_frameworks:
    fw_bin = frameworks_dir / f"{name}.framework/Versions/5/{name}"
    if fw_bin.exists():
        set_id(fw_bin, f"@rpath/{name}.framework/Versions/5/{name}")

# Remap deps in all binaries
for binpath in list(binaries):
    deps = otool_deps(binpath)
    for dep in deps:
        if dep.startswith("@"):
            continue
        if dep.startswith(str(gimp_app)) or dep.startswith("/System") or dep.startswith("/usr/lib"):
            continue
        if dep.startswith(opt_local):
            if ".framework/" in dep:
                name = framework_name(dep)
                if name:
                    new = f"@rpath/{name}.framework/Versions/5/{name}"
                    run(["install_name_tool", "-change", dep, new, str(binpath)])
            elif dep.endswith(".dylib"):
                new = f"@rpath/lib/{Path(dep).name}"
                run(["install_name_tool", "-change", dep, new, str(binpath)])

# Add rpaths
add_rpath_if_missing(plugin_bin, "@loader_path/Frameworks")
add_rpath_if_missing(plugin_bin, f"{gimp_app}/Contents/Resources")

for dylib in plugins_dir.rglob("*.dylib"):
    add_rpath_if_missing(dylib, "@loader_path/../..")
    add_rpath_if_missing(dylib, "@executable_path/../Frameworks")

for name in qt_frameworks:
    fw_bin = frameworks_dir / f"{name}.framework/Versions/5/{name}"
    if fw_bin.exists():
        add_rpath_if_missing(fw_bin, "@loader_path/../../..")

PY

# Clear quarantine
xattr -dr com.apple.quarantine "$BUNDLE_DIR" || true

ZIP_PATH="$OUTDIR/gmic_gimp_qt-gimp3-macos-${GMIC_VERSION}-bundled.zip"
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
