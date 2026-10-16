# RouteLab

A free, offline network simulator for Android (iOS later). Students drag routers,
switches and PCs onto a canvas, cable them, and configure each device through an
IOS-style command line.

> Working name. RouteLab is not affiliated with or endorsed by Cisco Systems, Inc.

## Layout

| Path | What it is |
| --- | --- |
| `app/` | Flutter app (canvas, terminal, PC desktop). Depends on `routelab_core`. |
| `packages/routelab_core/` | Pure-Dart simulation engine and CLI. Never imports Flutter. |
| `SOURCES.md` | Every RFC and public document consulted (clean-room record). |

## Development

```bash
cd packages/routelab_core && dart test
cd app && flutter run
```

## Clean-room rules

- No Packet Tracer binaries, assets, or `.pkt/.pka` compatibility. RouteLab uses its own `.rlab` format.
- No real IOS images or firmware.
- Command syntax and output layout are emulated; all help text and docs are written in our own words.
- No "Cisco", "Packet Tracer", "IOS" or "CCNA" in the app name, icon, package ID or developer name.
- Every RFC and public document consulted is listed in `SOURCES.md`.
