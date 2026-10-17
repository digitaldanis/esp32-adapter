#!/bin/bash
# Install the Linux side of ESP32 AirBridge: host transport, systemd unit, udev rule.
# Usage: sudo ./scripts/install.sh [/dev/serial/by-id/<your-esp32>]
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
DESTDIR=${DESTDIR:-}
LIB=$DESTDIR/usr/local/lib/esp32-airbridge
UNIT=$DESTDIR/etc/systemd/system/esp32-airbridge.service
RULE=$DESTDIR/etc/udev/rules.d/70-esp32-airbridge.rules
MODULES=$DESTDIR/etc/modules-load.d/esp32-airbridge.conf

die() { echo "error: $*" >&2; exit 1; }

[ -n "$DESTDIR" ] || [ "$(id -u)" -eq 0 ] || die "run with sudo"
command -v btattach >/dev/null || die "btattach not found (install bluez / bluez-deprecated / bluez-tools)"
command -v btmgmt >/dev/null || die "btmgmt not found (install bluez)"

PORT=${1:-}
if [ -z "$PORT" ]; then
    mapfile -t ports < <(ls /dev/serial/by-id/ 2>/dev/null | grep -i -E 'CP210|CH34|FTDI|UART|Serial' || true)
    [ "${#ports[@]}" -eq 1 ] || die "found ${#ports[@]} candidate serial ports; pass one explicitly: sudo $0 /dev/serial/by-id/..."
    PORT=/dev/serial/by-id/${ports[0]}
fi
[ -e "$PORT" ] || [ -n "$DESTDIR" ] || die "$PORT does not exist"
case "$PORT" in /dev/serial/by-id/*) ;; *) echo "warning: $PORT is not a stable /dev/serial/by-id path" >&2 ;; esac

SERVICE_USER=${AIRBRIDGE_USER:-${SUDO_USER:-}}
[ -n "$SERVICE_USER" ] && [ "$SERVICE_USER" != root ] || die "set AIRBRIDGE_USER=<unprivileged user>"
DEVICE_UNIT=$(systemd-escape --path --suffix=device "$PORT")

echo "port:  $PORT"
echo "user:  $SERVICE_USER"

install -d -m 0755 "$LIB" "$(dirname "$UNIT")" "$(dirname "$RULE")" "$(dirname "$MODULES")"
install -m 0644 "$REPO/host/airbridge.py" "$LIB/airbridge.py"
# Unit names contain \x2d escapes; keep sed from interpreting them.
sed -e "s|@PORT@|$PORT|g" -e "s|@USER@|$SERVICE_USER|g" -e "s|@DEVICE_UNIT@|${DEVICE_UNIT//\\/\\\\}|g" \
    "$REPO/host/esp32-airbridge.service.in" > "$UNIT"
chmod 0644 "$UNIT"

# Start the transport whenever this exact board is plugged in, keep ModemManager
# away from it and stop USB autosuspend from dropping bytes.
VID=10c4 PID=ea60 SERIAL=
if [ -z "$DESTDIR" ]; then
    while IFS='=' read -r key value; do
        case "$key" in
            ID_VENDOR_ID) VID=$value ;;
            ID_MODEL_ID) PID=$value ;;
            ID_SERIAL_SHORT) SERIAL=$value ;;
        esac
    done < <(udevadm info --query=property --name="$PORT")
fi
MATCH="ATTRS{idVendor}==\"$VID\", ATTRS{idProduct}==\"$PID\""
[ -n "$SERIAL" ] && MATCH="$MATCH, ATTRS{serial}==\"$SERIAL\""
cat > "$RULE" <<EOF
SUBSYSTEM=="tty", $MATCH, TAG+="systemd", ENV{ID_MM_DEVICE_IGNORE}="1", ENV{ID_MM_PORT_IGNORE}="1", ENV{SYSTEMD_WANTS}+="esp32-airbridge.service"
SUBSYSTEM=="usb", ${MATCH//ATTRS/ATTR}, TEST=="power/control", ATTR{power/control}="on"
EOF
printf 'hci_uart\n' > "$MODULES"

[ -n "$DESTDIR" ] && { echo "staged into $DESTDIR"; exit 0; }

modprobe hci_uart
systemctl daemon-reload
udevadm control --reload-rules
udevadm trigger --action=add --subsystem-match=tty
systemctl enable --now bluetooth.service
systemctl enable esp32-airbridge.service
systemctl restart esp32-airbridge.service

for _ in $(seq 20); do
    journalctl -u esp32-airbridge -n 5 --no-pager -q | grep -q READY && break
    sleep 1
done
journalctl -u esp32-airbridge -n 5 --no-pager -q
echo
echo "Done. Pair your headset with bluetoothctl or your desktop's Bluetooth settings,"
echo "then run ./scripts/audio-setup.sh (as your normal user, not root)."
