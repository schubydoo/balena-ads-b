# Bundled Grafana dashboards

Drop-in dashboards for the `otel-collector` service. Import in Grafana via **Dashboards → New → Import → Upload JSON file**, then pick your Prometheus data source when prompted.

| File | Title | What it shows |
| --- | --- | --- |
| [`containers.json`](containers.json) | **Containers** | Per-container CPU, memory, block I/O, network rx/tx. Filter by `container_name`. |
| [`app-services.json`](app-services.json) | **App Services** | Same metrics aggregated by `container_service_name` (so all replicas of `piaware` / `tar1090` / etc. roll up together). |

Both dashboards have an `Instance` dropdown driven by the `container_device_short_uuid` label, which `otel-collector/start.sh` derives from `BALENA_DEVICE_UUID` via its `resource/docker` processor.

## Known empty panels

- **Disk I/O** — stays empty on balena-engine. Both dashboards query `container_blockio_io_service_bytes_recursive`, but balena-engine on cgroup v2 doesn't expose block I/O counters through the Docker stats API, so the OTel `docker_stats` receiver has nothing to emit. Nothing fixable on the collector side; ignore the panel.

## Attribution

These JSON files originate from [`balena-io-experimental/otel-collector-device-prom`](https://github.com/balena-io-experimental/otel-collector-device-prom) (Apache-2.0). Original authors © balena. The only local modification is appending the `_total` suffix to `container_network_io_usage_{rx,tx}_bytes` queries — Grafana Cloud's OTLP→Prometheus translation adds that suffix to monotonic counters on ingest, so the un-suffixed names from the upstream JSON return no data.

The metric names and labels the dashboards filter on (`container_cpu_utilization_ratio`, `container_memory_usage_total_bytes`, `container_network_io_usage_{rx,tx}_bytes_total`, `container_blockio_io_service_bytes_recursive`, `container_service_name`, `container_name`, `container_device_short_uuid`) are exactly what `otel-collector` is configured to emit — see `otel-collector/start.sh` for the receiver wiring.

## Other useful dashboards (external)

Not bundled here, but worth importing by ID from the Grafana wizard's *Import* page:

- **Grafana Cloud → Connections → Linux Server → Install Dashboards and Alerts** — installs the Linux Node Exporter dashboards (host CPU, memory, network, processes). These query `node_*` series scraped from the sibling `node-exporter` service and filter on `job="integrations/node_exporter"` and `instance` (set by `start.sh` to your balena device name).
