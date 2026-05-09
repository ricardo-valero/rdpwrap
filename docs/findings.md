# Findings — RDP Wrapper fork audit and headless install

This document records what we learned auditing this fork (originally
`stascorp/rdpwrap` → `sjackson0109/rdpwrap` → here) and walking it
end-to-end onto a clean Windows 11 24H2 box from a macOS workstation
over SSH. It exists to (a) justify the rewrite in `docs/architecture.md`
and (b) save anyone repeating this work the same hours.

## Audit conclusion

No malicious code was introduced by either upstream fork. The C# port
in `src-csharp/` is a faithful translation of the original Delphi
`RDPWInst.dpr`. The native DLL source in `src-x86-x64-Fusix/` is
unchanged from the Fusix variant — only the `.vcxproj` was extended
with an ARM64 configuration. The HTTP helper has no telemetry; the
only outbound calls are to GitHub Releases for `rdpwrap.ini`,
`RDPWrapOffsetFinder*.exe`, and `Zydis*.dll`.

The CI hash-pins `sergiye/rdpWrapper` release assets in
`tools/sergiye-hashes.json`, which is a positive supply-chain signal.

Caveats worth knowing:

- `rdpwrap.dll` patches Windows Terminal Services in memory. AV/EDR
  *should* flag it; that is RDP Wrapper's whole purpose, not malice.
- Online install (`-i -o`) and update (`-w`) fetch resources from the
  fork's own release URL with no runtime hash verification. Fine if you
  trust the fork's signing/release process; otherwise prefer the
  embedded INI.
- MSIs are unsigned unless the repo variable `USE_CERT_SIGNING=true`
  is set. SmartScreen will warn on first run.

## Gap analysis — current state of the art

These are the broken or incomplete things we hit. They motivate a
clean-room rewrite rather than further patching.

### 1. The fork's release pipeline is incomplete

`build-and-release.yml` is comprehensive on paper, but at the time of
writing the fork's published "latest" release contains only:

- `rdpwrap.ini`
- `RDPWrapOffsetFinder_x64.{exe,zip}`, `RDPWrapOffsetFinder_x86.{exe,zip}`
- `Zydis_x64.dll`, `Zydis_x86.dll`

There is no `rdpwrap.dll`, no `RDPWInst.exe`, no MSI. The C# build job
runs but its outputs never make it onto the release. Anyone trying to
install from "your fork's latest release" cannot, and falls back to
older stascorp binaries.

### 2. The "x64" and "x86" OffsetFinder binaries are bit-identical 32-bit PEs

```
RDPWrapOffsetFinder_x64.exe  25088 bytes  PE32 (Intel 80386)
RDPWrapOffsetFinder_x86.exe  25088 bytes  PE32 (Intel 80386)
Zydis_x64.dll               545280 bytes  PE32 (DLL, Intel 80386)
Zydis_x86.dll               545280 bytes  PE32 (DLL, Intel 80386)
```

Identical sizes, identical architecture. The git log shows multiple
"fix: use correct 64-bit RDPWrapOffsetFinder binaries" commits that
never resolved this. In practice it doesn't *break* anything — the
finder is a disassembler that reads `termsrv.dll` as data, so its
own arch is irrelevant — but the labelling is wrong and a downstream
consumer that selects by arch suffix loses determinism.

### 3. `RDPWInst v1.6.2`'s embedded INI is from 2017

The stascorp v1.6.2 ZIP is the practical binary base most people end
up using (because the fork doesn't ship binaries — see #1). Its
embedded `rdpwrap.ini` predates Windows 10 build 14393. On any
modern Windows it prints `not supported` and the install proceeds
in a degraded state until the INI is overlaid manually.

### 4. Even fresh INIs lag Windows updates by weeks

The fork's most recent INI release covers `[10.0.26100.*]` builds up
to **7623**. The Windows 11 24H2 box we tested was on **8115**. Every
LCU pushes builds forward; the offset database always trails. This
means OffsetFinder is not optional — it has to be part of the
install path, not a manual escape hatch.

### 5. Windows OpenSSH ignores `~/.ssh/authorized_keys` for admins

This bit us. `ssh-copy-id` reports success and copies the key to
`C:\Users\<user>\.ssh\authorized_keys`, but `sshd` on Windows has a
`Match Group administrators` block in `C:\ProgramData\ssh\sshd_config`
that overrides `AuthorizedKeysFile` to
`__PROGRAMDATA__/ssh/administrators_authorized_keys` for any user in
the local Administrators group. Until the key is appended *there*
with locked-down ACLs, key auth keeps prompting for a password.

### 6. `rdpwrap.dll` keeps `rdpwrap.ini` open while TermService runs

Updating the INI in place fails with
`The process cannot access the file because it is being used by another
process`. You must `Stop-Service TermService -Force` (which also stops
dependents — track them and restart afterwards), then write, then
`Start-Service TermService`. The original `update.bat` ignores this
and works only because RDPWInst happens to restart the service at the
right point.

### 7. Defender flags `rdpwrap.dll`

Predictable but worth scripting: `Add-MpPreference -ExclusionPath
'C:\Program Files\RDP Wrapper'` *before* extracting files, otherwise
the DLL can be quarantined mid-install with no error surfaced.

### 8. Headless install works, despite the install.bat heritage

`RDPWInst.exe`'s `Pause()` is gated on `Console.IsOutputRedirected`,
so over SSH it exits cleanly. The original `install.bat` calling it
interactively is a UX choice, not a constraint. Everything we did
ran through `ssh ... 'powershell -NoProfile -ExecutionPolicy Bypass
-File ...'` with no manual intervention on the Windows side.

### 9. Localized Windows leaks into stdout

On Spanish-locale Windows, `netsh advfirewall firewall add rule` emits
"Aceptar" mid-output and `whoami /groups | findstr administrators`
needs to be `findstr Administradores` instead. Any installer that
parses tool output by string is fragile across locales — prefer
PowerShell cmdlets and SIDs (`S-1-5-32-544`) over text matching.

## Implications for a minimal rewrite

A clean-room CLI tool — no GUI binaries, no MSI, no .NET runtime —
should:

1. **Ship a single static native binary.** Cross-compilable from
   macOS via `zig cc` (the existing dev shell already includes Zig
   0.16). One toolchain for both the installer and the hook DLL.
2. **Treat OffsetFinder as a first-class dependency, not a fallback.**
   On every `install` and `update`, check if the running termsrv
   version is in the INI; if not, generate offsets locally and append.
   No silent "not supported" state.
3. **Manage TermService lifecycle explicitly.** Stop dependents,
   modify the INI, start dependents. Don't rely on accidental restarts.
4. **Verify file integrity.** Hash-pin downloaded INIs and the
   OffsetFinder binary. The CI's `sergiye-hashes.json` pattern is the
   right idea; extend it to runtime, not just build time.
5. **Apply Defender exclusion before drop.** Idempotent and silent.
6. **Use SIDs, not localized strings.** No `findstr administrators`.
7. **Prefer the Windows admin auth-keys path** in any docs/scripts:
   `C:\ProgramData\ssh\administrators_authorized_keys` with
   `icacls /inheritance:r /grant Administrators:F /grant SYSTEM:F`.

The CLI surface should collapse RDPWInst's `-i -o -s -f -u -k -w -r`
to four verbs: `install`, `uninstall`, `update`, `status`. No flag
soup; sensible defaults.

The matching headless install procedure we used end-to-end is
captured in `docs/headless-install.md`, with the working scripts
under `scripts/headless-install/`.
