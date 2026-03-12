#!/usr/bin/env python3
"""
Keeps a persistent connection to a device via tunneld and reads
lat,lon commands from stdin to update simulated location instantly.

Protocol (stdin → stdout):
  "25.033,121.565\n"  →  "OK 25.033,121.565\n"
  "CLEAR\n"           →  "CLEARED\n"

Lifecycle:
  1. Connects to tunneld, prints "READY\n" on stdout.
  2. Reads lines from stdin and updates location.
  3. On SIGINT/SIGTERM or EOF, clears location and exits.
"""

import sys
import signal
import asyncio
import time


async def main():
    udid = None
    for i, arg in enumerate(sys.argv):
        if arg == "--udid" and i + 1 < len(sys.argv):
            udid = sys.argv[i + 1]
            break

    from pymobiledevice3.tunneld.api import get_tunneld_devices
    from pymobiledevice3.services.dvt.instruments.location_simulation import LocationSimulation
    from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
    from pymobiledevice3.remote.remote_service_discovery import RemoteServiceDiscoveryService

    devices = await get_tunneld_devices()
    rsd = None
    for d in devices:
        if isinstance(d, RemoteServiceDiscoveryService):
            if udid is None or udid in str(d.udid):
                rsd = d
                break

    if rsd is None:
        print("ERROR: No device found via tunneld", file=sys.stderr, flush=True)
        sys.exit(1)

    dvt = DvtProvider(rsd)
    await dvt.connect()
    loc = LocationSimulation(dvt)
    await loc.connect()

    async def cleanup():
        try:
            await loc.clear()
        except Exception:
            pass
        try:
            await dvt.close()
        except Exception:
            pass

    loop = asyncio.get_event_loop()

    def handle_signal():
        loop.create_task(cleanup())
        loop.call_soon(sys.exit, 0)

    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, handle_signal)

    print("READY", flush=True)

    reader = asyncio.StreamReader()
    protocol = asyncio.StreamReaderProtocol(reader)
    await loop.connect_read_pipe(lambda: protocol, sys.stdin)

    try:
        while True:
            line_bytes = await reader.readline()
            if not line_bytes:
                break
            line = line_bytes.decode().strip()
            if not line:
                continue
            if line == "CLEAR":
                try:
                    await loc.clear()
                    print("CLEARED", flush=True)
                except Exception as e:
                    print(f"ERROR: {e}", file=sys.stderr, flush=True)
                continue
            try:
                parts = line.split(",")
                lat = float(parts[0])
                lon = float(parts[1])
                await loc.set(lat, lon)
                print(f"OK {lat},{lon}", flush=True)
            except (ValueError, IndexError) as e:
                print(f"PARSE_ERROR: {e}", file=sys.stderr, flush=True)
            except Exception as e:
                print(f"ERROR: {e}", file=sys.stderr, flush=True)
    except (EOFError, asyncio.CancelledError):
        pass
    finally:
        await cleanup()


if __name__ == "__main__":
    asyncio.run(main())
