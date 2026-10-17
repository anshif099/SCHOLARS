param(
    [string]$FlutterSdk,
    [string]$ChromeExecutable = "$env:ProgramFiles\Google\Chrome\Application\chrome.exe"
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
if (!$FlutterSdk) {
    $sdkProperty = Get-Content (Join-Path $projectRoot 'android\local.properties') |
        Where-Object { $_ -like 'flutter.sdk=*' } | Select-Object -First 1
    if (!$sdkProperty) { throw 'Pass -FlutterSdk with the installed Flutter SDK path.' }
    $FlutterSdk = $sdkProperty.Substring('flutter.sdk='.Length).Replace('\\', '\')
}
$dart = Join-Path $FlutterSdk 'bin\cache\dart-sdk\bin\dart.exe'
$flutterTools = Join-Path $FlutterSdk 'bin\cache\flutter_tools.snapshot'
$canvasKit = Join-Path $FlutterSdk 'bin\cache\flutter_web_sdk\canvaskit'
foreach ($requiredPath in @($dart, $flutterTools, $canvasKit, $ChromeExecutable)) {
    if (!(Test-Path -LiteralPath $requiredPath)) { throw "Missing test dependency: $requiredPath" }
}

$link = Join-Path $projectRoot 'test\canvaskit'
$wrapper = Join-Path $projectRoot ('.dart_tool\recording-chrome-{0}.cmd' -f [Guid]::NewGuid())
$previousChrome = $env:CHROME_EXECUTABLE
$createdAssets = $false
$testExitCode = 1
Push-Location $projectRoot
try {
    # Flutter 3.41's Windows test server misses CanvasKit because it compares
    # a Windows path to a URL prefix. Its static test-directory handler works.
    if (!(Test-Path -LiteralPath $link)) {
        $null = New-Item -ItemType Directory -Path $link
        $createdAssets = $true
        Copy-Item -Path (Join-Path $canvasKit '*') -Destination $link -Recurse -Force
    }
    # Headless Chrome has no user tap to unlock the generated test tone.
    ('@"{0}" --autoplay-policy=no-user-gesture-required %*' -f $ChromeExecutable) |
        Set-Content -LiteralPath $wrapper -Encoding Ascii
    $env:CHROME_EXECUTABLE = $wrapper
    & $dart $flutterTools test --no-pub --platform chrome test/web_recording_audio_test.dart --timeout 45s
    $testExitCode = $LASTEXITCODE
} finally {
    $env:CHROME_EXECUTABLE = $previousChrome
    if (Test-Path -LiteralPath $wrapper) { Remove-Item -LiteralPath $wrapper -Force }
    if ($createdAssets) {
        $temporaryAssets = Get-Item -LiteralPath $link -Force
        $expectedPath = [System.IO.Path]::GetFullPath((Join-Path $projectRoot 'test\canvaskit'))
        if ($temporaryAssets.FullName -ne $expectedPath -or
            ($temporaryAssets.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            throw 'Refusing to remove an unexpected temporary assets path.'
        }
        Remove-Item -LiteralPath $temporaryAssets.FullName -Recurse -Force
    }
    Pop-Location
}
exit $testExitCode
