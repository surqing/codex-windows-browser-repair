param()

$ErrorActionPreference = 'Stop'
$homeDir = [Environment]::GetFolderPath('UserProfile')
$codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $homeDir '.codex' }
$appLocal = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex'
$hostName = 'com.openai.codexextension'

function Report($Name, $Value, $Status) {
    [pscustomobject]@{ Check = $Name; Status = $Status; Detail = [string]$Value }
}
function PathReport($Name, $Path) {
    Report $Name $Path $(if (Test-Path -LiteralPath $Path) { 'OK' } else { 'MISSING' })
}
function RegistryReport($Browser, $Key) {
    $item = Get-Item -LiteralPath $Key -ErrorAction SilentlyContinue
    $value = if ($item) { $item.GetValue('') } else { $null }
    Report "$Browser registration" $value $(if ($value -and (Test-Path -LiteralPath $value)) { 'OK' } else { 'MISSING' })
}

$pkg = Get-AppxPackage -Name OpenAI.Codex | Sort-Object Version -Descending | Select-Object -First 1
if (-not $pkg) { throw 'OpenAI.Codex AppX package not found for this user.' }
$resources = Join-Path $pkg.InstallLocation 'app\resources'
$source = Join-Path $resources 'plugins\openai-bundled\plugins\chrome'
$pluginJson = Join-Path $source '.codex-plugin\plugin.json'
if (-not (Test-Path -LiteralPath $pluginJson)) { throw "Bundled Chrome plugin missing: $pluginJson" }
$version = (Get-Content -LiteralPath $pluginJson -Raw | ConvertFrom-Json).version
$base = Join-Path $codexHome 'plugins\cache\openai-bundled\chrome'
$latest = Join-Path $base 'latest'

Report 'AppX' "$($pkg.Version) at $($pkg.InstallLocation)" 'INFO'
Report 'Plugin version' $version 'INFO'
PathReport 'Bundled host' (Join-Path $source 'extension-host\windows\x64\extension-host.exe')
PathReport 'Versioned plugin cache' (Join-Path $base "$version\.codex-plugin\plugin.json")
PathReport 'latest host' (Join-Path $latest 'extension-host\windows\x64\extension-host.exe')
PathReport 'v1 native host manifest' (Join-Path $env:LOCALAPPDATA "OpenAI\extension\$hostName.json")
PathReport 'host config' (Join-Path $latest 'extension-host\windows\x64\extension-host-config.json')
RegistryReport 'Chrome' "Registry::HKEY_CURRENT_USER\Software\Google\Chrome\NativeMessagingHosts\$hostName"
RegistryReport 'Edge' "Registry::HKEY_CURRENT_USER\Software\Microsoft\Edge\NativeMessagingHosts\$hostName"
foreach ($file in @((Join-Path $appLocal 'chrome-native-hosts-v2.json'), (Join-Path $codexHome 'chrome-native-hosts-v2.json'))) {
    if (-not (Test-Path -LiteralPath $file)) { PathReport 'v2 registry' $file; continue }
    try {
        $doc = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
        $bad = @($doc.entries | Where-Object {
            $_.schemaVersion -ne 2 -or -not $_.paths -or
            @($_.paths.PSObject.Properties | Where-Object { $_.Name -ne 'codexHome' -and -not (Test-Path -LiteralPath $_.Value) }).Count -gt 0
        })
        Report 'v2 registry' "$file ($(@($doc.entries).Count) entries)" $(if ($doc.schemaVersion -eq 2 -and @($doc.entries).Count -gt 0 -and $bad.Count -eq 0) { 'OK' } else { 'INVALID' })
    } catch { Report 'v2 registry' "$file : $_" 'INVALID' }
}
$processes = @(Get-CimInstance Win32_Process -Filter "Name = 'extension-host.exe'" -ErrorAction SilentlyContinue)
Report 'Running extension-host.exe' $processes.Count $(if ($processes.Count) { 'OK' } else { 'INFO' })
