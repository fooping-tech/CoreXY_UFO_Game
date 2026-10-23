"""Threaded pyserial transport: background reader thread -> asyncio queue of lines."""

from __future__ import annotations

import asyncio
import logging
import threading
import time
from collections.abc import Callable

try:
    import serial
    from serial.tools import list_ports
except ImportError:  # pragma: no cover
    serial = None  # type: ignore[assignment]
    list_ports = None  # type: ignore[assignment]

log = logging.getLogger(__name__)

_PORT_HINTS = ("usbserial", "usbmodem", "SLAB", "wchusb", "cu.usb", "ttyUSB", "ttyACM")


def list_serial_ports() -> list[dict[str, str]]:
    if list_ports is None:
        return []
    out = []
    for p in list_ports.comports():
        out.append({"device": p.device, "description": p.description or "", "hwid": p.hwid or ""})
    return out


def guess_port() -> str | None:
    """Best guess for the Core2's USB serial port (CP210x / CH9102 on macOS)."""
    ports = list_serial_ports()
    for p in ports:
        dev = p["device"]
        if dev.startswith("/dev/cu.") and any(h in dev for h in _PORT_HINTS):
            if "Bluetooth" not in dev:
                return dev
    for p in ports:
        if "Bluetooth" not in p["device"] and p["device"].startswith("/dev/cu."):
            return p["device"]
    return ports[0]["device"] if ports else None


class SerialTransport:
    """Owns the pyserial handle. Lines arrive on `lines` (asyncio.Queue)."""

    def __init__(self, port: str, baudrate: int = 115200, *, startup_delay: float = 0.3,
                 on_disconnect: Callable[[Exception | None], None] | None = None) -> None:
        self.port = port
        self.baudrate = baudrate
        self.startup_delay = startup_delay
        self.on_disconnect = on_disconnect
        self.lines: asyncio.Queue[str] = asyncio.Queue()
        self._ser = None
        self._thread: threading.Thread | None = None
        self._stop = threading.Event()
        self._loop: asyncio.AbstractEventLoop | None = None
        self._write_lock = threading.Lock()
        self.last_rx_time = 0.0
        self.tx_log: Callable[[str], None] | None = None
        self.rx_log: Callable[[str], None] | None = None

    @property
    def is_open(self) -> bool:
        return self._ser is not None and bool(getattr(self._ser, "is_open", False))

    async def open(self) -> None:
        if serial is None:
            raise RuntimeError("pyserial is not installed")
        self._loop = asyncio.get_running_loop()
        # Do not toggle DTR/RTS: the Core2 may reset if they change.
        self._ser = serial.Serial(self.port, self.baudrate, timeout=0.05, write_timeout=1.0)
        self._ser.reset_input_buffer()
        await asyncio.sleep(self.startup_delay)
        self._stop.clear()
        self._thread = threading.Thread(target=self._reader, name="serial-reader", daemon=True)
        self._thread.start()
        log.info("serial open %s @ %d", self.port, self.baudrate)

    async def close(self) -> None:
        self._stop.set()
        if self._ser is not None:
            try:
                self._ser.close()
            except Exception:  # pragma: no cover
                pass
        if self._thread is not None and self._thread.is_alive() and threading.current_thread() is not self._thread:
            self._thread.join(timeout=1.0)
        self._ser = None
        log.info("serial closed")

    def write_line(self, line: str) -> None:
        if not self.is_open:
            raise ConnectionError("serial port not open")
        data = (line + "\n").encode("utf-8")
        with self._write_lock:
            self._ser.write(data)  # type: ignore[union-attr]
            self._ser.flush()  # type: ignore[union-attr]
        if self.tx_log:
            self.tx_log(line)

    def _reader(self) -> None:
        buf = bytearray()
        err: Exception | None = None
        while not self._stop.is_set():
            try:
                chunk = self._ser.read(256)  # type: ignore[union-attr]
            except Exception as e:  # port vanished (USB unplugged)
                err = e
                break
            if not chunk:
                continue
            self.last_rx_time = time.monotonic()
            buf.extend(chunk)
            while True:
                idx = -1
                for i, b in enumerate(buf):
                    if b in (10, 13):
                        idx = i
                        break
                if idx < 0:
                    break
                raw = bytes(buf[:idx])
                del buf[: idx + 1]
                if not raw:
                    continue
                line = raw.decode("utf-8", errors="replace").strip()
                if line and self._loop is not None:
                    if self.rx_log:
                        self.rx_log(line)
                    self._loop.call_soon_threadsafe(self.lines.put_nowait, line)
        if not self._stop.is_set():
            log.warning("serial reader stopped: %s", err)
            if self.on_disconnect and self._loop is not None:
                self._loop.call_soon_threadsafe(self.on_disconnect, err)
