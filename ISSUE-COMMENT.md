### Windows AppX workaround: bundled plugin copy failure and missing native host registrations

On one Windows installation (Codex AppX `26.924.6891.0`, bundled Chrome plugin `26.924.51851`), the Edge ChatGPT extension reported `Native transport disconnected`. The AppX package included the Chrome plugin, but its per-user cache and native host registrations were absent. Direct `Copy-Item` of a bundled file failed with `The specified file could not be encrypted`; reading its bytes and writing them to a normal user directory worked.

The recovery sequence was: materialize the current bundled plugin into the user's versioned cache; create the `latest` junction; run the plugin's own `installManifest.mjs` with the Desktop-staged runtime paths; add the Edge HKCU native messaging registration; create both `chrome-native-hosts-v2.json` manifests for the observed 26.924 schema. The Edge panel then connected successfully.

I've packaged a diagnosis script, a guarded repair script, and the validation steps here: https://github.com/surqing/codex-windows-browser-repair . The repair defaults to the one confirmed plugin version and does not alter the protected WindowsApps package. This is an unofficial workaround and has not been validated on another affected Windows machine. A first-party fix for the failing provisioning step would be preferable.
