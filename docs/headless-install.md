# Headless install — macOS to Windows over SSH

End-to-end install of RDP Wrapper from a macOS workstation onto a
remote Windows box, no GUI interaction on either side. The procedure
is the one we ran when first auditing this fork; it is intentionally
small and uses only stock tooling.

The companion document `docs/findings.md` explains *why* each step is
necessary. This file is the procedure only.

## Prerequisites

**On the Windows target:**

- Windows 10/11 or Windows Server 2016+.
- OpenSSH Server installed and running:
  ```powershell
  Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
  Start-Service sshd
  Set-Service sshd -StartupType Automatic
  ```
- The SSH user is a member of the local **Administrators** group.
- TCP 22 reachable from your Mac. TCP/UDP 3389 reachable after install
  if you actually want to RDP in.

**On the Mac:**

- Stock `ssh`, `scp`, `curl`. No extra tools required.
- A working SSH config alias for the box (see step 1).

## Step 1 — SSH config alias

Add an alias so we never type or expose the real host. With Home
Manager (newer schema where per-host options live under `data`):

```nix
programs.ssh = {
  enable = true;
  enableDefaultConfig = false;
  matchBlocks = {
    "*" = {
      data = {
        extraOptions = {
          AddKeysToAgent = "yes";
          UseKeychain    = "yes";
          IdentitiesOnly = "yes";
        };
      };
    };
    winbox = {
      data = {
        hostname = "<real-host-or-ip>";
        user     = "<windows-username>";
      };
    };
  };
};
```

Without Home Manager, the equivalent in `~/.ssh/config`:

```
Host winbox
    HostName <real-host-or-ip>
    User     <windows-username>
```

Verify:

```sh
ssh -G winbox | grep -E '^(hostname|user) ' >/dev/null && echo "alias ok"
```

## Step 2 — Stage artifacts on the Mac

We use `stascorp/rdpwrap@v1.6.2` for the binary base (RDPWInst.exe +
embedded rdpwrap.dll) because the fork's own release pipeline doesn't
ship those — see `docs/findings.md` §1. We overlay a fresh INI from
the fork's release, and we ship OffsetFinder + Zydis to handle
termsrv builds newer than the INI covers (always, in practice — §4).

```sh
STAGE=/tmp/rdpwrap-stage
mkdir -p "$STAGE" && cd "$STAGE"

curl -sL -o RDPWrap-v1.6.2.zip \
  https://github.com/stascorp/rdpwrap/releases/download/v1.6.2/RDPWrap-v1.6.2.zip

curl -sL -o rdpwrap.ini \
  https://github.com/sjackson0109/rdpwrap/releases/latest/download/rdpwrap.ini

curl -sL -o RDPWrapOffsetFinder.exe \
  https://github.com/sjackson0109/rdpwrap/releases/latest/download/RDPWrapOffsetFinder_x64.exe

curl -sL -o Zydis.dll \
  https://github.com/sjackson0109/rdpwrap/releases/latest/download/Zydis_x64.dll
```

Copy `scripts/headless-install/install.ps1` and
`scripts/headless-install/update-offsets.ps1` from this repo into the
same directory.

## Step 3 — First connection (password prompt)

```sh
ssh winbox 'powershell -NoProfile -Command "$env:PROCESSOR_ARCHITECTURE; (Get-Service sshd).Status"'
```

Expect `AMD64` (or `ARM64`/`x86`) and `Running`.

## Step 4 — Upload artifacts and run installer (one password each)

```sh
scp /tmp/rdpwrap-stage/RDPWrap-v1.6.2.zip \
    /tmp/rdpwrap-stage/rdpwrap.ini \
    /tmp/rdpwrap-stage/install.ps1 \
    winbox:C:/Windows/Temp/

ssh winbox 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\Windows\Temp\install.ps1'
```

Expected tail of output:

```
ServiceDll: C:\Program Files\RDP Wrapper\rdpwrap.dll
INI: Updated=YYYY-MM-DD
[+] Install complete.
```

## Step 5 — Generate offsets for the running termsrv build

If the INI doesn't cover your `termsrv.dll` build (very likely on a
patched system — see findings §4), upload OffsetFinder and run the
update script.

```sh
scp /tmp/rdpwrap-stage/RDPWrapOffsetFinder.exe \
    /tmp/rdpwrap-stage/Zydis.dll \
    /tmp/rdpwrap-stage/update-offsets.ps1 \
    winbox:C:/Windows/Temp/

ssh winbox 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\Windows\Temp\update-offsets.ps1'
```

The script:

1. Reads the running `termsrv.dll` ProductVersion.
2. Skips with `Nothing to do` if the INI already covers it (idempotent).
3. Otherwise runs OffsetFinder against `C:\Windows\System32\termsrv.dll`.
4. Stops `TermService` (so the INI is no longer locked — see findings §6).
5. Appends the generated section to `rdpwrap.ini`.
6. Restarts `TermService` and any dependents that were running.
7. Verifies the new section is present.

## Step 6 — Verify

```sh
ssh winbox 'powershell -NoProfile -Command "Get-Content C:\rdpwrap.txt -Tail 30 -ErrorAction SilentlyContinue"'
```

Look for `Loaded ini section [10.0.<your-build>]` and no error lines.

A real multi-session test still requires an RDP client — Microsoft
Remote Desktop on the Mac App Store is fine. Connect concurrently
from two sources (or two accounts) and confirm both sessions coexist.

## Troubleshooting

### "Permission denied (publickey,password,...)" after `ssh-copy-id`

Windows OpenSSH ignores `~/.ssh/authorized_keys` for admin users.
Move the key (last password prompt):

```sh
ssh winbox 'powershell -NoProfile -Command "Get-Content $env:USERPROFILE\.ssh\authorized_keys | Add-Content -Path C:\ProgramData\ssh\administrators_authorized_keys; icacls C:\ProgramData\ssh\administrators_authorized_keys /inheritance:r /grant Administrators:F /grant SYSTEM:F; Restart-Service sshd"'
```

### "The process cannot access the file ... rdpwrap.ini"

`TermService` (via `rdpwrap.dll`) has the INI open. The
`update-offsets.ps1` script handles this with `Stop-Service` /
`Start-Service`. If you hit it from a manual edit, do the same.

### Install reports `[-] StartService error (code 1056)`

`ERROR_SERVICE_ALREADY_RUNNING`. Harmless. The service was started
out of order during install and the second start was a no-op.

### Localized strings in output (e.g. "Aceptar" mid-line)

Spanish/other locale leaking through `netsh` output. Cosmetic;
ignore. Do not parse tool output by string match.

### Defender removed `rdpwrap.dll`

Re-run with the exclusion in place (the `install.ps1` script does
this proactively). If Defender is centrally managed, request the
exclusion from your admin.

## What's installed where

| Path | Purpose |
|---|---|
| `C:\Program Files\RDP Wrapper\rdpwrap.dll` | The hook, loaded by TermService. |
| `C:\Program Files\RDP Wrapper\rdpwrap.ini` | Per-build offset database. |
| `HKLM\SYSTEM\CurrentControlSet\Services\TermService\Parameters\ServiceDll` | Repointed at `rdpwrap.dll`. |
| Firewall rule "Remote Desktop" | TCP/UDP 3389 inbound, all profiles. |
| Defender exclusion | `C:\Program Files\RDP Wrapper`. |
| `C:\rdpwrap.txt` | Runtime log (per the INI's `LogFile=` line). |

## Uninstall

```sh
ssh winbox 'powershell -NoProfile -Command "& \"C:\Windows\Temp\rdpwrap\RDPWInst.exe\" -u"'
```

(or run `RDPWInst.exe -u -k` to keep registry/firewall settings.)
