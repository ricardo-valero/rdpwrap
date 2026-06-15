# rdpwrap-cli

Pure-Zig reimplementation of [RDP Wrapper](https://github.com/stascorp/rdpwrap) —
enables concurrent RDP sessions on Windows SKUs that normally allow only
one, by wrapping `termsrv.dll` instead of patching it on disk.

This repository started as a fork of an upstream C# / C++ project and has
been rewritten end-to-end in Zig. No .NET runtime, no MSI installer, no
shell scripts at install time — a single ~900 KB CLI plus a ~70 KB wrapper
DLL, both cross-compiled from any Zig host to Windows x64.

## Repository layout

- **`rdpwrap-cli/`** — the project. Builds `rdpwrap-cli.exe` (installer +
  status + INI updater + PDB fetcher) and `rdpwrap.dll` (the wrapper
  svchost loads). See [`rdpwrap-cli/README.md`](rdpwrap-cli/README.md) for
  build instructions, CLI surface, phase status, and per-module layout.
- **`docs/`** — design notes (`findings.md`), the manual procedure this
  replaces (`headless-install.md`), and a reference doc on adding support
  for new Windows builds (`HOW-TO-ADD-NEW-WINDOWS-BUILDS.md`).
- **`scripts/`** — PowerShell helpers for remote deploy, probing, and
  diagnostics. Used during development; not part of the shipped product.
- **`flake.nix`** — provides Zig 0.16 via Nix (`nix develop`).

## License

See [`LICENSE`](LICENSE). Attribution to the upstream RDP Wrapper authors
is preserved; the wrapper *technique* (load-into-svchost in place of
`termsrv.dll`, byte-patch the loaded image, install JMP trampoline for the
SL policy hook) is theirs. The Zig codebase here is an independent
implementation.
