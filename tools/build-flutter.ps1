param([string]$UiPath = 'ui')

$ErrorActionPreference = 'Stop'
$project = Join-Path (Split-Path -Parent $PSScriptRoot) $UiPath
Push-Location -LiteralPath $project
try {
    # Icons selected dynamically from category data must remain in the font.
    flutter build windows --release --no-pub --no-tree-shake-icons
    if ($LASTEXITCODE -ne 0) { throw "Flutter build failed ($LASTEXITCODE)" }
} finally {
    Pop-Location
}
