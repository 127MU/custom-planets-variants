<p align="center"><img src="assets/cpv.png" width="112" alt="CPV"></p>
<h1 align="center">Custom Planets & Variants</h1>
<p align="center">自定义星球和变种 · Rust / Flutter / Morrow</p>
<p align="center"><a href="README.md">简体中文</a> · <b>English</b></p>

A standalone planet and variant configuration tool for Helldivers 2. Search planets, combine effects, configure operations and regions, and keep reusable plans in one place.

## Features

- **Planet plans:** search names or IDs, add, edit, enable, import and export plans.
- **Effect library:** bilingual search, categories, multi-selection and selected-only filtering. Drag the category strip with a mouse, use the wheel or drag its horizontal scrollbar.
- **Operations:** campaign type, operation count, enemy faction, missing-region initialization and defense settings. City and special-planet campaigns need enough operation slots (default 20).
- **Temporary stratagems:** select multiple temporary stratagems per planet. The game has its own limit, and extra selections may not work in-game.
- **Weather presets:** documented Exostorm effects; experimental candidates are labeled in the interface.
- **Appearance:** custom background images, Chinese / English, light / dark / system mode, accent colors and frosted, liquid-glass or solid materials.
- **Armory:** search and select primary weapons, secondary weapons and throwables, or preview them in bulk. Saved plans apply when the game logs in again and fetches the item catalog and inventory. Missing catalog entries use a template from the same equipment category. Unnamed entries are experimental. Attachment replacements match the original attachment in existing presets. [Catalog data](https://github.com/deepseekv41flash/hd2-datamined/blob/master/docs/tables/WEAPON-CUSTOMIZATION-26251122.md) · [Unlock map](https://github.com/deepseekv41flash/hd2-network-proxy/blob/master/docs/UNLOCK-MAP-2026-11-06.md)
- **Connection management:** local certificate generation, explicitly confirmed current-user trust, Steam launch bridge and an optional upstream HTTP proxy.
- **Diagnostics:** check profile access, application integrity, certificate and proxy state, then export a local JSON report.

## Installation and use

Windows 10 / 11, 64-bit, is required.

1. Run the single-file **自定义星球和变种.exe**. It verifies and extracts its runtime on first launch; Qt, Flutter and Python do not need to be installed separately. For the portable ZIP, extract the entire archive first.
2. Add a planet, choose effects and operation / region settings, then save the plan.
3. Generate a local certificate on the Connection page. After reviewing its purpose, select Trust certificate. Authorize the Windows UAC prompt to install automatically. Only the **current-user** trust store is used; the main application does not remain elevated.
4. Copy the generated Steam launch options into the game's Properties → General → Launch Options.
5. Fully exit the game, enable the proxy, and launch the game from Steam.

Fully restart the game after stopping the proxy. Without a valid session the bridge launches the game normally. The application does not enable the proxy or install trust by default, change system proxy settings or hosts, or install a traffic-capture driver.

### Accelerators and upstream proxies

Only required game APIs on `api.live.prod.thehelldiversgame.com` are intercepted. Login and anti-cheat connections are excluded from HTTPS decryption. Enable the upstream HTTP proxy option while the proxy is stopped if your route requires an existing proxy. This affects application processes, not Windows global proxy settings.

### Diagnostics

Open Settings → Diagnostics & logs. Enable diagnostic mode, run the checks, and export a JSON log. Reports are never uploaded automatically and exclude accounts, authentication headers, request bodies, CA private keys and screenshots.

If the window cannot open, start it from PowerShell:

```powershell
& '.\自定义星球和变种.exe' --diagnostic
```

The default profile is `%LOCALAPPDATA%/CPV/RustProfile`; logs are under `diagnostics`. If that location is not writable, the launcher tries `.CPV/Profile` next to the executable. Set `CPV_PROFILE` to choose another profile directory.

If Windows policy rejects certificate installation, the application reports the system error. Do not change global trust policy to work around it. Removing trust only targets the certificate recorded by this application.


### Updates

Every launch checks stable releases in the background. A newer release opens a dialog with release notes. If GitHub is unreachable, the app tries GH-Proxy and GHFast mirrors. Original and mirror download buttons open the default browser; installers are never executed automatically. Settings → About also offers a manual check and displays author 127MU and the repository address.

When publishing, generate `latest.json` with `tools/release-manifest.py` and upload it alongside the EXE in the same stable release. Mirror-based update detection relies on this file.

## Build from source

Install Rust stable with edition 2024 support, Flutter stable, Python 3, Visual Studio 2022 Desktop development with C++, and a Windows SDK. Development validation used Flutter 3.47.9 / Dart 3.13.7.

```powershell
.\tools\build-rust.ps1 -Test
.\tools\build-rust.ps1
cd ui
flutter pub get
flutter analyze
flutter test
flutter build windows --release
cd ..
```

Prepare an official-mitmproxy-based Windows Python runtime containing `python.exe`, `proxy_main.py`, dependencies and a `runtime.json` hash manifest, then package:

```powershell
python tools/package-rust.py --output dist/release --proxy-runtime C:/path/to/mitmproxy-runtime --solid-payload build/cpv-payload.xz
.\tools\build-rust.ps1 -Payload build/cpv-payload.xz -PayloadManifest dist/release/CPV_2.0.3/manifest.json
```

The launcher is written to `backend/target/release/cpv-launcher.exe`; copy and rename it to `自定义星球和变种.exe`. Python runtimes and generated binaries are not committed. Packaging verifies runtime hashes and required icon glyphs. If it detects missing glyphs, run `flutter clean` and rebuild.

## Layout

| Directory | Purpose |
| --- | --- |
| `backend/` | Rust host, Steam bridge and single-file launcher |
| `ui/` | Flutter interface and Morrow glass materials |
| `proxy/` | Required game API proxy addon |
| `assets/` | Icons and effect catalog |
| `tools/` | Build, packaging and validation scripts |
| `tests/` | Proxy, catalog and package regressions |

## Special thanks

- [hd2-network-proxy](https://github.com/deepseekv41flash/hd2-network-proxy) — network API and variant research.
- [hd2-datamined](https://github.com/deepseekv41flash/hd2-datamined) — game data structures and resource research.
- [hd2-srkit](https://github.com/deepseekv41flash/hd2-srkit) — related tools and technical references.
- [Morrow](https://github.com/StarrySky7D4/morrow) — design reference, glass components and shaders.
- [SHODAN Stat Editor](https://github.com/127MU/SHODAN-Stat-Editor) — origin of the standalone tool.
- [mitmproxy](https://github.com/mitmproxy/mitmproxy), Flutter, Rust and the other open-source dependencies.

## License

**AGPL-3.0-only**. Third-party sources, revisions and licenses are documented in [`licenses/`](licenses/). This project is not affiliated with the game publisher. Catalog candidates and experimental options are not guarantees of compatibility across every game version or combination.
