#!/bin/bash
# Back up the board's current flash, then write the AirBridge firmware.
# Usage: ./scripts/flash.sh <port> [esp32-airbridge-full.bin]
#   Without an image, firmware/build is used (run `idf.py build` in firmware/ first).
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
PORT=${1:?usage: $0 <port> [esp32-airbridge-full.bin]}
IMAGE=${2:-}
ESPTOOL=${ESPTOOL:-python3 -m esptool}
BAUD=${BAUD:-460800}

$ESPTOOL version >/dev/null 2>&1 || { echo "error: esptool not found (pip install esptool)" >&2; exit 1; }

# The host transport holds the serial port open.
if systemctl is-active --quiet esp32-airbridge.service 2>/dev/null; then
    echo "Stopping esp32-airbridge.service while flashing..."
    sudo systemctl stop esp32-airbridge.service
    trap 'sudo systemctl start esp32-airbridge.service' EXIT
fi

BACKUP=${BACKUP:-esp32-backup-$(date +%Y%m%d-%H%M%S).bin}
if [ "${SKIP_BACKUP:-0}" != 1 ]; then
    echo "Backing up the full 4 MB flash to $BACKUP (restore with: esptool write_flash 0 $BACKUP)"
    $ESPTOOL --chip esp32 --port "$PORT" --baud "$BAUD" read_flash 0 0x400000 "$BACKUP"
fi

if [ -n "$IMAGE" ]; then
    $ESPTOOL --chip esp32 --port "$PORT" --baud "$BAUD" write_flash \
        --flash_mode dio --flash_freq 40m --flash_size 4MB 0x0 "$IMAGE"
else
    BUILD=$REPO/firmware/build
    [ -f "$BUILD/flash_args" ] || { echo "error: no build found; run 'idf.py build' in firmware/ or pass an image" >&2; exit 1; }
    (cd "$BUILD" && $ESPTOOL --chip esp32 --port "$PORT" --baud "$BAUD" write_flash @flash_args)
fi
echo "Flashed. The ESP32 now speaks HCI at 921600 baud on its USB serial port."
