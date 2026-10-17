#!/bin/bash
# Tune PipeWire/WirePlumber for headsets on the ESP32 AirBridge. Run as your desktop user
# with the headset connected. Settings are saved by WirePlumber and survive reconnects.
#
#   music: A2DP with SBC. SBC adapts its bitrate to the 921600-baud UART link;
#          AAC does not and stutters.
#   calls: HFP with mSBC (16 kHz). The ESP32 controller rejects CVSD eSCO links
#          to AirPods ("Invalid LMP Parameters"), so CVSD must not be remembered.
#   mic:   auto-switch to the headset profile whenever an app records.
#
# Usage: ./scripts/audio-setup.sh [AA:BB:CC:DD:EE:FF ...]   (default: every Bluetooth card)
#        A2DP_PROFILE=a2dp-sink ./scripts/audio-setup.sh     (keep AAC anyway)
set -euo pipefail

A2DP_PROFILE=${A2DP_PROFILE:-a2dp-sink-sbc}
HFP_PROFILE=${HFP_PROFILE:-headset-head-unit}

[ "$(id -u)" -ne 0 ] || { echo "error: run as your normal user, not root" >&2; exit 1; }
command -v wpctl >/dev/null && command -v pactl >/dev/null || { echo "error: needs PipeWire + WirePlumber (wpctl, pactl)" >&2; exit 1; }

wpctl settings --save bluetooth.autoswitch-to-headset-profile true >/dev/null
echo "auto-switch to headset when recording: on"

if [ $# -gt 0 ]; then
    cards=(); for mac in "$@"; do cards+=("bluez_card.${mac//:/_}"); done
else
    mapfile -t cards < <(pactl list short cards | awk '$2 ~ /^bluez_card\./ {print $2}')
fi
[ "${#cards[@]}" -gt 0 ] || { echo "No Bluetooth headset connected. Connect it and run this again."; exit 1; }

has_profile() { pactl list cards | awk -v c="$1" '$1=="Name:"{on=($2==c)} on' | grep -q "^[[:space:]]*$2: "; }

for card in "${cards[@]}"; do
    echo "$card"
    # Selecting a profile by hand is what makes WirePlumber remember it.
    if has_profile "$card" "$HFP_PROFILE"; then
        pactl set-card-profile "$card" "$HFP_PROFILE"; sleep 1
        echo "  calls: $HFP_PROFILE"
    else
        echo "  calls: $HFP_PROFILE not offered by this device, skipped"
    fi
    if has_profile "$card" "$A2DP_PROFILE"; then
        pactl set-card-profile "$card" "$A2DP_PROFILE"
        echo "  music: $A2DP_PROFILE"
    else
        echo "  music: $A2DP_PROFILE not offered by this device, skipped"
    fi
done
echo "Done. Pick the headset as microphone in your apps; it switches to call mode by itself."
