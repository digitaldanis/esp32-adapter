<div align="center">

# ESP32 AirBridge

**Turn a $5 ESP32 dev board into a USB Bluetooth adapter for Linux.
Music *and* microphone with AirPods and other headsets.**

[![CI](https://github.com/digitaldanis/esp32-adapter/actions/workflows/ci.yml/badge.svg)](https://github.com/digitaldanis/esp32-adapter/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![ESP-IDF v5.5](https://img.shields.io/badge/ESP--IDF-v5.5-red)
![Platform: Linux](https://img.shields.io/badge/host-Linux%20%7C%20BlueZ%20%7C%20PipeWire-informational)

</div>

No Bluetooth on your PC, a broken built-in adapter, or just an ESP32 lying in a drawer?
AirBridge flashes the ESP32 into a plain **HCI controller** and hands it to the Linux
Bluetooth stack over the board's USB serial chip. To Linux it is just another Bluetooth
adapter: `bluetoothctl`, GNOME/KDE settings, PipeWire and every app work as usual.

```
$ bluetoothctl list
Controller 24:0A:C4:12:34:56 ESP32 AirBridge [default]
```

## Features

- 🎧 **A2DP music** to headphones and speakers (SBC, adaptive bitrate)
- 🎙️ **Headset microphone** over HFP with **mSBC wideband** (16 kHz) voice: calls, Discord, Zoom
- 🔁 **Automatic switching** between music and call mode when an app opens the mic
- 🧩 **Bluetooth Classic + BLE**, handled by BlueZ, so no custom pairing UI
- 🔌 **Plug and play**: a udev rule + systemd unit bring the adapter up on hotplug
- 🛡️ **Fail-loud transport**: corrupt or overflowing streams raise an HCI hardware error and the controller restarts instead of silently losing bytes
- 🩺 **`doctor.sh`** checks every layer from USB to the audio profile and tells you what to fix

## How it works

```mermaid
flowchart LR
    subgraph PC["Linux PC"]
        apps["Apps<br/>(Firefox, Discord, …)"] --> pw["PipeWire +<br/>WirePlumber"]
        pw --> bluez["BlueZ<br/>(bluetoothd + kernel)"]
        bluez --> hci["hci_uart (H4)<br/>via btattach"]
    end
    hci -- "USB ⇄ CP2102<br/>921600 baud" --> fw
    subgraph ESP["ESP32"]
        fw["AirBridge firmware<br/>H4 ⇄ VHCI bridge"] --> ctrl["Espressif BT controller<br/>(BR/EDR + LE radio)"]
    end
    ctrl -. "2.4 GHz" .-> head["🎧 AirPods / headset"]
```

The ESP32 runs **only** the Bluetooth controller (link layer + radio). Everything above it,
including pairing, profiles, codecs and audio routing, runs on Linux. The firmware is a small, strict
bridge between the UART and Espressif's virtual HCI (VHCI) interface, plus three targeted
fixes that make **headset voice audio** work on this controller (see
[How the microphone was fixed](#how-the-microphone-was-fixed)).

## Hardware

| | |
|---|---|
| **Chip** | Original **ESP32** (ESP32-D0WD, WROOM-32, WROVER, ESP-32U …). ESP32-S2/S3/C3/C6 do **not** support Bluetooth Classic audio and will not work. |
| **Board** | Any dev board with a USB-UART bridge on UART0 (GPIO1/GPIO3): CP2102, CH340, FT232 |
| **Flash** | 4 MB |
| **Antenna** | A board with an external antenna (U.FL/IPEX) noticeably improves range and stability |

**Tested setup:** ESP32-D0WD-V3 rev 3.1 board with CP2102 and external antenna, Fedora 44
(kernel 6.19, BlueZ 5.87, PipeWire with WirePlumber 0.5.13), Apple AirPods (2nd gen).

## Quick start

### 1. Flash the firmware

Grab `esp32-airbridge-full.bin` from the [latest release](https://github.com/digitaldanis/esp32-adapter/releases)
(or [build it yourself](#building-the-firmware)), then:

```sh
pip install esptool
./scripts/flash.sh /dev/ttyUSB0 esp32-airbridge-full.bin
```

The script first saves a **full backup** of your board's flash (`esp32-backup-<date>.bin`), so
you can always go back with `esptool write_flash 0 esp32-backup-….bin`.

### 2. Install the Linux side

Requirements: `bluez` (with `btattach`/`btmgmt`), `python3`, systemd, and the `hci_uart` kernel module
(included in all mainstream distro kernels).

```sh
sudo ./scripts/install.sh            # auto-detects the board under /dev/serial/by-id/
# or: sudo ./scripts/install.sh /dev/serial/by-id/usb-Silicon_Labs_CP2102_…-port0
```

This installs a systemd service that performs an HCI handshake with the ESP32, attaches it
with `btattach`, names the adapter **ESP32 AirBridge** and powers it on, every time the board
is plugged in.

> **Tip:** if your PC already has a Bluetooth adapter, select the ESP32 with
> `bluetoothctl select <address>` or disable the other one so headsets pair with the right controller.

### 3. Pair your headset

Use your desktop's Bluetooth settings, or:

```sh
bluetoothctl
[bluetooth]# scan on
[bluetooth]# pair XX:XX:XX:XX:XX:XX
[bluetooth]# trust XX:XX:XX:XX:XX:XX
[bluetooth]# connect XX:XX:XX:XX:XX:XX
```

### 4. Tune audio (once per headset, as your normal user)

```sh
./scripts/audio-setup.sh
```

This saves three WirePlumber settings: **SBC** for music, **mSBC** for calls, and
**auto-switch** to call mode when an app records. The [audio notes](#audio-notes) explain why
each one matters.

### 5. Check everything

```sh
./scripts/doctor.sh
```
```
Transport
  ✔ esp32-airbridge.service running
  ✔ READY hci0 24:0A:C4:12:34:56
Bluetooth
  ✔ hci0 is an Espressif controller
  ✔ AirPods (AA:BB:CC:DD:EE:FF) connected
Audio
  ✔ auto-switch to headset profile on
  ✔ bluez_card.AA_BB_CC_DD_EE_FF: a2dp-sink-sbc
```

Test the microphone (speak after ~2 seconds, then listen back):

```sh
timeout 10 parecord -d "bluez_input.XX:XX:XX:XX:XX:XX" test.wav; pw-play test.wav
```

## Audio notes

| Mode | Profile | Codec | Notes |
|---|---|---|---|
| Music | A2DP | **SBC** | Adapts its bitpool to the link. **AAC stutters** over the 921600-baud UART because PipeWire does not back off its bitrate. |
| Calls / mic | HFP | **mSBC** (16 kHz) | Wideband speech. **CVSD is rejected** by the controller on eSCO links to AirPods (`Invalid LMP Parameters`). |

When an app opens the microphone, the headset switches to HFP and **music quality drops to
call quality** until the app releases it. This is how Bluetooth Classic headsets work with
any adapter, not a limitation of this project.

## How the microphone was fixed

Music worked on the first try; the microphone did not. Getting headset voice audio from an ESP32
controller to Linux needed changes at four layers:

1. **SCO data path → HCI.** By default the ESP32 controller sends voice data to its PCM pins.
   The firmware sets `ESP_SCO_DATA_PATH_HCI` at boot and **again right before every
   synchronous connection**, because Linux resets the controller after attaching it.
2. **Legacy synchronous connection setup.** With *Enhanced Setup Synchronous Connection* the
   eSCO link came up but incoming voice packets were all zeros. The firmware clears the two
   enhanced-sync bits in the *Read Local Supported Commands* reply (octet 29, bits 3–4), so the
   Linux kernel falls back to the classic `Setup Synchronous Connection` command.
3. **Voice setting rewrite.** For mSBC, Linux requests transparent air coding with the voice
   setting `0x0003`. The firmware rewrites it to `0x0043` (linear, 2's complement, 8-bit,
   transparent), the value Espressif's own HFP stack uses, inside
   `Setup`/`Accept Synchronous Connection` commands. Nothing else is touched.
4. **Host audio policy.** WirePlumber must auto-switch to the headset profile and remember
   mSBC, not CVSD. `audio-setup.sh` sets both.

Verified with `btmon`: an eSCO link with transparent air mode, 60-byte packets every 7.5 ms,
each carrying a valid mSBC frame (`01 xx AD …`) with real speech.

More detail on the transport and firmware design is in [docs/how-it-works.md](docs/how-it-works.md).

## Building the firmware

Requires [ESP-IDF **v5.5**](https://docs.espressif.com/projects/esp-idf/en/v5.5.2/esp32/get-started/).

```sh
. $IDF_PATH/export.sh
make firmware          # idf.py build in firmware/
make image             # → esp32-airbridge-full.bin (bootloader + partitions + app, offset 0x0)
./scripts/flash.sh /dev/ttyUSB0 esp32-airbridge-full.bin
```

Or flash straight from the build directory: `./scripts/flash.sh /dev/ttyUSB0`.

Run the unit tests (H4 parser, voice-setting rewrite, host handshake) with `make test`.
CI builds the firmware on every push and attaches the image to tagged releases.

## Troubleshooting

| Symptom | Fix |
|---|---|
| No `ESP32 AirBridge` in `bluetoothctl list` | `journalctl -u esp32-airbridge -n 30`. A handshake failure usually means the firmware isn't flashed or another program (serial monitor, ModemManager) holds the port. |
| Music drops out every few seconds | A device scan is running (Bluetooth settings window open, `bluetoothctl scan on`). Classic inquiry plus LE scanning takes the single radio away from A2DP for ~5 s every ~16 s. Close the window or run `bluetoothctl scan off`; `doctor.sh` flags it under *Radio*. |
| Music stutters | `./scripts/audio-setup.sh` to switch from AAC to SBC. Keep the board in line of sight; use an external antenna and a USB extension away from the PC case. |
| No microphone in apps | Run `./scripts/audio-setup.sh`, then pick the headset as input device. `doctor.sh` must show *auto-switch on*. |
| Mic records silence | Make sure the call profile is `headset-head-unit` (mSBC), not `-cvsd`. Speak a moment after recording starts; the profile switch takes ~1–2 s. |
| `le-connection-abort-by-local` when connecting AirPods | Harmless: BlueZ tried LE first. Check `bluetoothctl info` for `Connected: yes`. If they really don't connect, put them in the case, open the lid and retry. |
| Headset pairs with the wrong adapter | `bluetoothctl select <ESP32 address>` or disable the other adapter. |

## Limitations

- **Linux only.** Windows and macOS have no generic way to attach a UART HCI controller.
- The UART link runs at **921600 baud without hardware flow control**; dev boards wire
  RTS/DTR to reset/boot instead of CTS/RTS. That is plenty for SBC + mSBC but not for
  high-bitrate codecs (AAC, LDAC, aptX HD).
- **Bluetooth 4.2** controller: no LE Audio / LC3.
- One voice (SCO/eSCO) link and two Classic connections at a time.
- Hobby project, not a certified Bluetooth product. Range and stability depend on your board and antenna.

## Project layout

```
firmware/            ESP-IDF project (UART H4 ⇄ VHCI bridge)
  main/main.c          transport, fault handling, SCO data-path + capability fixes
  main/h4_parser.c     bounded, streaming H4 packet parser
  main/hci_compat.h    voice-setting rewrite for synchronous connections
host/airbridge.py    HCI handshake, btattach supervision, adapter naming
scripts/             flash, install, uninstall, audio-setup, doctor
tests/               C and Python unit tests
```

## Uninstall

```sh
sudo ./scripts/uninstall.sh
```

Your pairings stay in BlueZ. To restore the original firmware, flash the backup that
`flash.sh` created.

## License

[MIT](LICENSE)
