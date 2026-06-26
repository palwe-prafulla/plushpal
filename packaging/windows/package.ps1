$ErrorActionPreference = "Stop"
$Root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$Version = if ($env:PLUSHPAL_VERSION) { $env:PLUSHPAL_VERSION } else { "0.1.0" }
$Output = Join-Path $Root "dist\windows\PlushPal-$Version"

Push-Location (Join-Path $Root "apps\android\flutter_app")
flutter build web --release --pwa-strategy=none --no-web-resources-cdn
Pop-Location

$Assets = Join-Path $Root "apps\station\macstation_host\assets\flutter_web"
if (Test-Path $Assets) { Remove-Item -Recurse -Force $Assets }
Copy-Item -Recurse (Join-Path $Root "apps\android\flutter_app\build\web") $Assets

Push-Location $Root
cargo build --release -p plushpal-desktop-host --features native-runtime
Pop-Location

if (Test-Path $Output) { Remove-Item -Recurse -Force $Output }
New-Item -ItemType Directory -Force $Output | Out-Null
Copy-Item (Join-Path $Root "target\release\plushpal-desktop-host.exe") (Join-Path $Output "PlushPal.exe")
$LlamaDll = Get-ChildItem (Join-Path $Root "target\release\build") -Recurse -Filter "plushpal_llama.dll" | Select-Object -First 1
if (-not $LlamaDll) { throw "plushpal_llama.dll was not produced" }
Copy-Item $LlamaDll.FullName (Join-Path $Output "plushpal_llama.dll")
Compress-Archive -Force -Path $Output -DestinationPath "$Output.zip"
