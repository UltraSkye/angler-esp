#!/bin/bash
#
# Angler Power Monitor - Firmware Flash Script
# Supports: Wemos D1 Mini, NodeMCU ESP8266, ESP32, ESP32-C3, ESP32-C6
# Usage: ./flash.sh [--board TYPE] [--port PORT] [--ssid SSID] [--password PASS] [--token TOKEN]
#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_step()  { echo -e "${CYAN}[*]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[+]${NC} $1"; }
log_error() { echo -e "${RED}[!]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[?]${NC} $1"; }

BOARD=""
PORT=""
SSID=""
PASSWORD=""
TOKEN=""
SERVER="https://api.angler.com.ua"
LIST_PORTS=false
SKIP_CORE_INSTALL=false
COMPILE_ONLY=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --board)         BOARD="$2"; shift 2 ;;
        --port)          PORT="$2"; shift 2 ;;
        --ssid)          SSID="$2"; shift 2 ;;
        --password)      PASSWORD="$2"; shift 2 ;;
        --token)         TOKEN="$2"; shift 2 ;;
        --server)        SERVER="$2"; shift 2 ;;
        --list-ports)    LIST_PORTS=true; shift ;;
        --skip-core-install) SKIP_CORE_INSTALL=true; shift ;;
        --compile-only)  COMPILE_ONLY=true; shift ;;
        -h|--help)
            cat << 'EOF'
Angler Firmware Flash Tool

Usage: ./flash.sh [OPTIONS]

Options:
  --board TYPE           wemos, esp8266, esp32, esp32c3, esp32c6
  --port PORT            /dev/ttyUSB0, /dev/cu.usbserial-*
  --ssid SSID            WiFi network name
  --password PASSWORD    WiFi password
  --token TOKEN          Device token from @angler_energy_bot
  --server URL           Server URL (default: https://api.angler.com.ua)
  --list-ports           List available serial ports
  --skip-core-install    Skip Arduino core installation
  --compile-only         Only compile, don't upload
  -h, --help             Show this help

Examples:
  ./flash.sh
  ./flash.sh --board wemos --port /dev/ttyUSB0 --ssid "WiFi" --password "pass" --token "abc"
  ./flash.sh --compile-only --board esp32c3 --ssid "Test" --password "test" --token "test123"
EOF
            exit 0
            ;;
        *) log_error "Unknown option: $1"; exit 1 ;;
    esac
done

echo ""
echo -e "${GREEN}=== Angler Firmware Flash Tool ===${NC}"
echo ""

find_arduino_cli() {
    local REAL_HOME="$HOME"
    [[ -n "$SUDO_USER" ]] && REAL_HOME=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6) || true
    
    local locations=(
        "$REAL_HOME/.local/bin/arduino-cli"
        "$HOME/.local/bin/arduino-cli"
        "/usr/local/bin/arduino-cli"
        "/usr/bin/arduino-cli"
        "/snap/bin/arduino-cli"
        "/opt/homebrew/bin/arduino-cli"
    )
    
    for path in "${locations[@]}"; do
        [[ -f "$path" && -x "$path" ]] && echo "$path" && return 0
    done
    
    command -v arduino-cli 2>/dev/null && return 0
    return 1
}

log_step "Searching for Arduino CLI..."
CLI=$(find_arduino_cli) || CLI=""

if [[ -z "$CLI" ]]; then
    log_error "Arduino CLI not found!"
    echo ""
    echo "Install:"
    echo "  curl -fsSL https://raw.githubusercontent.com/arduino/arduino-cli/master/install.sh | sh"
    echo "  brew install arduino-cli  # macOS"
    echo "  sudo apt install arduino-cli  # Ubuntu/Debian"
    exit 1
fi

log_ok "Found: $CLI"

REAL_HOME="$HOME"
REAL_USER="$USER"
if [[ -n "$SUDO_USER" ]]; then
    REAL_HOME=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6) || REAL_HOME="$HOME"
    REAL_USER="$SUDO_USER"
    log_warn "Running as sudo (user: $REAL_USER)"
fi

CONFIG_DIR="$REAL_HOME/.arduino15"
CONFIG_FILE="$CONFIG_DIR/arduino-cli.yaml"
ARDUINO_DIR="$REAL_HOME/Arduino"

mkdir -p "$CONFIG_DIR" "$ARDUINO_DIR"

[[ $EUID -eq 0 && -n "$SUDO_USER" ]] && chown -R "$SUDO_USER:$SUDO_USER" "$CONFIG_DIR" "$ARDUINO_DIR" 2>/dev/null || true

cat > "$CONFIG_FILE" << EOF
board_manager:
  additional_urls:
    - https://arduino.esp8266.com/stable/package_esp8266com_index.json
    - https://raw.githubusercontent.com/espressif/arduino-esp32/gh-pages/package_esp32_index.json
directories:
  user: $ARDUINO_DIR
  data: $ARDUINO_DIR
  downloads: $ARDUINO_DIR/staging
EOF

if [[ "$LIST_PORTS" == true ]]; then
    log_step "Available serial ports:"
    echo ""
    "$CLI" board list --config-file "$CONFIG_FILE" 2>/dev/null || true
    echo ""
    ls -1 /dev/ttyUSB* /dev/ttyACM* /dev/cu.usbserial* /dev/cu.usbmodem* 2>/dev/null | sed 's/^/  /' || true
    exit 0
fi

if [[ -z "$BOARD" ]]; then
    echo ""
    log_warn "Select board:"
    echo "  1. Wemos D1 Mini"
    echo "  2. NodeMCU ESP8266"
    echo "  3. ESP32 DevKit"
    echo "  4. ESP32-C3 SuperMini"
    echo "  5. ESP32-C6 (5 GHz WiFi)"
    echo ""
    read -p "Enter 1-5 [1]: " choice
    
    case "$choice" in
        1|"") BOARD="wemos" ;;
        2) BOARD="esp8266" ;;
        3) BOARD="esp32" ;;
        4) BOARD="esp32c3" ;;
        5) BOARD="esp32c6" ;;
        *) BOARD="wemos" ;;
    esac
fi

case "$BOARD" in
    wemos|esp8266|esp32|esp32c3|esp32c6) ;;
    *) log_error "Invalid board: $BOARD"; exit 1 ;;
esac

declare -A BOARD_CONFIG=(
    ["wemos"]="esp8266:esp8266:d1_mini|esp8266:esp8266|esp8266"
    ["esp8266"]="esp8266:esp8266:nodemcuv2|esp8266:esp8266|esp8266"
    ["esp32"]="esp32:esp32:esp32|esp32:esp32|esp32"
    ["esp32c3"]="esp32:esp32:esp32c3|esp32:esp32|esp32c3"
    ["esp32c6"]="esp32:esp32:esp32c6|esp32:esp32|esp32c6"
)

IFS='|' read -r FQBN CORE_NAME FIRMWARE_FOLDER <<< "${BOARD_CONFIG[$BOARD]}"
log_ok "Board: $BOARD ($FQBN)"

if [[ -z "$SSID" ]]; then
    echo ""
    read -p "WiFi SSID: " SSID
    [[ -z "$SSID" ]] && log_error "SSID required!" && exit 1
fi

if [[ -z "$PASSWORD" ]]; then
    read -p "WiFi Password: " PASSWORD
    [[ -z "$PASSWORD" ]] && log_warn "Empty password (open network)"
fi

if [[ -z "$TOKEN" ]]; then
    echo ""
    echo "Get token: @angler_energy_bot"
    read -p "Device Token: " TOKEN
    [[ -z "$TOKEN" ]] && log_error "Token required!" && exit 1
fi

echo ""
echo -e "${YELLOW}Configuration:${NC}"
echo "  Board:    $BOARD ($FQBN)"
echo "  SSID:     $SSID"
echo "  Password: $PASSWORD"
echo "  Token:    ${TOKEN:0:8}..."
echo ""

if [[ "$COMPILE_ONLY" != true ]]; then
    read -p "Continue? [Y/n]: " confirm
    [[ "$confirm" =~ ^[Nn]$ ]] && log_warn "Cancelled" && exit 0
fi

echo ""
log_step "Updating board index..."
"$CLI" core update-index --config-file "$CONFIG_FILE" > /dev/null 2>&1 || true
log_ok "Done"

if [[ "$SKIP_CORE_INSTALL" != true ]]; then
    log_step "Checking $CORE_NAME core..."
    
    if "$CLI" core list --config-file "$CONFIG_FILE" 2>/dev/null | grep -q "$CORE_NAME"; then
        log_ok "Core installed"
    else
        log_warn "Installing $CORE_NAME (5-10 min)..."
        if ! "$CLI" core install "$CORE_NAME" --config-file "$CONFIG_FILE" 2>&1; then
            log_error "Core installation failed!"
            exit 1
        fi
        log_ok "Core installed"
    fi
fi

if [[ "$COMPILE_ONLY" == true ]]; then
    log_step "Compile-only mode"
elif [[ -z "$PORT" ]]; then
    echo ""
    log_step "Detecting ports..."
    
    PORTS=()
    
    for dev in /dev/ttyUSB* /dev/ttyACM* /dev/cu.usbserial* /dev/cu.usbmodem* /dev/cu.wchusbserial*; do
        [[ -e "$dev" ]] && PORTS+=("$dev")
    done
    
    if [[ ${#PORTS[@]} -eq 0 ]]; then
        log_error "No ports found! Connect your board."
        exit 1
    fi
    
    echo ""
    log_warn "Select port:"
    for i in "${!PORTS[@]}"; do
        echo "  $((i+1)). ${PORTS[$i]}"
    done
    echo ""
    
    read -p "Enter number [1]: " port_choice
    port_choice=${port_choice:-1}
    port_index=$((port_choice - 1))
    
    [[ $port_index -lt 0 || $port_index -ge ${#PORTS[@]} ]] && log_error "Invalid!" && exit 1
    PORT="${PORTS[$port_index]}"
fi

if [[ "$COMPILE_ONLY" != true ]]; then
    [[ ! -e "$PORT" ]] && log_error "Port $PORT not found!" && exit 1
    [[ $EUID -ne 0 && ! -r "$PORT" ]] && log_error "No access to $PORT. Run: sudo usermod -aG dialout \$USER" && exit 1
    log_ok "Port: $PORT"
fi

echo ""
log_step "Preparing firmware..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIRMWARE_DIR="$SCRIPT_DIR/$FIRMWARE_FOLDER"
BUILD_DIR=$(mktemp -d -t angler_build_XXXXXX)

trap "rm -rf '$BUILD_DIR'" EXIT

[[ ! -d "$FIRMWARE_DIR" ]] && log_error "Firmware not found: $FIRMWARE_DIR" && exit 1

cp -r "$FIRMWARE_DIR"/* "$BUILD_DIR/"

INO_FILE=$(find "$BUILD_DIR" -name "*.ino" -type f | head -n 1)
if [[ -n "$INO_FILE" ]]; then
    BUILD_NAME=$(basename "$BUILD_DIR")
    NEW_INO="$BUILD_DIR/$BUILD_NAME.ino"
    [[ "$INO_FILE" != "$NEW_INO" ]] && mv "$INO_FILE" "$NEW_INO"
fi

escape_c() { echo "$1" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g'; }

cat > "$BUILD_DIR/config.h" << EOF
#ifndef CONFIG_H
#define CONFIG_H

const char* WIFI_SSID = "$(escape_c "$SSID")";
const char* WIFI_PASSWORD = "$(escape_c "$PASSWORD")";
const char* SERVER_URL = "$SERVER";
const char* DEVICE_TOKEN = "$(escape_c "$TOKEN")";

const unsigned long HEARTBEAT_INTERVAL = 30000;
const unsigned long WIFI_TIMEOUT = 30000;

#define DEBUG_SERIAL 1

#endif
EOF

log_ok "Config ready"

echo ""
log_step "Compiling for $BOARD..."

COMPILE_OUTPUT=$("$CLI" compile --fqbn "$FQBN" --config-file "$CONFIG_FILE" "$BUILD_DIR" 2>&1)
COMPILE_EXIT=$?

echo "$COMPILE_OUTPUT" | grep -v "Documents Folder" | tail -5 || true

if [[ $COMPILE_EXIT -ne 0 ]]; then
    log_error "Compilation failed!"
    echo "$COMPILE_OUTPUT"
    exit 1
fi

log_ok "Compiled"

if [[ "$COMPILE_ONLY" == true ]]; then
    echo ""
    echo -e "${GREEN}=== Compilation successful ===${NC}"
    exit 0
fi

echo ""
log_step "Uploading to $PORT..."
echo "  Tip: Hold BOOT if upload stalls"

UPLOAD_OUTPUT=$("$CLI" upload -p "$PORT" --fqbn "$FQBN" --config-file "$CONFIG_FILE" "$BUILD_DIR" 2>&1)
UPLOAD_EXIT=$?

echo "$UPLOAD_OUTPUT" | grep -v "Documents Folder" | tail -5 || true

if [[ $UPLOAD_EXIT -ne 0 ]]; then
    log_error "Upload failed!"
    echo ""
    echo "Tips:"
    echo "  1. Hold BOOT button"
    echo "  2. Use data USB cable"
    echo "  3. Close Serial Monitor"
    exit 1
fi

log_ok "Done"

echo ""
echo -e "${GREEN}=== Device flashed! ===${NC}"
echo ""
echo "WiFi: $SSID"
echo ""
echo "LED:"
echo "  Blinking fast = connecting"
echo "  Short blink = working"
echo "  Solid on = token error"
echo ""
