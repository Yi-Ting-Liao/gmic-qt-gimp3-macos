#!/usr/bin/env python3
"""
Bundle dylibs and Qt frameworks into the gmic_gimp_qt plugin directory.

This script copies Qt frameworks, Qt plugins, explicit dylibs, and recursively
gathered transitive dependencies into Frameworks/ beside the plugin binary,
then rewrites all install names and rpaths so the bundle is self-contained.

Required environment variables (or CLI arguments):
    BUNDLE_DIR       - destination plugin directory (contains gmic_gimp_qt)
    PLUGIN_BIN       - path to the gmic_gimp_qt binary inside BUNDLE_DIR
    QT_PREFIX        - Qt5 prefix (e.g. /opt/local/libexec/qt5)
    GIMP_APP         - path to GIMP.app
    MACPORTS_PREFIX  - MacPorts prefix (default: /opt/local)
"""

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path


# ── Qt frameworks to bundle ───────────────────────────────────────────────

QT_FRAMEWORKS = [
    "QtCore",
    "QtGui",
    "QtWidgets",
    "QtNetwork",
    "QtDBus",
    "QtPrintSupport",
]

QT_PLUGIN_SUBDIRS = ["platforms", "styles", "imageformats", "iconengines"]


# ── Helper functions ──────────────────────────────────────────────────────

def run(cmd: list[str]) -> None:
    subprocess.run(cmd, check=True)


def otool_deps(path: Path) -> list[str]:
    """Return the list of linked library paths reported by otool -L."""
    out = subprocess.check_output(["otool", "-L", str(path)], text=True)
    deps: list[str] = []
    for line in out.splitlines()[1:]:
        dep = line.strip().split(" ", 1)[0]
        deps.append(dep)
    return deps


def framework_name(dep: str) -> str | None:
    """Extract the framework name from an absolute path like
    /opt/local/libexec/qt5/lib/QtCore.framework/Versions/5/QtCore."""
    for part in dep.split("/"):
        if part.endswith(".framework"):
            return part.removesuffix(".framework")
    return None


def add_rpath_if_missing(binpath: Path, rpath: str) -> None:
    out = subprocess.check_output(["otool", "-l", str(binpath)], text=True)
    if f"path {rpath} " in out:
        return
    run(["install_name_tool", "-add_rpath", rpath, str(binpath)])


def set_id(binpath: Path, new_id: str) -> None:
    run(["install_name_tool", "-id", new_id, str(binpath)])


# ── Main bundling logic ──────────────────────────────────────────────────

def bundle(
    bundle_dir: Path,
    plugin_bin: Path,
    qt_prefix: Path,
    gimp_app: Path,
    macports_prefix: Path,
) -> None:
    if not bundle_dir.is_dir() or not plugin_bin.exists():
        print("Missing bundle_dir or plugin_bin", file=sys.stderr)
        sys.exit(1)

    frameworks_dir = bundle_dir / "Frameworks"
    plugins_dir = frameworks_dir / "plugins"
    lib_dir = frameworks_dir / "lib"
    for d in (frameworks_dir, plugins_dir, lib_dir):
        d.mkdir(parents=True, exist_ok=True)

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

    # ── Copy Qt frameworks ────────────────────────────────────────────
    for name in QT_FRAMEWORKS:
        src = qt_lib_dir / f"{name}.framework"
        dst = frameworks_dir / f"{name}.framework"
        if not src.exists():
            print(f"Missing Qt framework: {src}", file=sys.stderr)
            sys.exit(1)
        if dst.exists():
            shutil.rmtree(dst)
        shutil.copytree(src, dst, symlinks=True)

    # ── Copy Qt plugins ───────────────────────────────────────────────
    for sub in QT_PLUGIN_SUBDIRS:
        src = qt_plugins_dir / sub
        dst = plugins_dir / sub
        if src.exists():
            if dst.exists():
                shutil.rmtree(dst)
            shutil.copytree(src, dst, symlinks=True)

    # ── Write qt.conf ─────────────────────────────────────────────────
    qt_conf = bundle_dir / "qt.conf"
    qt_conf.write_text("[Paths]\nPlugins = Frameworks/plugins\n", encoding="utf-8")

    # ── Collect initial set of binaries to process ────────────────────
    binaries: set[Path] = {plugin_bin}

    for name in QT_FRAMEWORKS:
        fw_bin = frameworks_dir / f"{name}.framework/Versions/5/{name}"
        if fw_bin.exists():
            binaries.add(fw_bin)

    for dylib in plugins_dir.rglob("*.dylib"):
        binaries.add(dylib)

    # ── Copy explicit libs ────────────────────────────────────────────
    for src in explicit_libs:
        if src.exists():
            dst = lib_dir / src.name
            if not dst.exists():
                shutil.copy2(src, dst)

    # ── Recursively gather transitive deps from /opt/local ────────────
    queue = list(binaries)
    seen: set[Path] = set(queue)
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
            if dep.startswith(opt_local) and dep.endswith(".dylib"):
                src = Path(dep)
                dst = lib_dir / src.name
                if not dst.exists():
                    shutil.copy2(src, dst)
                    seen.add(dst)
                    queue.append(dst)

    # ── Update binaries set with all copied dylibs ────────────────────
    for dylib in lib_dir.glob("*.dylib"):
        binaries.add(dylib)

    # ── Fix install IDs ───────────────────────────────────────────────
    for dylib in lib_dir.glob("*.dylib"):
        set_id(dylib, f"@rpath/lib/{dylib.name}")

    for name in QT_FRAMEWORKS:
        fw_bin = frameworks_dir / f"{name}.framework/Versions/5/{name}"
        if fw_bin.exists():
            set_id(fw_bin, f"@rpath/{name}.framework/Versions/5/{name}")

    # ── Remap deps in all binaries ────────────────────────────────────
    for binpath in list(binaries):
        for dep in otool_deps(binpath):
            if dep.startswith("@"):
                continue
            if (
                dep.startswith(str(gimp_app))
                or dep.startswith("/System")
                or dep.startswith("/usr/lib")
            ):
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

    # ── Add rpaths ────────────────────────────────────────────────────
    add_rpath_if_missing(plugin_bin, "@loader_path/Frameworks")
    add_rpath_if_missing(plugin_bin, f"{gimp_app}/Contents/Resources")

    for dylib in plugins_dir.rglob("*.dylib"):
        add_rpath_if_missing(dylib, "@loader_path/../..")
        add_rpath_if_missing(dylib, "@executable_path/../Frameworks")

    for name in QT_FRAMEWORKS:
        fw_bin = frameworks_dir / f"{name}.framework/Versions/5/{name}"
        if fw_bin.exists():
            add_rpath_if_missing(fw_bin, "@loader_path/../../..")


# ── CLI entry point ──────────────────────────────────────────────────────

def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--bundle-dir", default=os.environ.get("BUNDLE_DIR", ""),
                    help="Plugin bundle directory")
    p.add_argument("--plugin-bin", default=os.environ.get("PLUGIN_BIN", ""),
                    help="Path to gmic_gimp_qt binary")
    p.add_argument("--qt-prefix", default=os.environ.get("QT_PREFIX", ""),
                    help="Qt5 prefix path")
    p.add_argument("--gimp-app", default=os.environ.get("GIMP_APP", ""),
                    help="Path to GIMP.app")
    p.add_argument("--macports-prefix",
                    default=os.environ.get("MACPORTS_PREFIX", "/opt/local"),
                    help="MacPorts prefix (default: /opt/local)")
    return p.parse_args()


def main() -> None:
    args = parse_args()

    bundle_dir = Path(args.bundle_dir)
    plugin_bin = Path(args.plugin_bin)
    qt_prefix = Path(args.qt_prefix)
    gimp_app = Path(args.gimp_app)
    macports_prefix = Path(args.macports_prefix)

    for name, val in [
        ("bundle-dir", bundle_dir),
        ("plugin-bin", plugin_bin),
        ("qt-prefix", qt_prefix),
        ("gimp-app", gimp_app),
    ]:
        if not str(val):
            print(f"Error: --{name} (or env var) is required", file=sys.stderr)
            sys.exit(1)

    bundle(bundle_dir, plugin_bin, qt_prefix, gimp_app, macports_prefix)
    print(f"Bundle complete: {bundle_dir}")


if __name__ == "__main__":
    main()
