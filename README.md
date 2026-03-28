# Blocks

A PowerShell command-line tool for downloading, compiling, and installing Delphi packages from GitHub into the IDE.

## Requirements

- PowerShell 5.1 or later
- Delphi / RAD Studio (any version from XE6 onwards)
- .NET Framework 4.x (for MSBuild)
- Internet access (for downloading packages from GitHub)

## Installation

Copy `blocks.ps1` to any folder in your `PATH`, or run it directly from its location.

## Usage

```powershell
.\blocks.ps1 -Install <id|path|url> [options]
```

If invoked with no arguments, the help message is displayed.

## Options

| Option | Description |
|---|---|
| `-Install <id\|path\|url>` | Package to install. See [Specifying a package](#specifying-a-package). |
| `-Uninstall` | Remove the project directory and its database entry. |
| `-Product <version>` | Delphi version to target, by internal name (e.g. `delphi13`). Use `-ListProducts` to see available values. |
| `-Commit <sha>` | Download a specific commit SHA instead of the latest. Can also be embedded in the ID with `@` (see below). |
| `-Silent` | Skip all interactive prompts. On commit mismatch in dependencies, keeps the installed version. |
| `-Overwrite` | Automatically overwrite an existing project directory without asking. |
| `-WorkspacePath <dir>` | Working directory where packages are installed (default: current directory). Created if it does not exist. |
| `-ProjectFolder <dir>` | Override the project directory name (default: `application.name` from the config). |
| `-BuildOnly` | Skip the download step. Assumes the project is already on disk and runs the build only. Falls back to `application.name` if `-ProjectFolder` is not specified. |
| `-ListProducts` | List installed Delphi versions and exit. |
| `-Help` | Show the help message and exit. |

## Specifying a package

`-Install` accepts three formats:

**Package ID** — looks up the configuration in `.blocks\repository\`:

```powershell
.\blocks.ps1 -Install delphi-blocks.wirl
# resolves to .blocks\repository\delphi-blocks\wirl.json
```

Dots (or slashes) in the ID act as directory separators. The last segment becomes the filename.

A specific commit can be pinned directly in the ID using `@`:

```powershell
.\blocks.ps1 -Install delphi-blocks.wirl@a3f1c9b
```

**Local file path:**

```powershell
.\blocks.ps1 -Install C:\myconfigs\mylib.json
.\blocks.ps1 -Install .\mylib.json
```

**Remote URL:**

```powershell
.\blocks.ps1 -Install https://example.com/configs/mylib.json
```

## Package configuration

Each package is described by a JSON file:

```json
{
  "application": {
    "id": "delphi-blocks.wirl",
    "name": "WiRL",
    "description": "RESTful Library for Delphi",
    "url": "https://github.com/delphi-blocks/WiRL"
  },
  "supportedPlatforms": {
    "Win32": {
      "sourcePath": ["Source\\Core", "Source\\Data", "Source\\Extensions", "Source\\Client"]
    }
  },
  "packages": [
    { "name": "WiRL",       "type": ["runtime"] },
    { "name": "WiRLDesign", "type": ["designtime"] }
  ],
  "package options": {
    "package folders": {
      "delphiberlin": "10.1Berlin",
      "delphitokyo":  "10.2Tokyo",
      "delphirio":    "10.3Rio",
      "delphisydney": "10.4Sydney",
      "delphi11+":    "11AndLater"
    }
  },
  "dependencies": [
    "paolo-rossi.delphi-neon@a576d50073ef4c1036eef1d2e07d014e4d60483b"
  ]
}
```

### Fields

- **`application.id`** — unique identifier in `owner.package` format.
- **`application.name`** — human-readable name, used as the default project directory name.
- **`application.url`** — GitHub repository URL.
- **`supportedPlatforms`** — object whose keys are platform names (e.g. `Win32`). Each platform can declare `sourcePath`, `browsingPath`, and `debugDCUPath` arrays, which are added to the corresponding Delphi library registry paths after compilation. Omitted arrays are ignored.
- **`packages`** — list of `.dproj` files to compile. Each entry has a `name` and a `type` (`runtime` or `designtime`). Files are expected at `packages\<folder>\<name>.dproj`.
- **`package options.package folders`** — maps a Delphi version key to the subfolder name inside `packages\`. Keys ending in `+` match that version and all later ones (e.g. `delphi11+` matches Delphi 11, 12, 13, ...).
- **`dependencies`** — list of package IDs (optionally with a pinned commit via `@`) that must be installed before this package.

## Dependencies

When a package declares dependencies, Blocks resolves them recursively before installing the main package. For each dependency:

- **Already installed, correct commit** — skipped.
- **Already installed, different commit** — the user is prompted to stop, keep the installed version, or install the required version. In `-Silent` mode, the installed version is kept automatically.
- **Not installed** — downloaded, compiled, and registered in the database automatically.

Sub-dependencies are always processed before their parent.

## Database

After each successful installation, Blocks records the installed library and commit in a per-Delphi-version database file:

```
.blocks\delphi13-database.json
```

The file contains a `blocks` array of entries in `owner.package@commitsha` format:

```json
{
  "blocks": [
    "paolo-rossi.delphi-neon@a576d50073ef4c1036eef1d2e07d014e4d60483b",
    "delphi-blocks.wirl@52f67656b1ad09e13c9b3ea61093bdb7d84ce4c3"
  ]
}
```

This database is used to check whether a dependency is already present before attempting to download it.

## Repository folder

The built-in package registry lives at `.blocks\repository\` relative to the working directory, organised by vendor:

```
.blocks\
  repository\
    delphi-blocks\
      wirl.json
    paolo-rossi\
      delphi-jose-jwt.json
      delphi-neon.json
      openapi-delphi.json
```

## Examples

```powershell
# Install WiRL (and its dependencies) targeting the current Delphi version
.\blocks.ps1 -Install delphi-blocks.wirl

# Fully automated install, targeting Delphi 13, overwriting any existing files
.\blocks.ps1 -Install delphi-blocks.wirl -Product delphi13 -Silent -Overwrite

# Install a specific commit
.\blocks.ps1 -Install delphi-blocks.wirl@a3f1c9b

# Recompile without re-downloading
.\blocks.ps1 -Install delphi-blocks.wirl -Product delphi13 -BuildOnly

# Uninstall
.\blocks.ps1 -Install delphi-blocks.wirl -Uninstall

# List installed Delphi versions
.\blocks.ps1 -ListProducts
```

## How it works

1. **Load configuration** — from the repository, a local file, or a remote URL.
2. **Detect Delphi versions** — reads installed versions from the Windows registry (`HKLM` and `HKCU` under `Embarcadero\BDS`).
3. **Select target version** — most recent by default, or specified via `-Product`.
4. **Resolve dependencies** — installs any missing dependencies recursively before proceeding.
5. **Select commit** — latest by default, or specified via `-Commit` or the `@` suffix in the ID.
6. **Download** — fetches the repository as a zip from GitHub and extracts it to `<workspace>\<name>`.
7. **Compile** — runs MSBuild on each `.dproj` for every supported platform. Stops immediately on the first failure.
8. **Update library paths** — adds `sourcePath`, `browsingPath`, and `debugDCUPath` entries to the Delphi registry for each platform.
9. **Register** — records the installed library and commit in the version database.
