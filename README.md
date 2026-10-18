# PocketRoute

A free, offline network simulator for Android (iOS later). Students drag routers,
switches and PCs onto a canvas, cable them, and configure each device through an
IOS-style command line.

> Working name. PocketRoute is not affiliated with or endorsed by Cisco Systems, Inc.

## Layout

| Path | What it is |
| --- | --- |
| `app/` | Flutter app (canvas, terminal, PC desktop). Depends on `pocketroute_core`. |
| `packages/pocketroute_core/` | Pure-Dart simulation engine and CLI. Never imports Flutter. |
| `SOURCES.md` | Every RFC and public document consulted (clean-room record). |

## Development

```bash
cd packages/pocketroute_core && dart test
cd app && flutter run
```

## Clean-room rules

- No Packet Tracer binaries, assets, or `.pkt/.pka` compatibility. PocketRoute uses its own `.prlab` format.
- No real IOS images or firmware.
- Command syntax and output layout are emulated; all help text and docs are written in our own words.
- No "Cisco", "Packet Tracer", "IOS" or "CCNA" in the app name, icon, package ID or developer name.
- Every RFC and public document consulted is listed in `SOURCES.md`.

## Download

Android APKs are on the [Releases](https://github.com/RaniloJohn/PocketRoute/releases) page. Most phones need `app-arm64-v8a-release.apk`; `app-release.apk` works on all of them.

## License

PocketRoute is free software under the [GNU General Public License v3.0](LICENSE). You may use, study, share and modify it; versions you distribute must also be released under the GPL-3.0 with their source code.

The bundled IBM Plex fonts are under the SIL Open Font License 1.1.
