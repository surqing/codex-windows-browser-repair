# Codex Windows browser bridge repair

An **unofficial, version guarded workaround** for `Native transport disconnected` in the ChatGPT Edge extension when the Microsoft Store / AppX Codex Desktop installation has failed to materialize its bundled Chrome plugin and native host registration.

The procedure was confirmed on one Windows installation with AppX `26.924.6891.0` and bundled plugin `26.924.51851`. It is not a general cure for every browser connection failure. Read the diagnosis before running the repair. The schema of `chrome-native-hosts-v2.json` is private and can change after an app update.

## Symptoms and diagnosis

Run in **Windows PowerShell**, as the affected user (no administrator elevation required):

```powershell
.\Diagnose-CodexBrowserBridge.ps1
```

PowerShell may block downloaded scripts. Inspect the files first; if you trust this copy, use a one process policy rather than changing the machine policy:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Diagnose-CodexBrowserBridge.ps1
```

This workaround is relevant when the official AppX package contains `plugins\openai-bundled\plugins\chrome`, but the user's `.codex\plugins\cache\openai-bundled\chrome` cache, v1 native messaging manifest, or v2 manifests are missing. On the reported machine, a direct `Copy-Item` from WindowsApps failed with `The specified file could not be encrypted`, while reading source bytes and writing a new user file succeeded. This is **evidence from that machine**, not a proven cause on every Windows installation.

The diagnostic reports the bundled host, current versioned cache, `latest` host, v1 and v2 manifests, Chrome/Edge HKCU registry pointers, and a running extension host. A missing running process alone is not conclusive until the browser extension attempts a connection.

## Repair

Close Codex Desktop and Edge. Run a dry run, then repair in the same Windows user account:

```powershell
.\Repair-CodexBrowserBridge.ps1 -WhatIf
.\Repair-CodexBrowserBridge.ps1
```

Or, after reviewing the scripts, invoke each with `powershell.exe -NoProfile -ExecutionPolicy Bypass -File` as above. Restart Codex Desktop and Edge, open the extension, and rerun the diagnostic. Confirm the browser panel actually connects.

The script:

1. Finds the current AppX package, bundled plugin version, Desktop's staged `codex.exe`, and matching `node.exe` / `node_repl.exe` pair.
2. Copies the bundled plugin through byte reads/writes into a staged user directory, then moves it into the versioned cache. It leaves a timestamped copy of a previous versioned cache.
3. Repoints the `latest` junction. It stops if `latest` is a normal directory instead of deleting it.
4. Runs the **bundled** `installManifest.mjs` for the v1 native host. It saves existing v1 and host config files first.
5. Registers Edge's native messaging host under the current user's registry hive.
6. Generates both v2 manifests from discovered paths and the schema confirmed for plugin `26.924.51851`. Existing manifests are backed up and entries for unrelated native hosts/channels are retained.

The script writes only under the current user's profile, `%LOCALAPPDATA%`, and HKCU. It does not change WindowsApps permissions, decrypt the package, disable protection, or download executables. It does not send credentials anywhere.

### Other plugin versions

The script intentionally stops before changing anything when the bundled plugin is not `26.924.51851`. After reviewing the current app's private schema and installer, an experienced user can override this guard with `-AllowUntestedVersion`. That switch is **not a compatibility guarantee**. Extension IDs and the v2 field layout may change. Please open an issue with redacted diagnostic output rather than assuming that the old schema still applies.

### Recovery and limitations

Backups are named `.bak-YYYYMMDD-HHMMSS-mmm` next to overwritten files. An existing versioned plugin cache is renamed to a matching `.bak-...` directory. The repair does not provide an automatic rollback: if it fails halfway, inspect the error and backups before rerunning it. Existing `latest` is replaced only when it is a link. A Microsoft Store update can change paths and invalidate this repair; rerun diagnosis after updates.

Do not post `auth.json`, tokens, private logs, or unredacted paths containing your username in public issues. This project is independent of OpenAI and is not an official installer. Prefer an official fix when one becomes available.

## Manual verification

```powershell
Test-Path "$env:LOCALAPPDATA\OpenAI\extension\com.openai.codexextension.json"
Test-Path "$env:LOCALAPPDATA\OpenAI\Codex\chrome-native-hosts-v2.json"
Test-Path "$env:USERPROFILE\.codex\chrome-native-hosts-v2.json"
reg.exe query "HKCU\Software\Microsoft\Edge\NativeMessagingHosts\com.openai.codexextension" /ve
Get-CimInstance Win32_Process -Filter "Name = 'extension-host.exe'" |
    Select-Object ProcessId, ExecutablePath
```

If `CODEX_HOME` is set, use that directory instead of `%USERPROFILE%\.codex` in the third check. The browser connection itself is the final verification.

## Scope of testing

This repository packages a manually successful recovery sequence. The generalized scripts have been reviewed statically but have **not yet been executed on another affected Windows machine**. Please report results with the AppX and plugin versions, the exact failing step, and redacted diagnostics.

## License

MIT; see [LICENSE](LICENSE).
