#!/usr/bin/python3
"""ESP32 UART-H4 bring-up. Standard-library only; never flashes or changes audio policy."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import select
import signal
import struct
import subprocess
import sys
import termios
import time
import tty

DEFAULT_PORT = os.environ.get('AIRBRIDGE_PORT',
    '/dev/serial/by-id/usb-Silicon_Labs_CP2102_USB_to_UART_Bridge_Controller_0001-if00-port0')
DEFAULT_NAME = os.environ.get('AIRBRIDGE_NAME', 'ESP32 AirBridge')

class H4Events:
    def __init__(self):
        self.buf = bytearray()
    def feed(self, data):
        self.buf.extend(data)
        packets = []
        while self.buf:
            kind = self.buf[0]
            header = {2:5, 3:4, 4:3}.get(kind)
            if header is None:
                del self.buf[0]
                continue
            if len(self.buf) < header:
                break
            payload = self.buf[2] if kind == 4 else self.buf[3]
            if kind == 2:
                payload |= self.buf[4] << 8
            if payload > 2043:
                raise RuntimeError('Invalid controller packet length')
            size = header + payload
            if len(self.buf) < size:
                break
            packets.append(bytes(self.buf[:size]))
            del self.buf[:size]
        return packets

def open_uart(port):
    fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    try:
        tty.setraw(fd)
        attrs = termios.tcgetattr(fd)
        attrs[2] &= ~(termios.CRTSCTS | termios.HUPCL | termios.CSTOPB | termios.PARENB)
        attrs[2] |= termios.CLOCAL | termios.CREAD | termios.CS8
        attrs[4] = attrs[5] = termios.B921600
        termios.tcsetattr(fd, termios.TCSANOW, attrs)
        # The board wires DTR/RTS to boot/reset transistors, not to HCI flow control.
        fcntl.ioctl(fd, termios.TIOCMBIC, struct.pack('I', termios.TIOCM_DTR | termios.TIOCM_RTS))
        return fd
    except BaseException:
        os.close(fd)
        raise

def command(fd, decoder, opcode, timeout=2.5):
    packet = bytes((1, opcode & 255, opcode >> 8, 0))
    sent = 0
    deadline = time.monotonic() + timeout
    while sent < len(packet):
        _, writable, _ = select.select([], [fd], [], max(0, deadline-time.monotonic()))
        if not writable:
            raise TimeoutError('UART write timed out')
        sent += os.write(fd, packet[sent:])
    while time.monotonic() < deadline:
        readable, _, _ = select.select([fd], [], [], max(0, deadline-time.monotonic()))
        if not readable:
            break
        data = os.read(fd, 4096)
        if not data:
            raise OSError('USB serial device disconnected')
        for event in decoder.feed(data):
            if event[:2] == b'\x04\x10':
                raise RuntimeError('Controller reported a transport hardware error')
            if len(event) >= 7 and event[:2] == b'\x04\x0e' and event[4:6] == struct.pack('<H', opcode):
                if event[6]:
                    raise RuntimeError(f'HCI command {opcode:04x}: status {event[6]:02x}')
                return event
    raise TimeoutError(f'No HCI response to {opcode:04x}')

def probe(port, attempts=5):
    last = None
    for attempt in range(attempts):
        fd = None
        try:
            fd = open_uart(port)
            time.sleep(1.0)
            termios.tcflush(fd, termios.TCIFLUSH)
            decoder = H4Events()
            command(fd, decoder, 0x0c03)
            version = command(fd, decoder, 0x1001)
            if len(version) != 15:
                raise RuntimeError('Unexpected Read Local Version reply')
            manufacturer = struct.unpack_from('<H', version, 11)[0]
            # The classic ESP32 controller reports its RivieraWaves IP vendor (0x0060).
            if manufacturer not in (0x0060, 0x02e5):
                raise RuntimeError(f'Not an Espressif controller (manufacturer {manufacturer:#06x})')
            address = command(fd, decoder, 0x1009)
            if len(address) != 13:
                raise RuntimeError('Unexpected Read BD_ADDR reply')
            mac = ':'.join(f'{b:02X}' for b in address[7:13][::-1])
            return {'port':port, 'baud':921600, 'manufacturer':manufacturer,
                    'hci_version':version[7], 'address':mac}
        except (OSError, RuntimeError, TimeoutError) as error:
            last = error
            if attempt + 1 < attempts:
                time.sleep(0.75)
        finally:
            if fd is not None:
                os.close(fd)
    raise RuntimeError(f'ESP32 HCI handshake failed: {last}')

def run(port, name=DEFAULT_NAME):
    before = set(Path('/sys/class/bluetooth').glob('hci*'))
    info = probe(port)
    print(json.dumps(info), flush=True)
    child = subprocess.Popen(['/usr/bin/btattach', '-B', port, '-S', '921600', '-P', 'h4', '-N'])
    def stop(signum, frame):
        child.terminate()
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        deadline = time.monotonic() + 12
        adapter = None
        while time.monotonic() < deadline:
            if child.poll() is not None:
                raise RuntimeError(f'btattach exited with {child.returncode}')
            added = set(Path('/sys/class/bluetooth').glob('hci*')) - before
            if len(added) == 1:
                adapter = next(iter(added)).name
                break
            time.sleep(0.2)
        if adapter is None:
            raise RuntimeError('Linux did not register an HCI controller')
        # Wait until the kernel finishes asynchronous HCI initialization.
        deadline = time.monotonic() + 10
        while True:
            ready = subprocess.run(['/usr/bin/btmgmt', '--index', adapter, 'info'],
                capture_output=True, text=True, timeout=3)
            if ready.returncode == 0:
                break
            if time.monotonic() >= deadline or child.poll() is not None:
                raise RuntimeError('HCI initialization did not complete: ' + ready.stderr.strip())
            time.sleep(0.25)
        # BlueZ/kernel own the audio profiles and pairing; configure only our new index.
        subprocess.run(['/usr/bin/btmgmt', '--index', adapter, 'name', name], check=True, timeout=8)
        subprocess.run(['/usr/bin/btmgmt', '--index', adapter, 'power', 'on'], check=True, timeout=8)
        print(f'READY {adapter} {info["address"]}', flush=True)
        return child.wait()
    finally:
        if child.poll() is None:
            child.terminate()
        try:
            child.wait(timeout=3)
        except subprocess.TimeoutExpired:
            child.kill();child.wait()

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['probe','run'])
    parser.add_argument('--port', default=DEFAULT_PORT)
    parser.add_argument('--name', default=DEFAULT_NAME, help='Bluetooth name shown to other devices')
    args=parser.parse_args()
    if args.action=='probe':
        print(json.dumps(probe(args.port),indent=2));return 0
    return run(args.port, args.name)

if __name__=='__main__':
    try:
        sys.exit(main())
    except (OSError, RuntimeError, TimeoutError, subprocess.SubprocessError) as error:
        print(f'AirBridge: {error}',file=sys.stderr);sys.exit(1)
