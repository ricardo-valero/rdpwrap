# rdpwrap-cli + rdpwrap.dll

Pure-Zig RDP Wrapper. Cross-compiles from macOS (or any Zig host) to
Windows x64 in a single workspace. No .NET runtime, no PowerShell
scripts at install time, no C/C++ in the hook DLL.

Two artifacts produced by `zig build`:

- **`rdpwrap-cli.exe`** — installer (`install` / `uninstall` / `update` / `status`).
- **`rdpwrap.dll`** — the wrapper svchost loads in place of `termsrv.dll`.

See `docs/findings.md` and `docs/headless-install.md` for the
rationale and the manual procedure this replaces.

## Status

| Phase | Module | State |
|---|---|---|
| 1.1 | `rdpwrap-cli install` / `uninstall` | done |
| 1.2 | `rdpwrap-cli status` — termsrv version, ServiceDll, INI coverage | done |
| 2a  | INI parser (`src/ini.zig`)            | done |
| 2b  | PE reader + patcher (`src/{pe,patcher}.zig`) | done |
| 2c  | DLL skeleton (`src/dll_*.zig`) — DllMain + exports + forwarding | done |
| 2d  | DLL patching pipeline (read INI, detect version, apply byte patches) | done |
| 2e  | Hook trampoline pipeline + exported `New_CSLQuery_Initialize` | done |
| 3.1 | `rdpwrap-cli update` — fetch fresh INI from community sources over HTTPS | done |
| 3.2 | PDB-based offset finder (when community INIs lag a Microsoft update) | next |
| 4   | ARM64, signing, native firewall/Defender APIs | future |

## Build

The repo's nix flake provides Zig 0.16 (`nix develop` or direnv).
From this directory:

```sh
zig build                                   # debug, default target = x86_64-windows-gnu
zig build -Doptimize=ReleaseSmall           # ~458 KB exe + ~52 KB dll
zig build -Dtarget=x86_64-windows-gnu       # explicit target
zig build -Dtarget=aarch64-windows-gnu      # ARM64 (untested)
zig build test                              # host-side unit tests
```

Outputs:
- `zig-out/bin/rdpwrap-cli.exe`
- `zig-out/bin/rdpwrap.dll`

## Run on macOS host (sanity check)

The arg parser and `help` verb don't touch Windows APIs:

```sh
zig build -Dtarget=x86_64-macos -Doptimize=Debug run -- help
```

## CLI surface

```
rdpwrap-cli install     Drop rdpwrap.dll, point TermService at it, open firewall
rdpwrap-cli uninstall   Restore termsrv.dll, close firewall
rdpwrap-cli update      Refresh INI; regenerate offsets if termsrv build is newer
rdpwrap-cli status      Print termsrv version, ServiceDll path, INI date
rdpwrap-cli help        Show help
```

No flag soup. Defaults:
- Install dir: `%ProgramFiles%\RDP Wrapper\`
- INI source (Phase 3): hash-pinned snapshot of `asmtron/rdpwrap-keepalive`.
- Offset generation (Phase 3): local PDB-based, falls back to bundled OffsetFinder.

## Layout

```
src/
  main.zig         arg parsing + verb dispatch + Context
  log.zig          [*] / [+] / [-] / [!] prefixed output
  install.zig      verb skeleton
  uninstall.zig    verb skeleton
  update.zig       verb skeleton
  status.zig       verb skeleton
  win/             (planned) registry / service / firewall / defender wrappers
build.zig          cross-compile target = x86_64-windows-gnu by default
build.zig.zon      package metadata
```

## Roadmap

- **Phase 1**: scaffold + cross-compile verified. **Done.**
- **Phase 1.1**: implement `install` and `uninstall` against a user-supplied DLL+INI on disk. **Done.**
- **Phase 1.2**: implement `status` (termsrv version, ServiceDll, INI date, INI coverage).
- **Phase 2**: build the existing Fusix C++ DLL with `zig c++` so we ship our own `rdpwrap.dll`.
- **Phase 3**: replace OffsetFinder with PDB-based offset resolution
  via Microsoft's public symbol server. Implement `update`.
- **Phase 4**: ARM64, signing, INI source decision (hosted vs proxied).
