# G'MIC-Qt Builder for GIMP 3 on macOS

Build and package the [G'MIC](https://gmic.eu/) image-processing plugin as a
**self-contained, relocatable bundle** for
[GIMP 3](https://www.gimp.org/) on macOS.

Supports both **x86_64 (Intel)** and **arm64 (Apple Silicon)** architectures.

---

## Pre-built Binaries

If you just want to **use G'MIC in GIMP** without compiling anything, grab the
latest release from the
[**Releases page**](../../releases/latest).

Download the zip that matches your Mac's architecture:

| Architecture | Mac type                                 |
| ------------ | ---------------------------------------- |
| **arm64**    | Apple Silicon (M1 / M2 / M3 / M4)        |
| **x86_64**   | Intel, or GIMP.app running under Rosetta |

### Installation

1. Unzip the downloaded file
2. Copy the `gmic_gimp_qt` folder to:
    ```
    ~/Library/Application Support/GIMP/3.0/plug-ins/
    ```
    (In Finder: **Go → Go to Folder…** then paste the path above)
3. Open Terminal and run:
    ```bash
    xattr -dr com.apple.quarantine "$HOME/Library/Application Support/GIMP/3.0/plug-ins/gmic_gimp_qt"
    ```
4. Restart GIMP

G'MIC will appear under **Filters → G'MIC-Qt…** in GIMP.

---

## Building from Source

The rest of this document explains how to compile G'MIC-Qt yourself on a clean
macOS system.

### Prerequisites

| Requirement                                       | Notes                                                               |
| ------------------------------------------------- | ------------------------------------------------------------------- |
| macOS (10.15 Catalina or later recommended)       | Older versions may work but are untested                            |
| Xcode Command Line Tools                          | `xcode-select --install`                                            |
| [MacPorts](https://www.macports.org/install.php)  | Provides Qt 5, FFTW, libomp, and other build-time dependencies      |
| [GIMP.app](https://www.gimp.org/downloads/) 3.x.x | Must be the native `.app` bundle — **not** the X11 / MacPorts build |

> **Tip:** The script auto-detects GIMP.app's architecture from its binary and
> embeds it in the output filename. Make sure your MacPorts installation targets
> the same architecture as your GIMP.app.

### Install MacPorts dependencies

```bash
sudo port -N install \
  cmake pkgconfig \
  qt5-qtbase qt5-qttools \
  fftw-3 libomp dbus \
  gdk-pixbuf2 cairo gegl glib2
```

GIMP headers are also needed at compile time. The script automatically
**downloads the GIMP source tarball** (version matched from your GIMP.app) and
extracts the required headers. No manual intervention is needed.

### Build

```bash
./gmic-qt-builder.sh
```

That single command will:

1. Download the G'MIC source code
2. Generate a `gimp-3.0.pc` file pointing at your GIMP.app
3. Configure and compile `gmic-qt` via CMake
4. Bundle all runtime dependencies (Qt frameworks, FFTW, libomp, …) into a
   relocatable directory
5. Package everything into a zip under `../dist/`

### CLI Reference

```
Usage: gmic-qt-builder.sh [options]
```

| Flag                       | Description                                               | Default                  |
| -------------------------- | --------------------------------------------------------- | ------------------------ |
| `--gimp-app <path>`        | Path to GIMP.app                                          | `/Applications/GIMP.app` |
| `--gmic-version <ver>`     | G'MIC version to build                                    | `3.7.0`                  |
| `--workdir <path>`         | Working directory (sources, build artifacts)              | `../work`                |
| `--outdir <path>`          | Output directory (bundle, zip)                            | `../dist`                |
| `--macports-prefix <path>` | MacPorts prefix                                           | `/opt/local`             |
| `--skip-ports`             | Skip MacPorts dependency installation                     | off                      |
| `--skip-gimp3-devel`       | Skip `gimp3-devel` port; use source headers directly      | on                       |
| `--install`                | Copy the bundle to the user plug-in directory after build | off                      |
| `--clean`                  | Remove workdir and build artifacts before building        | off                      |

Environment variables `MACPORTS_PREFIX` and `QT_PREFIX` can override the
MacPorts and Qt 5 paths if your installation is non-standard:

```bash
MACPORTS_PREFIX=/custom/prefix \
QT_PREFIX=/custom/prefix/libexec/qt5 \
./gmic-qt-builder.sh
```

### Examples

```bash
# Simplest invocation — uses all defaults
./gmic-qt-builder.sh

# Specify a different G'MIC version
./gmic-qt-builder.sh --gmic-version 3.5.2

# Skip dependency installation (already done) and use source headers
./gmic-qt-builder.sh --skip-ports --skip-gimp3-devel

# Build and install directly into the GIMP plug-in directory
./gmic-qt-builder.sh --install

# Clean build
./gmic-qt-builder.sh --clean
```

---

## Output

The build produces a zip archive in the output directory:

```
gmic-qt-gimp3-macos-<version>-<arch>.zip
```

Where `<arch>` is `x86_64` or `arm64`, detected automatically from GIMP.app.

Inside the zip:

```
gmic_gimp_qt/
├── gmic_gimp_qt          # Plugin binary
├── qt.conf               # Qt plugin search path configuration
└── Frameworks/
    ├── Qt*.framework/     # Qt 5 frameworks (Core, Gui, Widgets, Network, DBus, PrintSupport)
    ├── plugins/           # Qt platform plugins (cocoa), styles, image formats, icon engines
    └── lib/               # Bundled dylibs (fftw3, libomp, libpng, libz, libcurl, …)
```

All library paths are rewritten to `@rpath`-relative references via
`install_name_tool`, so the bundle is fully self-contained. No MacPorts or
Homebrew installation is required on the target machine — only GIMP.app.

---

## How It Works

1. **Source download** — Fetches the G'MIC release tarball from
   [gmic.eu](https://gmic.eu).
2. **Header resolution** — Uses GIMP headers from the `gimp3-devel` MacPorts
   port. If unavailable, downloads the matching GIMP source tarball (version
   detected from GIMP.app's `Info.plist`) and extracts `libgimp*` headers,
   including generating `gimpversion.h`.
3. **pkg-config generation** — Fills in
   [gimp-3.0.pc.in](gimp-3.0.pc.in) with paths to GIMP.app's
   libraries and the resolved headers directory.
4. **CMake build** — Compiles `gmic-qt` with `GMIC_QT_HOST=gimp3`, linking
   against Qt 5 and FFTW from MacPorts, and libpng / zlib / libcurl from
   GIMP.app.
5. **Bundling** —
   [bundle_libs.py](bundle_libs.py) performs a BFS walk over
   `otool -L` output to discover all transitive dependencies, copies them into
   the bundle, and rewrites load paths to `@rpath`-relative references.
6. **Packaging** — Creates the final zip via `ditto`.

---

## CI / Automation

This repository includes two GitHub Actions workflows that fully automate the
release process.

### Build workflow ([build.yml](.github/workflows/build.yml))

Compiles the plugin on both Intel (`macos-15-intel`) and Apple Silicon
(`macos-15`) runners, then publishes a GitHub Release with architecture-specific
zip files.

-   **Triggers:** manual `workflow_dispatch` (with version inputs) or
    `repository_dispatch` (fired by the version-check workflow).
-   **MacPorts:** Built from source on the runner (the `.pkg` installer does not
    work on GitHub Actions).
-   **GIMP.app:** Downloaded as an official DMG from `download.gimp.org`, mounted,
    and copied to `/Applications`.

### Version check workflow ([check-version.yml](.github/workflows/check-version.yml))

Runs daily (UTC 08:00) to poll for new upstream releases.

1. Fetches the latest tag from
   [GreycLab/gmic-qt](https://github.com/GreycLab/gmic-qt).
2. Fetches the latest GIMP macOS DMG version from `download.gimp.org`.
3. Checks whether a matching release already exists in this repository.
4. If not, fires a `repository_dispatch` event to trigger the build workflow.

This means new G'MIC-Qt versions are **built and released automatically** with
no manual intervention.

---

## Troubleshooting

**G'MIC does not appear in GIMP at all**

1. Confirm the plugin is in the correct directory:
   `~/Library/Application Support/GIMP/3.0/plug-ins/gmic_gimp_qt/`
2. Make sure the binary is executable: `chmod +x .../gmic_gimp_qt/gmic_gimp_qt`
3. Remove the quarantine attribute:
   `xattr -dr com.apple.quarantine .../gmic_gimp_qt`
4. Delete the stale plug-in cache:
   `rm -f "$HOME/Library/Application Support/GIMP/3.0/pluginrc"`
5. Restart GIMP.

---

## Project Structure

```
gmic-qt-builder/
├── gmic-qt-builder.sh          # Main build script
├── bundle_libs.py              # Bundles dylibs/frameworks and rewrites load paths
├── gimp-3.0.pc.in              # pkg-config template (filled in at build time)
└── .github/workflows/
    ├── build.yml               # CI: compile + release (x86_64 + arm64)
    └── check-version.yml       # CI: daily upstream version check
```

---

## License

This repository contains **build tooling only**. G'MIC is developed by the
[G'MIC team](https://gmic.eu/) and distributed under the
[CeCILL](https://cecill.info/licences/Licence_CeCILL_V2.1-en.html) license.
G'MIC-Qt is distributed under the
[GPL-3.0](https://www.gnu.org/licenses/gpl-3.0.html) license.
See the [upstream repository](https://github.com/GreycLab/gmic-qt) for details.
