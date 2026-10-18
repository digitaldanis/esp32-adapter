#!/bin/bash
# Print the state of every layer between the ESP32 and your headset, with hints.
# Safe to run any time; it changes nothing.
set -uo pipefail

ok()   { printf '  \033[32m✔\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✘\033[0m %s\n' "$*"; }

echo "Transport"
if systemctl is-active --quiet esp32-airbridge.service; then
    ok "esp32-airbridge.service running"
else
    bad "esp32-airbridge.service not running  →  journalctl -u esp32-airbridge -n 30"
fi
ready=$(journalctl -u esp32-airbridge -n 50 --no-pager -q 2>/dev/null | grep READY | tail -1)
[ -n "$ready" ] && ok "${ready##*]: }" || warn "no READY line in the service log (needs journal access)"

echo "Bluetooth"
adapters=$(btmgmt info 2>/dev/null | awk '/^hci[0-9]+:/ {idx=$1} /manufacturer 96/ {print idx}' | tr -d ':')
if [ -n "$adapters" ]; then
    for a in $adapters; do ok "$a is an Espressif controller"; done
else
    bad "no ESP32 controller registered with BlueZ"
fi
while read -r _ mac name; do
    [ -n "$mac" ] || continue
    if bluetoothctl info "$mac" 2>/dev/null | grep -q "Connected: yes"; then
        ok "$name ($mac) connected"
    else
        warn "$name ($mac) paired but not connected"
    fi
done < <(bluetoothctl devices Paired 2>/dev/null)

echo "Audio"
if [ "$(wpctl settings bluetooth.autoswitch-to-headset-profile 2>/dev/null | awk '/Value:/ {print $2}')" = true ]; then
    ok "auto-switch to headset profile on"
else
    bad "auto-switch to headset profile off: no microphone in music mode  →  ./scripts/audio-setup.sh"
fi
state=${XDG_STATE_HOME:-$HOME/.local/state}/wireplumber/bluetooth-autoswitch
if grep -q '=headset-head-unit-cvsd$' "$state" 2>/dev/null; then
    bad "a headset is set to remember CVSD, which this controller cannot carry  →  ./scripts/audio-setup.sh"
fi
for card in $(pactl list short cards 2>/dev/null | awk '$2 ~ /^bluez_card\./ {print $2}'); do
    profile=$(pactl list cards | awk -v c="$card" '$1=="Name:"{on=($2==c)} on && /Active Profile:/ {print $3}')
    case "$profile" in
        a2dp-sink-sbc|a2dp-sink-sbc_xq) ok "$card: $profile" ;;
        a2dp-sink)                      warn "$card: AAC can stutter over the UART link  →  ./scripts/audio-setup.sh" ;;
        headset-head-unit)              ok "$card: $profile (mSBC call mode)" ;;
        headset-head-unit-cvsd)         bad "$card: CVSD call mode will not work  →  ./scripts/audio-setup.sh" ;;
        *)                              warn "$card: $profile" ;;
    esac
done

echo "Radio"
# A running scan (Bluetooth settings window, `bluetoothctl scan on`) makes the single
# radio do Classic inquiry + LE scanning, which interrupts A2DP every ~16 s.
if bluetoothctl show 2>/dev/null | grep -q "Discovering: yes"; then
    warn "scanning is active: audio drops out while it runs  →  close the Bluetooth settings window / run 'bluetoothctl scan off'"
else
    ok "no device scan running"
fi
