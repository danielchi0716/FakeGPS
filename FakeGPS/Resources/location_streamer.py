#!/usr/bin/env python3
"""
FakeGPS Python helper — multi-mode tool for iOS device communication.

Modes:
  streamer  — Persistent location simulation via tunneld (stdin/stdout protocol)
  list      — List connected USB devices (JSON output)
  tunneld   — Start the tunnel daemon (long-running, requires sudo)

Usage:
  location_streamer streamer --udid <UDID>
  location_streamer list
  location_streamer tunneld
"""

import sys
import signal
import asyncio
import json


# ── Mode: streamer ──────────────────────────────────────────────

async def mode_streamer(udid):
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


# ── Mode: list ──────────────────────────────────────────────────

def mode_list():
    import asyncio
    from pymobiledevice3.usbmux import list_devices
    import inspect

    devices = list_devices()
    # list_devices may be async in newer versions
    if inspect.iscoroutine(devices):
        devices = asyncio.run(devices)

    result = []
    for d in devices:
        result.append({
            "UniqueDeviceID": getattr(d, "serial", "unknown"),
            "DeviceName": getattr(d, "name", "iPhone"),
            "ProductType": getattr(d, "product_type", "unknown"),
            "ProductVersion": getattr(d, "os_version", "unknown"),
        })
    print(json.dumps(result), flush=True)


# ── Mode: tunneld ───────────────────────────────────────────────

def mode_tunneld():
    from pymobiledevice3.__main__ import main as pymobiledevice3_main
    sys.argv = ["pymobiledevice3", "remote", "tunneld"]
    pymobiledevice3_main()


# ── Entry point ─────────────────────────────────────────────────

def main():
    if len(sys.argv) < 2:
        print("Usage: location_streamer <streamer|list|tunneld> [options]", file=sys.stderr)
        sys.exit(1)

    mode = sys.argv[1]

    if mode == "streamer":
        udid = None
        for i, arg in enumerate(sys.argv):
            if arg == "--udid" and i + 1 < len(sys.argv):
                udid = sys.argv[i + 1]
                break
        asyncio.run(mode_streamer(udid))

    elif mode == "list":
        mode_list()

    elif mode == "tunneld":
        mode_tunneld()

    else:
        print(f"Unknown mode: {mode}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
