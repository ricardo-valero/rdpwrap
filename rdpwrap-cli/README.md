# rdpwrap-cli

Minimal RDP Wrapper installer in Zig. Cross-compiles from macOS (or any
Zig host) to Windows x64. Single static binary, no .NET runtime, no
PowerShell scripts at install time.

This is the Phase 1 deliverable — see `docs/findings.md` and
`docs/headless-install.md` at the repo root for the rationale and the
manual procedure this replaces.

## Status

**Scaffold only.** The CLI builds and dispatches verbs but no verb is
implemented. Phase 1 will incrementally fill in `install`,
`uninstall`, `update`, `status` against a known-good DLL/INI base.

## Build

The repo's nix flake provides Zig 0.16 (`nix develop` or direnv).
From this directory:

```sh
zig build                                   # debug, default target = x86_64-windows-gnu
zig build -Doptimize=ReleaseSmall           # ~430 KB exe
zig build -Dtarget=x86_64-windows-gnu       # explicit target
zig build -Dtarget=aarch64-windows-gnu      # ARM64 (untested)
```

Output: `zig-out/bin/rdpwrap-cli.exe`.

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

- **Phase 1** (now): scaffold + cross-compile verified. **Done.**
- **Phase 1.1**: implement `install` against a user-supplied DLL+INI on disk.
- **Phase 1.2**: implement `uninstall`, `status`.
- **Phase 2**: build the existing Fusix C++ DLL with `zig c++` so we ship our own `rdpwrap.dll`.
- **Phase 3**: replace OffsetFinder with PDB-based offset resolution
  via Microsoft's public symbol server. Implement `update`.
- **Phase 4**: ARM64, signing, INI source decision (hosted vs proxied).
