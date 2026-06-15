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
| 3.1   | `rdpwrap-cli update` — fetch fresh INI from community sources over HTTPS | done |
| 3.2.0 | Extract CodeView PDB info from termsrv, emit Microsoft symbol-server URL | done |
| 3.2.1 | `rdpwrap-cli pdb-fetch` — download the matching termsrv.pdb | done |
| 3.2.2 | Pure-Zig PDB parser (MSF container + DBI / symbol streams) | future |
| 3.2.3 | `rdpwrap-cli offset-find` — emit a complete INI section from a PDB | future |
| 4     | ARM64, signing, native firewall/Defender APIs | future |

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
rdpwrap-cli install --dll <path> --ini <path> [--no-firewall]
                        Copy DLL+INI to %ProgramFiles%\RDP Wrapper, point
                        TermService's ServiceDll at it, open firewall 3389.
rdpwrap-cli uninstall [--keep-firewall]
                        Restore stock termsrv.dll, close firewall.
rdpwrap-cli update [--url <url>] [--from <source>] [--no-restart]
                        Fetch a fresh rdpwrap.ini from a community source
                        (sebaxakerhtc by default, asmtron as fallback) and
                        atomically replace the installed one.
rdpwrap-cli status      Print termsrv version, TermService state, ServiceDll
                        path, INI date, INI coverage for the running build,
                        and the Microsoft symbol-server URL for the
                        matching termsrv.pdb.
rdpwrap-cli pdb-fetch [--out <path>]
                        Download the matching termsrv.pdb from Microsoft's
                        public symbol server. Useful as a manual escape
                        hatch when a community INI hasn't caught up to a
                        Microsoft update — pair with cvdump.exe to extract
                        offsets by hand until Phase 3.2.2 lands.
rdpwrap-cli help        Show help.
```

Defaults:
- Install dir: `%ProgramFiles%\RDP Wrapper\`
- INI source: `sebaxakerhtc/rdpwrap.ini` (master branch)
- Log file written by the DLL: `C:\Windows\Temp\rdpwrap.txt`

## Layout

```
src/
  main.zig            arg parsing + verb dispatch + Context
  log.zig             [*] / [+] / [-] / [!] prefixed output
  http.zig            shared HTTPS-fetch wrapper around std.http.Client
  ini.zig             rdpwrap.ini parser (host-testable)
  pe.zig              PE header reader + CodeView debug-info extractor
  patcher.zig         byte writes + JMP trampoline encoding (host-testable)

  install.zig         install verb
  uninstall.zig       uninstall verb
  update.zig          update verb
  status.zig          status verb
  pdb_fetch.zig       pdb-fetch verb

  dll_main.zig        rdpwrap.dll entry + svchost-facing exports
  dll_runtime.zig     first-call orchestration (load termsrv, apply patches)
  dll_patch.zig       walk INI section, apply byte + hook patches
  dll_hooks.zig       exported New_CSLQuery_Initialize + SLInit override table
  dll_version.zig     read termsrv VS_FIXEDFILEINFO ProductVersion
  dll_log.zig         best-effort append-only log file

  win/                registry / service / path / process / Win32 bindings
build.zig             cross-compile target = x86_64-windows-gnu by default
```
