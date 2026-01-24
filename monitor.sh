#!/bin/bash

# Serial Monitor for ESP8266/ESP32
# Usage:
#   ./monitor.sh
#   ./monitor.sh --port /dev/ttyUSB0 --baud 115200
#   ./monitor.sh --list-ports

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Helper functions
write_step() { echo -e "${CYAN}[*]${NC} $1"; }
write_ok() { echo -e "${GREEN}[+]${NC} $1"; }
write_err() { echo -e "${RED}[!]${NC} $1"; }
write_warn() { echo -e "${YELLOW}[?]${NC} $1"; }

# Default values
PORT=""
BAUD="115200"
LIST_PORTS=false
LOG_FILE=""
TIMESTAMP=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --port|-p)
            PORT="$2"
            shift 2
            ;;
        --baud|-b)
            BAUD="$2"
            shift 2
            ;;
        --list-ports|-l)
            LIST_PORTS=true
            shift
            ;;
        --log|-o)
            LOG_FILE="$2"
            shift 2
            ;;
        --timestamp|-t)
            TIMESTAMP=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Serial Monitor for ESP8266/ESP32"
            echo ""
            echo "Options:"
            echo "  -p, --port PORT      Serial port (e.g., /dev/ttyUSB0)"
            echo "  -b, --baud RATE      Baud rate (default: 115200)"
            echo "  -l, --list-ports     List available serial ports"
            echo "  -o, --log FILE       Save output to file"
            echo "  -t, --timestamp      Add timestamps to output"
            echo "  -h, --help           Show this help"
            echo ""
            echo "Keyboard shortcuts (in monitor):"
            echo "  Ctrl+C               Exit monitor"
            echo "  Ctrl+A, then X       Exit (if using screen)"
            echo ""
            echo "Common baud rates: 9600, 115200, 74880 (ESP boot messages)"
            exit 0
            ;;
        *)
            write_err "Unknown option: $1"
            exit 1
            ;;
    esac
done

echo ""
echo -e "${GREEN}=== Angler Serial Monitor ===${NC}"
echo ""

# ============================================
# Find available tools
# ============================================
MONITOR_TOOL=""

# Check for available tools (prefer simpler ones)
if command -v picocom &> /dev/null; then
    MONITOR_TOOL="picocom"
elif command -v minicom &> /dev/null; then
    MONITOR_TOOL="minicom"
elif command -v screen &> /dev/null; then
    MONITOR_TOOL="screen"
elif command -v cat &> /dev/null; then
    MONITOR_TOOL="cat"
fi

# ============================================
# List Ports Mode
# ============================================
list_ports() {
    write_step "Available serial ports:"
    echo ""
    
    local found=false
    
    # List /dev/ttyUSB* and /dev/ttyACM*
    for dev in /dev/ttyUSB* /dev/ttyACM*; do
        if [[ -e "$dev" ]]; then
            found=true
            # Get device info if possible
            local info=""
            if command -v udevadm &> /dev/null; then
                info=$(udevadm info -q property "$dev" 2>/dev/null | grep -E "ID_MODEL=|ID_VENDOR=" | head -2 | tr '\n' ' ' || true)
            fi
            if [[ -n "$info" ]]; then
                echo "  $dev  ($info)"
            else
                echo "  $dev"
            fi
        fi
    done
    
    if [[ "$found" == false ]]; then
        write_warn "No serial ports found"
        echo ""
        echo "Make sure:"
        echo "  1. Device is connected via USB"
        echo "  2. USB cable supports data (not charge-only)"
        echo "  3. Driver is installed (CH340/CP2102)"
    fi
}

if [[ "$LIST_PORTS" == true ]]; then
    list_ports
    exit 0
fi

# ============================================
# Port Selection
# ============================================
if [[ -z "$PORT" ]]; then
    # Find available ports
    PORTS=()
    for dev in /dev/ttyUSB* /dev/ttyACM*; do
        if [[ -e "$dev" ]]; then
            PORTS+=("$dev")
        fi
    done
    
    if [[ ${#PORTS[@]} -eq 0 ]]; then
        write_err "No serial ports found!"
        echo ""
        echo "Connect your device via USB."
        exit 1
    fi
    
    if [[ ${#PORTS[@]} -eq 1 ]]; then
        PORT="${PORTS[0]}"
        write_ok "Auto-selected port: $PORT"
    else
        echo ""
        write_warn "Multiple ports found. Select one:"
        for i in "${!PORTS[@]}"; do
            echo "  $((i+1)). ${PORTS[$i]}"
        done
        echo ""
        read -p "Enter number (1-${#PORTS[@]}): " port_choice
        port_index=$((port_choice - 1))
        
        if [[ $port_index -lt 0 || $port_index -ge ${#PORTS[@]} ]]; then
            write_err "Invalid selection!"
            exit 1
        fi
        
        PORT="${PORTS[$port_index]}"
    fi
fi

# ============================================
# Check Port
# ============================================
if [[ ! -e "$PORT" ]]; then
    write_err "Port $PORT does not exist!"
    list_ports
    exit 1
fi

# Check permissions (skip if running as root)
if [[ $EUID -ne 0 ]]; then
    if [[ ! -r "$PORT" || ! -w "$PORT" ]]; then
        write_err "Cannot access port $PORT (permission denied)"
        echo ""
        echo "Fix permissions:"
        echo "  sudo usermod -aG dialout $USER"
        echo "  Then logout and login again"
        echo ""
        echo "Or run with sudo (not recommended):"
        echo "  sudo $0 --port $PORT"
        exit 1
    fi
fi

# ============================================
# Check if port is busy
# ============================================
if command -v fuser &> /dev/null; then
    if fuser "$PORT" &>/dev/null; then
        write_warn "Port $PORT might be in use by another program"
        read -p "Continue anyway? (y/N): " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            exit 0
        fi
    fi
fi

# ============================================
# Start Monitor
# ============================================
echo ""
write_step "Starting monitor..."
echo "  Port: $PORT"
echo "  Baud: $BAUD"
if [[ -n "$LOG_FILE" ]]; then
    echo "  Log:  $LOG_FILE"
fi
echo ""
write_warn "Press Ctrl+C to exit"
echo ""
echo -e "${CYAN}--- Serial Output ---${NC}"
echo ""

# Function to add timestamp
add_timestamp() {
    if [[ "$TIMESTAMP" == true ]]; then
        while IFS= read -r line; do
            echo "[$(date '+%H:%M:%S.%3N')] $line"
        done
    else
        cat
    fi
}

# Function to tee to log file if specified
log_output() {
    if [[ -n "$LOG_FILE" ]]; then
        tee -a "$LOG_FILE"
    else
        cat
    fi
}

# Handle cleanup
cleanup() {
    echo ""
    echo -e "${CYAN}--- Monitor stopped ---${NC}"
    # Reset terminal settings if needed
    stty sane 2>/dev/null || true
    exit 0
}
trap cleanup EXIT INT TERM

# Configure serial port
stty -F "$PORT" "$BAUD" raw -echo -echoe -echok 2>/dev/null || true

case "$MONITOR_TOOL" in
    picocom)
        write_ok "Using picocom (Ctrl+A, Ctrl+X to exit)"
        if [[ -n "$LOG_FILE" ]]; then
            picocom -b "$BAUD" "$PORT" | add_timestamp | log_output
        else
            picocom -b "$BAUD" "$PORT"
        fi
        ;;
    minicom)
        write_ok "Using minicom (Ctrl+A, X to exit)"
        if [[ -n "$LOG_FILE" ]]; then
            minicom -b "$BAUD" -D "$PORT" -C "$LOG_FILE"
        else
            minicom -b "$BAUD" -D "$PORT"
        fi
        ;;
    screen)
        write_ok "Using screen (Ctrl+A, K to exit)"
        if [[ -n "$LOG_FILE" ]]; then
            screen -L -Logfile "$LOG_FILE" "$PORT" "$BAUD"
        else
            screen "$PORT" "$BAUD"
        fi
        ;;
    cat|*)
        # Simple cat-based monitor (read-only but works everywhere)
        write_ok "Using simple monitor (Ctrl+C to exit)"
        cat "$PORT" | add_timestamp | log_output
        ;;
esac
