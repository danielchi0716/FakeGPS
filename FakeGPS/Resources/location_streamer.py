#!/usr/bin/env python3
"""
FakeGPS Python helper — multi-mode tool for iOS device communication.

Modes:
  streamer  — Persistent location simulation via tunneld (stdin/stdout protocol)
  list      — List connected devices via USB and network (JSON output)
  tunneld   — Start the tunnel daemon (long-running, requires sudo)

Usage:
  location_streamer streamer --udid <UDID>
  location_streamer list
  location_streamer tunneld
"""

import sys
import signal
import asyncio
import inspect
import json


# ── Helpers ────────────────────────────────────────────────────

async def _maybe_await(val):
    """Await if coroutine, otherwise return as-is."""
    if inspect.iscoroutine(val):
        return await val
    return val


async def _get_tunneld_devices():
    """Get tunneld devices, compatible with both sync and async API versions."""
    try:
        from pymobiledevice3.tunneld.api import async_get_tunneld_devices
        return await async_get_tunneld_devices()
    except ImportError:
        from pymobiledevice3.tunneld.api import get_tunneld_devices
        result = get_tunneld_devices()
        return await _maybe_await(result)


async def _get_rsd_device_info(rsd):
    """Extract device info dict from a RemoteServiceDiscoveryService instance."""
    udid = str(rsd.udid)
    info = {
        "UniqueDeviceID": udid,
        "DeviceName": "iPhone",
        "ProductType": "unknown",
        "ProductVersion": "unknown",
        "ConnectionType": "Network",
    }
    try:
        info["DeviceName"] = (await _maybe_await(rsd.get_value(None, "DeviceName"))) or "iPhone"
        info["ProductType"] = (await _maybe_await(rsd.get_value(None, "ProductType"))) or "unknown"
        info["ProductVersion"] = (await _maybe_await(rsd.get_value(None, "ProductVersion"))) or "unknown"
    except Exception as e:
        print(f"Warning (network device {udid}): {e}", file=sys.stderr, flush=True)
    return info


# ── Mode: streamer ──────────────────────────────────────────────

async def mode_streamer(udid):
    from pymobiledevice3.services.dvt.instruments.location_simulation import LocationSimulation
    from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
    from pymobiledevice3.remote.remote_service_discovery import RemoteServiceDiscoveryService

    devices = await _get_tunneld_devices()
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
    """List connected devices via USB and network (JSON output)."""
    from pymobiledevice3.usbmux import list_devices
    from pymobiledevice3.lockdown import create_using_usbmux

    async def _list():
        seen_udids = set()
        result = []

        # 1. USB devices
        devs = await _maybe_await(list_devices())
        for d in devs:
            serial = getattr(d, "serial", "unknown")
            info = {
                "UniqueDeviceID": serial,
                "DeviceName": "iPhone",
                "ProductType": "unknown",
                "ProductVersion": "unknown",
                "ConnectionType": "USB",
            }
            try:
                lockdown = await _maybe_await(create_using_usbmux(serial=serial))
                vals = lockdown.all_values
                if inspect.iscoroutine(vals):
                    vals = await vals
                if isinstance(vals, dict):
                    info["DeviceName"] = vals.get("DeviceName", "iPhone")
                    info["ProductType"] = vals.get("ProductType", "unknown")
                    info["ProductVersion"] = vals.get("ProductVersion", "unknown")
                    info["UniqueDeviceID"] = vals.get("UniqueDeviceID", serial)
            except Exception as e:
                print(f"Warning: {e}", file=sys.stderr, flush=True)
            seen_udids.add(info["UniqueDeviceID"])
            result.append(info)

        # 2. Network devices via tunneld (requires tunneld to be running)
        try:
            from pymobiledevice3.remote.remote_service_discovery import RemoteServiceDiscoveryService
            tunnel_devs = await _get_tunneld_devices()
            for d in tunnel_devs:
                if not isinstance(d, RemoteServiceDiscoveryService):
                    continue
                udid = str(d.udid)
                if udid in seen_udids:
                    continue
                info = await _get_rsd_device_info(d)
                seen_udids.add(udid)
                result.append(info)
        except Exception as e:
            print(f"Warning: tunneld query failed: {e}", file=sys.stderr, flush=True)

        # 3. Bonjour browse fallback (discovers network devices without tunneld)
        if not any(d["ConnectionType"] == "Network" for d in result):
            try:
                from pymobiledevice3.remote.remote_service_discovery import browse_remoted
                browse_devs = await _maybe_await(browse_remoted(timeout=3))
                for d in browse_devs:
                    udid = str(getattr(d, "udid", "unknown"))
                    if udid in seen_udids:
                        continue
                    info = await _get_rsd_device_info(d)
                    seen_udids.add(udid)
                    result.append(info)
            except Exception as e:
                print(f"Warning: bonjour browse failed: {e}", file=sys.stderr, flush=True)

        return result

    print(json.dumps(asyncio.run(_list())), flush=True)


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
