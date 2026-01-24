<#
.SYNOPSIS
    Angler Power Monitor - Firmware Flash Script for Windows
.DESCRIPTION
    Supports: Wemos D1 Mini, NodeMCU ESP8266, ESP32, ESP32-C3, ESP32-C6
.EXAMPLE
    .\flash.ps1
    .\flash.ps1 -Board wemos -Port COM3 -SSID "WiFi" -Password "pass" -Token "abc"
#>

param(
    [ValidateSet("wemos", "esp8266", "esp32", "esp32c3", "esp32c6")]
    [string]$Board,
    [string]$Port,
    [string]$SSID,
    [string]$Password,
    [string]$Token,
    [string]$Server = "https://api.angler.com.ua",
    [switch]$ListPorts,
    [switch]$SkipCoreInstall,
    [switch]$CompileOnly
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$env:ARDUINO_DIRECTORIES_USER = "$env:LOCALAPPDATA\Arduino"
$env:ARDUINO_DIRECTORIES_DATA = "$env:LOCALAPPDATA\Arduino"

function Write-Step  { param($msg) Write-Host "[*] $msg" -ForegroundColor Cyan }
function Write-OK    { param($msg) Write-Host "[+] $msg" -ForegroundColor Green }
function Write-Err   { param($msg) Write-Host "[!] $msg" -ForegroundColor Red }
function Write-Warn  { param($msg) Write-Host "[?] $msg" -ForegroundColor Yellow }

function Find-ArduinoCLI {
    $cli = Get-Command "arduino-cli" -ErrorAction SilentlyContinue
    if ($cli) { return $cli.Path }
    
    $locations = @(
        "$env:LOCALAPPDATA\arduino-cli\arduino-cli.exe",
        "$env:ProgramFiles\Arduino CLI\arduino-cli.exe",
        "$env:USERPROFILE\arduino-cli\arduino-cli.exe"
    )
    
    foreach ($path in $locations) {
        if (Test-Path $path) { return $path }
    }
    
    $wingetPath = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages"
    if (Test-Path $wingetPath) {
        $found = Get-ChildItem -Path $wingetPath -Recurse -Filter "arduino-cli.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { return $found.FullName }
    }
    
    return $null
}

Write-Host ""
Write-Host "=== Angler Firmware Flash Tool ===" -ForegroundColor Green
Write-Host ""

Write-Step "Searching for Arduino CLI..."
$cli = Find-ArduinoCLI

if (-not $cli) {
    Write-Err "Arduino CLI not found!"
    Write-Host "Install: winget install Arduino.arduino-cli"
    exit 1
}

Write-OK "Found: $cli"

$configDir = "$env:LOCALAPPDATA\arduino-cli"
$configFile = "$configDir\arduino-cli.yaml"
$arduinoDir = "$env:LOCALAPPDATA\Arduino"

New-Item -ItemType Directory -Path $configDir -Force -ErrorAction SilentlyContinue | Out-Null
New-Item -ItemType Directory -Path $arduinoDir -Force -ErrorAction SilentlyContinue | Out-Null

@"
board_manager:
  additional_urls:
    - https://arduino.esp8266.com/stable/package_esp8266com_index.json
    - https://raw.githubusercontent.com/espressif/arduino-esp32/gh-pages/package_esp32_index.json
directories:
  user: $arduinoDir
  data: $arduinoDir
  downloads: $arduinoDir\staging
"@ | Set-Content $configFile -Encoding UTF8

if ($ListPorts) {
    Write-Step "Available COM ports:"
    & $cli board list --config-file $configFile 2>$null
    [System.IO.Ports.SerialPort]::GetPortNames() | ForEach-Object { Write-Host "  $_" }
    exit 0
}

if (-not $Board) {
    Write-Host ""
    Write-Warn "Select board:"
    Write-Host "  1. Wemos D1 Mini"
    Write-Host "  2. NodeMCU ESP8266"
    Write-Host "  3. ESP32 DevKit"
    Write-Host "  4. ESP32-C3 SuperMini"
    Write-Host "  5. ESP32-C6 (5 GHz WiFi)"
    Write-Host ""
    
    $choice = Read-Host "Enter 1-5 [1]"
    $Board = switch ($choice) {
        "" { "wemos" }
        "1" { "wemos" }
        "2" { "esp8266" }
        "3" { "esp32" }
        "4" { "esp32c3" }
        "5" { "esp32c6" }
        default { "wemos" }
    }
}

Write-OK "Board: $Board"

$boardConfig = @{
    "wemos"   = @{ FQBN = "esp8266:esp8266:d1_mini";    Core = "esp8266:esp8266"; Folder = "esp8266" }
    "esp8266" = @{ FQBN = "esp8266:esp8266:nodemcuv2"; Core = "esp8266:esp8266"; Folder = "esp8266" }
    "esp32"   = @{ FQBN = "esp32:esp32:esp32";         Core = "esp32:esp32";     Folder = "esp32" }
    "esp32c3" = @{ FQBN = "esp32:esp32:esp32c3";       Core = "esp32:esp32";     Folder = "esp32c3" }
    "esp32c6" = @{ FQBN = "esp32:esp32:esp32c6";       Core = "esp32:esp32";     Folder = "esp32c6" }
}

$fqbn = $boardConfig[$Board].FQBN
$coreName = $boardConfig[$Board].Core
$firmwareFolder = $boardConfig[$Board].Folder

if (-not $SSID) {
    Write-Host ""
    $SSID = Read-Host "WiFi SSID"
    if ([string]::IsNullOrWhiteSpace($SSID)) { Write-Err "SSID required!"; exit 1 }
}

if (-not $Password) {
    $Password = Read-Host "WiFi Password"
    if ([string]::IsNullOrWhiteSpace($Password)) { Write-Warn "Empty password" }
}

if (-not $Token) {
    Write-Host ""
    Write-Host "Get token: @angler_energy_bot" -ForegroundColor DarkGray
    $Token = Read-Host "Device Token"
    if ([string]::IsNullOrWhiteSpace($Token)) { Write-Err "Token required!"; exit 1 }
}

Write-Host ""
Write-Host "Configuration:" -ForegroundColor Yellow
Write-Host "  Board:    $Board ($fqbn)"
Write-Host "  SSID:     $SSID"
Write-Host "  Password: $Password"
Write-Host "  Token:    $($Token.Substring(0, [Math]::Min(8, $Token.Length)))..."
Write-Host ""

if (-not $CompileOnly) {
    $confirm = Read-Host "Continue? [Y/n]"
    if ($confirm -eq "n" -or $confirm -eq "N") { Write-Warn "Cancelled"; exit 0 }
}

Write-Host ""
Write-Step "Updating board index..."
& $cli core update-index --config-file $configFile 2>$null | Out-Null
Write-OK "Done"

if (-not $SkipCoreInstall) {
    Write-Step "Checking $coreName core..."
    $coreList = & $cli core list --config-file $configFile 2>$null | Out-String
    
    if ($coreList -match [regex]::Escape($coreName)) {
        Write-OK "Core installed"
    } else {
        Write-Warn "Installing $coreName (5-10 min)..."
        & $cli core install $coreName --config-file $configFile 2>&1 | Out-Null
        Write-OK "Core installed"
    }
}

if ($CompileOnly) {
    Write-Step "Compile-only mode"
} elseif (-not $Port) {
    Write-Host ""
    Write-Step "Detecting COM ports..."
    
    $ports = [System.IO.Ports.SerialPort]::GetPortNames()
    
    if ($ports.Count -eq 0) {
        Write-Err "No COM ports found!"
        exit 1
    }
    
    Write-Host ""
    Write-Warn "Select port:"
    for ($i = 0; $i -lt $ports.Count; $i++) {
        Write-Host "  $($i + 1). $($ports[$i])"
    }
    Write-Host ""
    
    $portChoice = Read-Host "Enter number [1]"
    if ([string]::IsNullOrWhiteSpace($portChoice)) { $portChoice = "1" }
    $portIndex = [int]$portChoice - 1
    
    if ($portIndex -lt 0 -or $portIndex -ge $ports.Count) { Write-Err "Invalid!"; exit 1 }
    $Port = $ports[$portIndex]
}

if (-not $CompileOnly) {
    Write-OK "Port: $Port"
}

Write-Host ""
Write-Step "Preparing firmware..."

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$firmwareDir = Join-Path $scriptDir $firmwareFolder
$buildDir = Join-Path $env:TEMP "angler_build_$(Get-Random)"

if (-not (Test-Path $firmwareDir)) { Write-Err "Firmware not found: $firmwareDir"; exit 1 }

New-Item -ItemType Directory -Path $buildDir -Force | Out-Null
Copy-Item "$firmwareDir\*" $buildDir -Recurse

$inoFiles = Get-ChildItem -Path $buildDir -Filter "*.ino"
if ($inoFiles.Count -gt 0) {
    $buildName = Split-Path -Leaf $buildDir
    $newIno = Join-Path $buildDir "$buildName.ino"
    if ($inoFiles[0].FullName -ne $newIno) {
        Move-Item $inoFiles[0].FullName $newIno -Force
    }
}

function Escape-CString { param($str) $str -replace '\\', '\\' -replace '"', '\"' }

@"
#ifndef CONFIG_H
#define CONFIG_H

const char* WIFI_SSID = "$(Escape-CString $SSID)";
const char* WIFI_PASSWORD = "$(Escape-CString $Password)";
const char* SERVER_URL = "$Server";
const char* DEVICE_TOKEN = "$(Escape-CString $Token)";

const unsigned long HEARTBEAT_INTERVAL = 30000;
const unsigned long WIFI_TIMEOUT = 30000;

#define DEBUG_SERIAL 1

#endif
"@ | Set-Content (Join-Path $buildDir "config.h") -Encoding UTF8

Write-OK "Config ready"

Write-Host ""
Write-Step "Compiling for $Board..."

$compileOutput = & $cli compile --fqbn $fqbn --config-file $configFile $buildDir 2>&1 | Out-String
$compileExitCode = $LASTEXITCODE

$compileOutput -split "`n" | Select-Object -Last 5 | ForEach-Object { if ($_.Trim()) { Write-Host "  $_" -ForegroundColor DarkGray } }

if ($compileExitCode -ne 0) {
    Write-Err "Compilation failed!"
    Write-Host $compileOutput
    Remove-Item $buildDir -Recurse -Force -ErrorAction SilentlyContinue
    exit 1
}

Write-OK "Compiled"

if ($CompileOnly) {
    Remove-Item $buildDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host ""
    Write-Host "=== Compilation successful ===" -ForegroundColor Green
    exit 0
}

Write-Host ""
Write-Step "Uploading to $Port..."
Write-Host "  Tip: Hold BOOT if upload stalls" -ForegroundColor DarkGray

$uploadOutput = & $cli upload -p $Port --fqbn $fqbn --config-file $configFile $buildDir 2>&1 | Out-String
$uploadExitCode = $LASTEXITCODE

$uploadOutput -split "`n" | Select-Object -Last 5 | ForEach-Object { if ($_.Trim()) { Write-Host "  $_" -ForegroundColor DarkGray } }

Remove-Item $buildDir -Recurse -Force -ErrorAction SilentlyContinue

if ($uploadExitCode -ne 0) {
    Write-Err "Upload failed!"
    Write-Host ""
    Write-Host "Tips:" -ForegroundColor Yellow
    Write-Host "  1. Hold BOOT button"
    Write-Host "  2. Use data USB cable"
    Write-Host "  3. Close Serial Monitor"
    exit 1
}

Write-OK "Done"

Write-Host ""
Write-Host "=== Device flashed! ===" -ForegroundColor Green
Write-Host ""
Write-Host "WiFi: $SSID"
Write-Host ""
Write-Host "LED:"
Write-Host "  Blinking fast = connecting"
Write-Host "  Short blink = working"
Write-Host "  Solid on = token error"
Write-Host ""
