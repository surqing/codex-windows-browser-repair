[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [switch]$AllowUntestedVersion
)

$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Windows only.' }
$homeDir = [Environment]::GetFolderPath('UserProfile')
$codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $homeDir '.codex' }
$appLocal = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex'
$nativeHostName = 'com.openai.codexextension'
$extensionIds = @('hehggadaopoacecdllhhajmbjkdcmajg', 'odlomjlbamekndcpllcnffbgeohgkmjh')
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'

function Require-File($Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Required file is missing: $Path" }
}
function Backup-File($Path) {
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $backup = "$Path.bak-$stamp"
        [IO.File]::WriteAllBytes($backup, [IO.File]::ReadAllBytes($Path))
        Write-Host "Backup: $backup"
    }
}
function Find-NewestFile($Root, $Name) {
    $matches = @(Get-ChildItem -LiteralPath $Root -Filter $Name -Recurse -File -ErrorAction Stop |
        Sort-Object LastWriteTimeUtc -Descending)
    if ($matches.Count -eq 0) { throw "Could not find $Name under $Root" }
    return $matches[0].FullName
}
function Copy-TreeByBytes($Source, $Destination) {
    [IO.Directory]::CreateDirectory($Destination) | Out-Null
    foreach ($file in Get-ChildItem -LiteralPath $Source -Recurse -File -Force) {
        $relative = $file.FullName.Substring($Source.TrimEnd('\').Length).TrimStart('\')
        $target = Join-Path $Destination $relative
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target)) | Out-Null
        [IO.File]::WriteAllBytes($target, [IO.File]::ReadAllBytes($file.FullName))
    }
}

$pkg = Get-AppxPackage -Name OpenAI.Codex | Sort-Object Version -Descending | Select-Object -First 1
if (-not $pkg) { throw 'OpenAI.Codex AppX package not found for this user.' }
$resources = Join-Path $pkg.InstallLocation 'app\resources'
$source = Join-Path $resources 'plugins\openai-bundled\plugins\chrome'
$pluginFile = Join-Path $source '.codex-plugin\plugin.json'
Require-File $pluginFile
$version = (Get-Content -LiteralPath $pluginFile -Raw | ConvertFrom-Json).version
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw "Unexpected plugin version: $version" }
if (-not $AllowUntestedVersion -and $version -ne '26.924.51851') {
    throw "v2 schema was verified only with plugin 26.924.51851; found $version. Review the current app schema, then pass -AllowUntestedVersion if compatible."
}
$base = Join-Path $codexHome 'plugins\cache\openai-bundled\chrome'
$versioned = Join-Path $base $version
$latest = Join-Path $base 'latest'
$installer = Join-Path $versioned 'scripts\installManifest.mjs'
$host = Join-Path $versioned 'extension-host\windows\x64\extension-host.exe'
$hostConfig = Join-Path $versioned 'extension-host\windows\x64\extension-host-config.json'
$v1 = Join-Path $env:LOCALAPPDATA "OpenAI\extension\$nativeHostName.json"
$localV2 = Join-Path $appLocal 'chrome-native-hosts-v2.json'
$homeV2 = Join-Path $codexHome 'chrome-native-hosts-v2.json'
$codex = Find-NewestFile (Join-Path $appLocal 'bin') 'codex.exe'
$node = Find-NewestFile (Join-Path $appLocal 'runtimes\cua_node') 'node.exe'
$nodeRepl = Join-Path (Split-Path -Parent $node) 'node_repl.exe'
foreach ($p in @($installer.Replace($versioned, $source), $host.Replace($versioned, $source), $codex, $node, $nodeRepl)) { Require-File $p }
Write-Host "AppX: $($pkg.Version); plugin: $version"
Write-Host "CLI: $codex; Node: $node"

if (-not $PSCmdlet.ShouldProcess("$base; $v1; Edge HKCU; $localV2; $homeV2", 'Materialize plugin and register native host')) { return }

# Never modify the protected package. Stage in the user directory before replacing a partial cache.
[IO.Directory]::CreateDirectory($base) | Out-Null
$staging = Join-Path $base "$version.stage-$stamp"
try {
    Copy-TreeByBytes $source $staging
    Require-File (Join-Path $staging 'scripts\installManifest.mjs')
    Require-File (Join-Path $staging 'extension-host\windows\x64\extension-host.exe')
    if (Test-Path -LiteralPath $versioned) {
        $old = "$versioned.bak-$stamp"
        Move-Item -LiteralPath $versioned -Destination $old
        Write-Host "Previous plugin cache: $old"
    }
    Move-Item -LiteralPath $staging -Destination $versioned
} finally {
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
}

if (Test-Path -LiteralPath $latest) {
    $item = Get-Item -LiteralPath $latest -Force
    if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "latest exists but is not a junction/link: $latest; inspect it manually."
    }
    [IO.Directory]::Delete($latest, $false)
}
New-Item -ItemType Junction -Path $latest -Target $versioned | Out-Null

Backup-File $v1
Backup-File $hostConfig
$wrapper = Join-Path $env:TEMP "codex-native-install-$stamp.mjs"
@'
import { pathToFileURL } from 'node:url';
const [installerPath, codexCliPath, nodeReplPath] = process.argv.slice(2);
const installer = await import(pathToFileURL(installerPath).href);
await installer.install({ appServerRuntimePaths: { codexCliPath, nodePath: process.execPath, nodeReplPath } });
'@ | Set-Content -LiteralPath $wrapper -Encoding UTF8
try {
    & $node $wrapper $installer $codex $nodeRepl
    if ($LASTEXITCODE -ne 0) { throw "Official installManifest.mjs failed with exit code $LASTEXITCODE" }
} finally { Remove-Item -LiteralPath $wrapper -Force -ErrorAction SilentlyContinue }
Require-File $v1
Require-File $hostConfig

$edgeKey = "HKCU:\Software\Microsoft\Edge\NativeMessagingHosts\$nativeHostName"
$previousEdge = if (Test-Path $edgeKey) { (Get-Item $edgeKey).GetValue('') } else { $null }
Write-Host "Previous Edge registration: $previousEdge"
New-Item -Path $edgeKey -Force | Out-Null
(Get-Item $edgeKey).SetValue('', $v1, [Microsoft.Win32.RegistryValueKind]::String)

# The v2 document is built from current paths. Keep existing unrelated entries.
# This format was reverse checked against the 26.924 package and should be reviewed after updates.
$generator = Join-Path $env:TEMP "codex-native-v2-$stamp.mjs"
@'
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
const [resourcesPath, codexCliPath, nodePath, nodeReplPath, pluginRoot, codexHome, outputLocal, outputHome, hostName, version, extensionIdsJson] = process.argv.slice(2);
const extensionIds = JSON.parse(extensionIdsJson);
const channel = 'prod';
function shortHash(values) {
  const hash = crypto.createHash('sha256');
  for (const value of values) { hash.update(String(value), 'utf8'); hash.update(Buffer.from([0])); }
  return hash.digest('hex').slice(0, 32);
}
const paths = {
  browserClientPath: path.join(pluginRoot, 'scripts', 'browser-client.mjs'),
  browserServicePath: path.join(pluginRoot, 'scripts', 'browser-service.mjs'),
  codexCliPath, codexHome,
  extensionHostPath: path.join(pluginRoot, 'extension-host', 'windows', 'x64', 'extension-host.exe'),
  nodePath, nodeReplPath, resourcesPath
};
for (const [key, value] of Object.entries(paths)) {
  if (key !== 'codexHome' && !fs.existsSync(value)) throw new Error(`Missing ${key}: ${value}`);
}
const entry = {
  schemaVersion: 2, appServerProtocolVersion: 2, appVersion: version,
  channel, cliVersion: version,
  entryId: 'codex-runtime-' + shortHash([hostName, ...extensionIds, channel, version, paths.extensionHostPath, codexCliPath, codexHome, resourcesPath]),
  extensionBuildChannels: ['prod'], extensionIds,
  installId: 'codex-install-' + shortHash([hostName, resourcesPath, codexHome]),
  nativeHostNames: [hostName], nativeHostProtocolVersion: 2,
  nativeHostVersion: version, paths, proxyHost: '127.0.0.1', proxyPort: 0,
  updatedAt: new Date().toISOString()
};
function write(destination) {
  let entries = [];
  if (fs.existsSync(destination)) {
    const old = JSON.parse(fs.readFileSync(destination, 'utf8'));
    if (old.schemaVersion !== 2 || !Array.isArray(old.entries)) throw new Error(`Unexpected existing v2 format: ${destination}`);
    entries = old.entries.filter(item => !(item.nativeHostNames?.includes(hostName) && item.channel === channel));
    fs.copyFileSync(destination, destination + '.bak-' + process.env.CODEX_REPAIR_STAMP);
  }
  entries.push(entry);
  const document = { schemaVersion: 2, entries };
  fs.mkdirSync(path.dirname(destination), { recursive: true });
  const temp = destination + '.tmp-' + process.pid;
  fs.writeFileSync(temp, JSON.stringify(document, null, 2) + '\n', { encoding: 'utf8', flag: 'wx' });
  fs.renameSync(temp, destination);
  console.log(`WROTE: ${destination}`);
}
write(outputLocal);
write(outputHome);
console.log(`entryId: ${entry.entryId}`);
'@ | Set-Content -LiteralPath $generator -Encoding UTF8
try {
    $env:CODEX_REPAIR_STAMP = $stamp
    $idsJson = ConvertTo-Json -InputObject $extensionIds -Compress
    & $node $generator $resources $codex $node $nodeRepl $latest $codexHome $localV2 $homeV2 $nativeHostName $version $idsJson
    if ($LASTEXITCODE -ne 0) { throw "v2 generation failed with exit code $LASTEXITCODE" }
} finally {
    Remove-Item -LiteralPath $generator -Force -ErrorAction SilentlyContinue
    Remove-Item Env:CODEX_REPAIR_STAMP -ErrorAction SilentlyContinue
}
Write-Host 'Repair complete. Restart Codex Desktop and Edge, then run Diagnose-CodexBrowserBridge.ps1.'
