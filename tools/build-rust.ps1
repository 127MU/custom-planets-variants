param([switch]$Test, [string]$Payload)
$ErrorActionPreference = 'Stop'
$buildTemp = Join-Path $PSScriptRoot '..\build\rust-tmp'
New-Item -ItemType Directory -Path $buildTemp -Force | Out-Null
$env:TEMP = (Resolve-Path $buildTemp).Path
$env:TMP = $env:TEMP
$vs = & 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe' -latest -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$compiler = Get-ChildItem -LiteralPath "$vs\VC\Tools\MSVC" -Directory | Sort-Object Name -Descending | Select-Object -First 1
$sdk = Get-ChildItem -LiteralPath 'C:\Program Files (x86)\Windows Kits\10\Lib' -Directory | Sort-Object Name -Descending | Select-Object -First 1
if (!$compiler -or !$sdk) { throw 'MSVC compiler or Windows SDK not installed' }
$sdkBin = Join-Path 'C:\Program Files (x86)\Windows Kits\10\bin' "$($sdk.Name)\x64"
$env:PATH = "$env:CARGO_HOME\bin;$($compiler.FullName)\bin\Hostx64\x64;$sdkBin;$env:PATH"
$env:LIB = "$($compiler.FullName)\lib\x64;$($sdk.FullName)\ucrt\x64;$($sdk.FullName)\um\x64"
$resolvedPayload = if ($Payload) { (Resolve-Path -LiteralPath $Payload).Path } else { $null }
Push-Location "$PSScriptRoot\..\backend"
try {
    if ($Payload) {
        $env:CPV_PAYLOAD = $resolvedPayload
        cargo rustc --release --features bundle --bin cpv-launcher -- -C target-feature=+crt-static
    } elseif ($Test) { cargo test } else { cargo build --release }
    if ($LASTEXITCODE -ne 0) { throw "Rust build failed ($LASTEXITCODE)" }
} finally { Pop-Location }
