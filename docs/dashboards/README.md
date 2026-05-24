# Bundled Grafana dashboards

Drop-in dashboards for the `otel-collector` service. Import in Grafana via **Dashboards → New → Import → Upload JSON file**, then pick your Prometheus data source when prompted.

| File | Title | What it shows |
| --- | --- | --- |
| [`containers.json`](containers.json) | **Containers** | Per-container CPU, memory, block I/O, network rx/tx. Filter by `container_name`. |
| [`app-services.json`](app-services.json) | **App Services** | Same metrics aggregated by `container_service_name` (so all replicas of `piaware` / `tar1090` / etc. roll up together). |

Both dashboards have an `Instance` dropdown driven by the `container_device_short_uuid` label, which `otel-collector/start.sh` derives from `BALENA_DEVICE_UUID` via its `resource/docker` processor.

## Attribution

These JSON files are vendored unchanged from [`balena-io-experimental/otel-collector-device-prom`](https://github.com/balena-io-experimental/otel-collector-device-prom) (Apache-2.0). Original authors © balena.

The metric names and labels the dashboards filter on (`container_cpu_utilization_ratio`, `container_memory_usage_total_bytes`, `container_network_io_usage_{rx,tx}_bytes`, `container_blockio_io_service_bytes_recursive`, `container_service_name`, `container_name`, `container_device_short_uuid`) are exactly what `otel-collector` is configured to emit — see `otel-collector/start.sh` for the receiver wiring.

## Other useful dashboards (external)

Not bundled here, but worth importing by ID from the Grafana wizard's *Import* page:

- **Grafana Cloud → Connections → Linux Server → Install Dashboards and Alerts** — installs the Linux Node Exporter dashboards (host CPU, memory, network, processes). These query `node_*` series scraped from the sibling `node-exporter` service and filter on `job="integrations/node_exporter"` and `instance` (set by `start.sh` to your balena device name).
