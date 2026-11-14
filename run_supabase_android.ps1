<#
.SYNOPSIS
  Runs CricEco on a connected Android device against Supabase.

.DESCRIPTION
  Reads the build values from supabase.local.json (project root) through
  --dart-define-from-file. This script stores no credentials and never
  prints the URL or the key: it only reports pass / fail for each check.

  Checks before launching:
    1. supabase.local.json exists, is valid JSON with the four expected
       fields, CRICECO_BACKEND = supabase, CRICECO_DEMO = false, and the key
       is a publishable key (never a secret / service-role key).
    2. supabase.local.json is ignored by Git and not tracked.
    3. An Android device is connected (pick one with -DeviceId when several).

.PARAMETER DeviceId
  The Android device id from `flutter devices`. Optional with one device.

.PARAMETER Release
  Build in release mode (default: debug).

.PARAMETER CheckOnly
  Run the checks only; do not launch the app.

.PARAMETER Flutter
  Path to flutter.bat (default: C:\src\flutter\bin\flutter.bat).

.EXAMPLE
  .\run_supabase_android.ps1 -CheckOnly
.EXAMPLE
  .\run_supabase_android.ps1 -DeviceId R58M12ABCDE
#>
param(
  [string]$DeviceId,
  [switch]$Release,
  [switch]$CheckOnly,
  [string]$Flutter = 'C:\src\flutter\bin\flutter.bat'
)

# No global ErrorActionPreference = 'Stop': in Windows PowerShell 5.1 it
# turns a native command's stderr (git, flutter) into a terminating error.
# Cmdlets that must fail loudly use -ErrorAction Stop instead.
$configName = 'supabase.local.json'

function Stop-WithError([string]$message) {
  Write-Host "ERROR: $message" -ForegroundColor Red
  exit 1
}

function Write-Ok([string]$message) {
  Write-Host "OK: $message" -ForegroundColor Green
}

# Always run from the project root (where this script lives).
Set-Location -LiteralPath $PSScriptRoot

if (-not (Test-Path -LiteralPath $Flutter -PathType Leaf)) {
  Stop-WithError "Flutter not found at $Flutter (pass -Flutter <path to flutter.bat>)."
}

# --- 1. Local configuration ---------------------------------------------------
$configPath = Join-Path $PSScriptRoot $configName
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
  Stop-WithError "$configName not found in the project root."
}
try {
  $config = Get-Content -LiteralPath $configPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
} catch {
  # The parser message could quote the file's contents: never show it.
  Stop-WithError "$configName is not valid JSON."
}
if ($null -eq $config) { Stop-WithError "$configName is empty." }

$required = @('CRICECO_BACKEND', 'CRICECO_DEMO', 'SUPABASE_URL', 'SUPABASE_PUBLISHABLE_KEY')
$names = @($config.PSObject.Properties.Name)
foreach ($name in $required) {
  if ($names -cnotcontains $name) { Stop-WithError "$configName is missing $name." }
}
if ("$($config.CRICECO_BACKEND)" -cne 'supabase') {
  Stop-WithError "CRICECO_BACKEND must be 'supabase'."
}
if ("$($config.CRICECO_DEMO)".ToLowerInvariant() -ne 'false') {
  Stop-WithError "CRICECO_DEMO must be false for a Supabase build."
}

$url = "$($config.SUPABASE_URL)"
$uri = $null
if (-not [Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$uri) -or
    $uri.Scheme -ne 'https' -or $url -match '\s') {
  Stop-WithError "SUPABASE_URL must be an https URL (https://<project-ref>.supabase.co)."
}

$key = "$($config.SUPABASE_PUBLISHABLE_KEY)"
if ($key.Trim().Length -eq 0) { Stop-WithError 'SUPABASE_PUBLISHABLE_KEY is empty.' }
if ($key.StartsWith('sb_secret_')) {
  Stop-WithError 'SUPABASE_PUBLISHABLE_KEY is a secret key. Use the publishable key only.'
}
$parts = $key.Split('.')
if ($parts.Count -eq 3) {
  # A legacy JWT key: refuse the service_role one.
  try {
    $payload = $parts[1].Replace('-', '+').Replace('_', '/')
    switch ($payload.Length % 4) { 2 { $payload += '==' } 3 { $payload += '=' } }
    $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json -ErrorAction Stop
    if ($claims.role -eq 'service_role') {
      Stop-WithError 'SUPABASE_PUBLISHABLE_KEY is a service-role key. Use the publishable key only.'
    }
  } catch {
    # Not decodable: the app's own startup check decides.
  }
}
Write-Ok "$configName is valid (backend supabase, demo off, https URL, publishable key)."

# --- 2. Git must ignore the configuration -------------------------------------
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  Stop-WithError 'git not found: cannot confirm the configuration is ignored.'
}
& git check-ignore -q -- $configName
if ($LASTEXITCODE -ne 0) {
  Stop-WithError "$configName is NOT ignored by Git. Add it to .gitignore first."
}
& git ls-files --error-unmatch -- $configName 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) {
  Stop-WithError "$configName is tracked by Git. Remove it from the index before running."
}
Write-Ok "$configName is ignored by Git and not tracked."

# --- 3. A connected Android device --------------------------------------------
$devicesOutput = (& $Flutter devices --machine 2>$null) -join "`n"
$start = $devicesOutput.IndexOf('[')
if ($start -lt 0) { Stop-WithError 'Could not read the device list from flutter devices.' }
try {
  $parsed = $devicesOutput.Substring($start) | ConvertFrom-Json -ErrorAction Stop
  # Windows PowerShell 5.1 emits a JSON array as ONE object: enumerate it.
  $devices = @($parsed | ForEach-Object { $_ })
} catch {
  Stop-WithError 'Could not read the device list from flutter devices.'
}
$android = @($devices | Where-Object { "$($_.targetPlatform)" -like 'android*' })
if ($android.Count -eq 0) {
  Stop-WithError 'No Android device connected. Connect the phone with USB debugging on and accept the prompt.'
}
if ($DeviceId) {
  $device = $android | Where-Object { $_.id -eq $DeviceId } | Select-Object -First 1
  if ($null -eq $device) { Stop-WithError "Android device '$DeviceId' is not connected." }
} elseif ($android.Count -eq 1) {
  $device = $android[0]
} else {
  Write-Host 'Several Android devices are connected:'
  $android | ForEach-Object { Write-Host "  $($_.id)  $($_.name)" }
  Stop-WithError 'Choose one with -DeviceId <id>.'
}
$kind = 'physical device'
if ($device.emulator) { $kind = 'emulator' }
Write-Ok "Android $kind '$($device.name)' ($($device.id))."

if ($CheckOnly) {
  Write-Host 'All checks passed (-CheckOnly: the app was not launched).'
  exit 0
}

# --- Launch -------------------------------------------------------------------
$runArgs = @('run', '-d', $device.id, "--dart-define-from-file=$configName")
if ($Release) { $runArgs += '--release' }
$mode = 'debug'
if ($Release) { $mode = 'release' }
Write-Host "Launching CricEco in Supabase mode ($mode)..."
& $Flutter @runArgs
exit $LASTEXITCODE
