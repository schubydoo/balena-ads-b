#!/usr/bin/env python3
"""
Tiny dump1090-fa → Prometheus exporter, stdlib only.

Started as a sidecar by start.sh when OTEL_DUMP1090_ENABLED=true. The otelcol
prometheus receiver scrapes 127.0.0.1:${DUMP1090_EXPORTER_PORT}/metrics.

The metric naming scheme follows clawsicus/dump1090exporter
(https://github.com/clawsicus/dump1090exporter, MIT) so dashboards built
against that exporter remain usable. We do NOT depend on that package because
its pinned aiohttp==3.8.1 transitive dep no longer builds on Python >= 3.12.

Stats.json schema reference: FlightAware dump1090-fa README,
https://github.com/flightaware/dump1090.
"""

from __future__ import annotations

import argparse
import json
import logging
import math
import os
import signal
import sys
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Iterable

log = logging.getLogger("dump1090_exporter")

DEFAULT_RESOURCE_PATH = "http://dump1090-fa:8080/data"
DEFAULT_PORT = 9105
DEFAULT_FETCH_TIMEOUT = 5.0


def fetch_json(url: str, timeout: float) -> dict[str, Any] | None:
    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except (urllib.error.URLError, TimeoutError, ValueError, OSError) as exc:
        log.warning("fetch %s failed: %s", url, exc)
        return None


def _emit(buf: list[str], name: str, value: float, help_text: str, mtype: str = "gauge", labels: dict[str, str] | None = None) -> None:
    if value is None or (isinstance(value, float) and math.isnan(value)):
        return
    if not any(line.startswith(f"# HELP {name} ") for line in buf):
        buf.append(f"# HELP {name} {help_text}")
        buf.append(f"# TYPE {name} {mtype}")
    if labels:
        rendered = ",".join(f'{k}="{v}"' for k, v in sorted(labels.items()))
        buf.append(f"{name}{{{rendered}}} {value}")
    else:
        buf.append(f"{name} {value}")


def _interval_blocks(stats: dict[str, Any]) -> Iterable[tuple[str, dict[str, Any]]]:
    for key in ("last1min", "last5min", "last15min", "total"):
        block = stats.get(key)
        if isinstance(block, dict):
            yield key, block


def render_metrics(stats: dict[str, Any] | None, aircraft: dict[str, Any] | None, *, lat: float | None, lon: float | None) -> str:
    buf: list[str] = []

    if isinstance(aircraft, dict):
        ac_list = aircraft.get("aircraft") or []
        with_pos = sum(1 for a in ac_list if isinstance(a, dict) and "lat" in a and "lon" in a)
        _emit(buf, "dump1090_aircraft_recent_count", len(ac_list), "Aircraft seen in the most recent update.")
        _emit(buf, "dump1090_aircraft_recent_with_position", with_pos, "Aircraft with a known position in the most recent update.")
        if lat is not None and lon is not None:
            max_range = 0.0
            for a in ac_list:
                if isinstance(a, dict) and "lat" in a and "lon" in a:
                    d = _haversine_meters(lat, lon, a["lat"], a["lon"])
                    if d > max_range:
                        max_range = d
            _emit(buf, "dump1090_aircraft_recent_max_range_meters", max_range, "Furthest aircraft from the configured receiver position, in meters.")
        msgs = aircraft.get("messages")
        if isinstance(msgs, (int, float)):
            _emit(buf, "dump1090_messages_total", msgs, "Total Mode S messages processed since dump1090 started.", mtype="counter")

    if isinstance(stats, dict):
        for interval, block in _interval_blocks(stats):
            labels = {"interval": interval}
            local = block.get("local") or {}
            remote = block.get("remote") or {}
            tracks = block.get("tracks") or {}
            cpu = block.get("cpu") or {}

            for field, help_text in (
                ("samples_processed", "Samples processed by the demodulator."),
                ("samples_dropped", "Samples dropped due to USB or CPU overruns."),
                ("modeac", "Mode A/C messages decoded."),
                ("modes", "Mode S messages decoded."),
                ("bad", "Mode S messages that failed CRC."),
                ("unknown_icao", "Mode S messages with an unknown ICAO address."),
                ("accepted", "Accepted Mode S messages."),
                ("strong_signals", "Mode S messages received above -3 dBFS."),
            ):
                v = local.get(field)
                if isinstance(v, (int, float)):
                    _emit(buf, f"dump1090_recent_local_{field}_total", v, help_text, mtype="counter", labels=labels)

            for field, help_text in (
                ("signal", "Mean signal power of accepted messages (dBFS)."),
                ("noise", "Mean background noise level (dBFS)."),
                ("peak_signal", "Peak signal power of accepted messages (dBFS)."),
            ):
                v = local.get(field)
                if isinstance(v, (int, float)):
                    _emit(buf, f"dump1090_recent_local_{field}_dbfs", v, help_text, labels=labels)

            for field, help_text in (
                ("modeac", "Mode A/C messages received from remote sources."),
                ("modes", "Mode S messages received from remote sources."),
                ("bad", "Bad Mode S messages received from remote sources."),
                ("unknown_icao", "Remote Mode S messages with unknown ICAO."),
                ("accepted", "Accepted remote Mode S messages."),
            ):
                v = remote.get(field)
                if isinstance(v, (int, float)):
                    _emit(buf, f"dump1090_recent_remote_{field}_total", v, help_text, mtype="counter", labels=labels)

            for field, help_text in (
                ("new", "New aircraft tracks started."),
                ("single_message", "Single-message tracks that never produced a follow-up."),
            ):
                v = tracks.get(field)
                if isinstance(v, (int, float)):
                    _emit(buf, f"dump1090_recent_tracks_{field}_total", v, help_text, mtype="counter", labels=labels)

            msgs = block.get("messages")
            if isinstance(msgs, (int, float)):
                _emit(buf, "dump1090_recent_messages_total", msgs, "Mode S messages processed during the period.", mtype="counter", labels=labels)

            for field in ("demod", "reader", "background"):
                v = cpu.get(field)
                if isinstance(v, (int, float)):
                    _emit(buf, "dump1090_recent_cpu_milliseconds", v, "CPU time consumed by dump1090, in milliseconds.", labels={"interval": interval, "type": field})

    buf.append("")
    return "\n".join(buf)


def _haversine_meters(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    r = 6371008.8  # mean Earth radius, meters
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlam = math.radians(lon2 - lon1)
    a = math.sin(dphi / 2) ** 2 + math.cos(phi1) * math.cos(phi2) * math.sin(dlam / 2) ** 2
    return 2 * r * math.asin(math.sqrt(a))


class _Handler(BaseHTTPRequestHandler):
    server_version = "dump1090_exporter/0.1"

    def do_GET(self) -> None:  # noqa: N802 — required name
        if self.path not in ("/", "/metrics"):
            self.send_response(404)
            self.end_headers()
            return
        cfg = self.server.exporter_cfg  # type: ignore[attr-defined]
        stats = fetch_json(f"{cfg['resource_path']}/stats.json", cfg["timeout"])
        aircraft = fetch_json(f"{cfg['resource_path']}/aircraft.json", cfg["timeout"])
        body = render_metrics(stats, aircraft, lat=cfg["lat"], lon=cfg["lon"]).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt: str, *args: Any) -> None:  # noqa: A003 — stdlib name
        log.debug("%s - " + fmt, self.client_address[0], *args)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="dump1090-fa Prometheus exporter (stdlib only).")
    parser.add_argument("--resource-path", default=os.environ.get("DUMP1090_RESOURCE_PATH", DEFAULT_RESOURCE_PATH))
    parser.add_argument("--port", type=int, default=int(os.environ.get("DUMP1090_EXPORTER_PORT", DEFAULT_PORT)))
    parser.add_argument("--bind", default=os.environ.get("DUMP1090_EXPORTER_BIND", "127.0.0.1"))
    parser.add_argument("--latitude", type=float, default=_optional_float(os.environ.get("LAT")))
    parser.add_argument("--longitude", type=float, default=_optional_float(os.environ.get("LON")))
    parser.add_argument("--timeout", type=float, default=float(os.environ.get("DUMP1090_FETCH_TIMEOUT", DEFAULT_FETCH_TIMEOUT)))
    parser.add_argument("--log-level", default=os.environ.get("DUMP1090_EXPORTER_LOG_LEVEL", "warning"))
    args = parser.parse_args(argv)

    logging.basicConfig(level=args.log_level.upper(), format="%(asctime)s %(levelname)s dump1090_exporter %(message)s")

    server = ThreadingHTTPServer((args.bind, args.port), _Handler)
    server.exporter_cfg = {  # type: ignore[attr-defined]
        "resource_path": args.resource_path.rstrip("/"),
        "lat": args.latitude,
        "lon": args.longitude,
        "timeout": args.timeout,
    }
    log.info("Listening on http://%s:%s/metrics, scraping %s", args.bind, args.port, args.resource_path)

    def _shutdown(_signum: int, _frame: Any) -> None:
        log.info("Shutting down")
        server.shutdown()

    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)
    try:
        server.serve_forever()
    finally:
        server.server_close()
    return 0


def _optional_float(value: str | None) -> float | None:
    if value in (None, ""):
        return None
    try:
        return float(value)
    except ValueError:
        return None


if __name__ == "__main__":
    sys.exit(main())
