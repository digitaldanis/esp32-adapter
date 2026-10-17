# How it works

## The transport

Linux talks to Bluetooth controllers through **HCI**, the Host Controller Interface. Over a
serial line, HCI packets are framed with the **H4** protocol: one type byte followed by the
packet itself.

| Type | Direction | Packet | Length field |
|---|---|---|---|
| `0x01` | host → controller | Command | 1 byte, offset 3 |
| `0x02` | both | ACL data (L2CAP: A2DP, RFCOMM, …) | 2 bytes, offset 3 |
| `0x03` | both | SCO/eSCO data (voice) | 1 byte, offset 3 |
| `0x04` | controller → host | Event | 1 byte, offset 2 |

The ESP32's Bluetooth controller does not expose a UART HCI by itself in this configuration;
it offers **VHCI**, a function-call interface (`esp_vhci_host_send_packet` /
`notify_host_recv`). The firmware connects the two:

```
          UART0 RX ──► h4-rx task ──► H4 parser ──► esp_vhci_host_send_packet ──► controller
                         (core 1)        (bounded)
controller ──► notify_host_recv ──► ring buffer (32 KB) ──► h4-tx task ──► UART0 TX
                (no blocking)         (no split items)        (core 1)
```

- **Parser** (`h4_parser.c`): streaming, works with arbitrary fragmentation, never scans
  payloads for type bytes, rejects packets larger than 2048 bytes. Unit-tested on the host.
- **Controller → host**: the VHCI callback runs in the controller's context and must never
  block, so packets are copied into a no-split ring buffer and written to the UART by a
  separate task.
- **Fail loud**: UART FIFO overflow, framing/parity errors, an oversized packet, a full ring
  buffer, or a packet left incomplete for 500 ms all set a fault flag. The firmware then sends
  an HCI *Hardware Error* event (`04 10 01 01`) and restarts. Linux sees the error and the
  service reattaches the adapter, so a corrupted stream never runs on silently.
- **No noise on the wire**: console, bootloader and application logging are all disabled,
  so the UART carries nothing but H4.
- 240 MHz, no Wi-Fi, no Bluetooth modem sleep, and both transport tasks pinned to core 1.

## Host side

`host/airbridge.py` (standard library only) runs as a hardened systemd service:

1. Opens the port at 921600 8N1, raw mode, **no** hardware flow control, and **deasserts DTR
   and RTS**. On ESP32 dev boards those lines drive the EN/BOOT transistors, not CTS/RTS.
2. Sends `HCI_Reset`, `Read_Local_Version` and `Read_BD_ADDR`, and checks the manufacturer is
   Espressif's controller IP (`0x0060`) or Espressif (`0x02E5`). That way it never attaches a
   random serial device as a Bluetooth controller.
3. Starts `btattach -P h4 -S 921600`, waits for the new `hciN` to finish kernel
   initialization, sets its name and powers it on with `btmgmt`, then supervises `btattach`.

The service runs as an unprivileged user with only `CAP_NET_ADMIN` + `CAP_NET_RAW`, a
read-only filesystem view and restricted socket families. udev starts it when the board is
plugged in, and systemd stops it when the board goes away (`BindsTo=` the device unit).

## Voice audio (HFP/SCO)

A2DP music is ordinary ACL data and worked without changes. Headset voice uses **eSCO**
synchronous links, which needed three firmware fixes and one host-policy fix:

### 1. SCO data path

The ESP32 controller can route voice either to its I2S/PCM pins or over HCI. The firmware
selects HCI with `esp_bredr_sco_datapath_set(ESP_SCO_DATA_PATH_HCI)` at boot. Linux resets
the controller when attaching it, so the firmware **asserts it again** whenever the host sends
`Setup`/`Accept` (Enhanced) `Synchronous Connection`, the same thing Espressif's own HFP
host stack does. The call runs in the UART task, not inside the controller callback.

### 2. Legacy setup instead of Enhanced Setup

The kernel uses *Enhanced Setup Synchronous Connection* (`0x043D`) if the controller
advertises it. On this controller that produced a working eSCO link whose incoming packets
were entirely zero. The firmware clears octet 29 bits 3–4 (Enhanced Setup/Accept
Synchronous Connection) in the *Read Local Supported Commands* response, so the kernel uses
the legacy `0x0428`/`0x0429` commands. No responses are synthesized and no completions are
faked; only that capability bitmap is edited.

### 3. Voice setting

For mSBC, Linux requests transparent air coding with voice setting `0x0003` (1's-complement
input). `hci_compat.h` rewrites the voice-setting field of legacy `Setup`/`Accept
Synchronous Connection` commands to `0x0043` (2's complement), the value Espressif's HFP
implementation uses with transparent mode. Only commands with an exact length match and
transparent air coding are touched; everything else passes through byte for byte.
`tests/test_voice.c` covers the edge cases.

### 4. Host audio policy

- WirePlumber's `bluetooth.autoswitch-to-headset-profile` must be **on**. Otherwise the
  headset exposes no microphone while it is in music (A2DP) mode.
- The remembered headset profile must be `headset-head-unit` (**mSBC**). The controller
  rejects CVSD eSCO links to AirPods with *Invalid LMP Parameters* (`0x1E`).
- For music, **SBC** is preferred over AAC. The UART carries ~92 KB/s with no flow
  control, and SBC's bitpool adapts to the link while PipeWire's AAC encoder does not.

`scripts/audio-setup.sh` applies all three settings; `scripts/doctor.sh` checks them.

## Debugging tips

```sh
sudo btmon -i hci0                      # live HCI trace
sudo btmon -S -i hci0                   # include SCO payloads
journalctl -u esp32-airbridge -f        # transport service
pactl list cards | grep -A20 bluez      # profiles and active codec
```

A healthy mSBC call shows `Synchronous Connect Complete` with `Status: Success`,
`Link type: eSCO`, `Air mode: Transparent`, then 60-byte packets every 7.5 ms whose payload
starts with an H2 header `01 08|38|c8|f8` followed by the mSBC sync byte `AD`.
