#!/bin/bash
# Remove everything install.sh put on the system. Pairings in BlueZ are left alone.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "error: run with sudo" >&2; exit 1; }

systemctl disable --now esp32-airbridge.service 2>/dev/null || true
rm -f /etc/systemd/system/esp32-airbridge.service \
      /etc/udev/rules.d/70-esp32-airbridge.rules \
      /etc/modules-load.d/esp32-airbridge.conf
rm -rf /usr/local/lib/esp32-airbridge
systemctl daemon-reload
udevadm control --reload-rules
echo "ESP32 AirBridge removed."
