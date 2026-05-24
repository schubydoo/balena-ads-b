#!/usr/bin/env bash
set -e

# Check if service has been opted in through the ENABLED_SERVICES environment variable.

if [[ ",$(echo -e "${ENABLED_SERVICES}" | tr -d '[:space:]')," != *",$BALENA_SERVICE_NAME,"* ]]; then
	echo "$BALENA_SERVICE_NAME is not enabled. Sending request to stop the service:"
	curl --fail --retry 86400 --retry-delay 1 --retry-all-errors --header "Content-Type:application/json" "$BALENA_SUPERVISOR_ADDRESS/v2/applications/$BALENA_APP_ID/stop-service?apikey=$BALENA_SUPERVISOR_API_KEY" -d '{"serviceName": "'$BALENA_SERVICE_NAME'"}'
	echo " "
	sleep infinity
fi

echo "Verifying settings..."
echo " "
sleep 2

missing_variables=false

[ -z "$OTLP_ENDPOINT" ] && echo "OTLP_ENDPOINT is missing, will abort startup." && missing_variables=true || echo "OTLP_ENDPOINT is set: $OTLP_ENDPOINT"

if [ "$missing_variables" = true ]; then
	echo "Settings missing, aborting..."
	echo " "
	sleep infinity
fi

echo "Settings verified, proceeding with startup."
echo " "

# Resolve per-signal toggles. Default: hostmetrics + docker_stats on (cheap,
# always useful), logs + ADS-B app metrics off (higher volume / extra deps).
OTEL_HOSTMETRICS_ENABLED="${OTEL_HOSTMETRICS_ENABLED:-true}"
OTEL_DOCKER_STATS_ENABLED="${OTEL_DOCKER_STATS_ENABLED:-true}"
OTEL_LOGS_ENABLED="${OTEL_LOGS_ENABLED:-false}"
OTEL_DUMP1090_ENABLED="${OTEL_DUMP1090_ENABLED:-false}"

OTEL_COLLECTION_INTERVAL="${OTEL_COLLECTION_INTERVAL:-30s}"
OTEL_DOCKER_ENDPOINT="${OTEL_DOCKER_ENDPOINT:-unix:///var/run/balena.sock}"
# Scrape target for ADS-B app metrics. Defaults to the sibling
# dump1090-exporter service on the compose bridge network; users can override
# (e.g. point at a different host) without rebuilding.
DUMP1090_EXPORTER_HOST="${DUMP1090_EXPORTER_HOST:-dump1090-exporter}"
DUMP1090_EXPORTER_PORT="${DUMP1090_EXPORTER_PORT:-9105}"

CONFIG_FILE=/etc/otelcol/config.yaml

# Build the config inline rather than via a tpl + envsubst. envsubst would
# also try to consume otelcol's own ${env:NAME} references, and a static tpl
# can't drop pipelines that have no enabled receivers (otelcol rejects empty
# `receivers: []`). Generating from shell keeps both problems away.

cat > "$CONFIG_FILE" <<'BASE_CONFIG'
# Generated at container startup by otel-collector/start.sh. Edits will be
# overwritten on next restart — change env vars on the balena fleet/device
# instead. Receivers/exporters used here come from
# https://github.com/open-telemetry/opentelemetry-collector-contrib
extensions:
  health_check:
    endpoint: 0.0.0.0:13133

processors:
  batch:
    timeout: 10s
    send_batch_size: 1024
  resourcedetection/system:
    detectors: [env, system]
    timeout: 5s
    override: false
  resource/balena:
    attributes:
      - key: service.namespace
        value: balena-ads-b
        action: upsert
      - key: balena.device_uuid
        value: ${env:BALENA_DEVICE_UUID}
        action: upsert
      - key: balena.app_id
        value: ${env:BALENA_APP_ID}
        action: upsert
      - key: balena.app_name
        value: ${env:BALENA_APP_NAME}
        action: upsert
      - key: balena.device_name
        value: ${env:BALENA_DEVICE_NAME_AT_INIT}
        action: upsert
      - key: balena.device_type
        value: ${env:BALENA_DEVICE_TYPE}
        action: upsert
      - key: balena.host_os_version
        value: ${env:BALENA_HOST_OS_VERSION}
        action: upsert

exporters:
  otlphttp:
    endpoint: ${env:OTLP_ENDPOINT}
    headers:
      authorization: ${env:OTLP_AUTH_HEADER}
    compression: gzip
    retry_on_failure:
      enabled: true
      initial_interval: 5s
      max_interval: 30s
      max_elapsed_time: 300s
    sending_queue:
      enabled: true
      num_consumers: 4
      queue_size: 100

receivers:
BASE_CONFIG

METRICS_RECEIVERS=()
LOGS_RECEIVERS=()

if [ "$OTEL_HOSTMETRICS_ENABLED" = "true" ]; then
	METRICS_RECEIVERS+=("hostmetrics")
	# /proc and /sys come from the host via the procfs/sysfs balena labels
	# in docker-compose.yml, so the collector's default root_path: "/" reads
	# the host's view directly — no /hostfs prefix needed.
	cat >> "$CONFIG_FILE" <<EOF
  hostmetrics:
    collection_interval: ${OTEL_COLLECTION_INTERVAL}
    scrapers:
      cpu:
      load:
      memory:
      disk:
      filesystem:
        exclude_mount_points:
          mount_points: ["/dev/.*", "/proc/.*", "/sys/.*", "/run/.*", "/var/lib/docker/.*", "/var/lib/balena-engine/.*", "/mnt/data/docker/.*", "/mnt/data/balena-engine/.*"]
          match_type: regexp
      network:
      paging:
      processes:
EOF
fi

if [ "$OTEL_DOCKER_STATS_ENABLED" = "true" ]; then
	METRICS_RECEIVERS+=("docker_stats")
	cat >> "$CONFIG_FILE" <<EOF
  docker_stats:
    endpoint: ${OTEL_DOCKER_ENDPOINT}
    collection_interval: ${OTEL_COLLECTION_INTERVAL}
    timeout: 20s
    metrics:
      container.cpu.utilization:
        enabled: true
      container.memory.percent:
        enabled: true
      container.network.io.usage.tx_bytes:
        enabled: true
      container.network.io.usage.rx_bytes:
        enabled: true
      container.restarts:
        enabled: true
EOF
fi

if [ "$OTEL_DUMP1090_ENABLED" = "true" ]; then
	METRICS_RECEIVERS+=("prometheus/dump1090")
	# Scrape the sibling dump1090-exporter service
	# (https://github.com/schubydoo/dump1090-exporter, MIT) over the balena
	# compose bridge network. The dump1090-exporter service must also be
	# listed in ENABLED_SERVICES on the device — otherwise it parks itself
	# and the scrape will fail (the collector logs a warning per interval).
	cat >> "$CONFIG_FILE" <<EOF
  prometheus/dump1090:
    config:
      scrape_configs:
        - job_name: dump1090
          scrape_interval: ${OTEL_COLLECTION_INTERVAL}
          static_configs:
            - targets: ['${DUMP1090_EXPORTER_HOST}:${DUMP1090_EXPORTER_PORT}']
EOF
fi

if [ "$OTEL_LOGS_ENABLED" = "true" ]; then
	LOGS_RECEIVERS+=("journald")
	# journalctl auto-discovers both /var/log/journal (persistent logs, see
	# https://docs.balena.io/learn/manage/device-logs#persistent-logging) and
	# /run/log/journal (volatile, used when persistent logging is off). Both
	# directories are mounted read-only by docker-compose.yml; whichever the
	# host actually populates is what we read.
	JOURNALD_UNITS_YAML=""
	if [ -n "$OTEL_LOG_UNITS" ]; then
		JOURNALD_UNITS_YAML="    units:"$'\n'
		IFS=',' read -ra _units <<< "$OTEL_LOG_UNITS"
		for u in "${_units[@]}"; do
			u_trimmed="$(echo "$u" | tr -d '[:space:]')"
			[ -n "$u_trimmed" ] && JOURNALD_UNITS_YAML+="      - ${u_trimmed}"$'\n'
		done
	fi
	{
		echo "  journald:"
		echo "    directory: /var/log/journal"
		echo "    priority: ${OTEL_LOG_PRIORITY:-info}"
		[ -n "$JOURNALD_UNITS_YAML" ] && printf '%s' "$JOURNALD_UNITS_YAML"
	} >> "$CONFIG_FILE"
fi

# Pipelines: drop any signal type with no receivers — otelcol rejects empty
# receiver lists at startup.
yaml_list() {
	local IFS=', '
	printf '[%s]' "$*"
}

{
	echo ""
	echo "service:"
	echo "  extensions: [health_check]"
	echo "  pipelines:"
	if [ ${#METRICS_RECEIVERS[@]} -gt 0 ]; then
		echo "    metrics:"
		echo "      receivers: $(yaml_list "${METRICS_RECEIVERS[@]}")"
		echo "      processors: [resourcedetection/system, resource/balena, batch]"
		echo "      exporters: [otlphttp]"
	fi
	if [ ${#LOGS_RECEIVERS[@]} -gt 0 ]; then
		echo "    logs:"
		echo "      receivers: $(yaml_list "${LOGS_RECEIVERS[@]}")"
		echo "      processors: [resourcedetection/system, resource/balena, batch]"
		echo "      exporters: [otlphttp]"
	fi
	if [ ${#METRICS_RECEIVERS[@]} -eq 0 ] && [ ${#LOGS_RECEIVERS[@]} -eq 0 ]; then
		echo "ERROR: every receiver is disabled, nothing to do. Set at least one of OTEL_HOSTMETRICS_ENABLED, OTEL_DOCKER_STATS_ENABLED, OTEL_DUMP1090_ENABLED, OTEL_LOGS_ENABLED to true."
		echo ""
		sleep infinity
	fi
	echo "  telemetry:"
	echo "    logs:"
	echo "      level: ${OTEL_LOG_LEVEL:-info}"
} >> "$CONFIG_FILE"

echo "Generated otelcol config:"
echo "--------"
cat "$CONFIG_FILE"
echo "--------"
echo " "

echo "Starting otelcol-contrib..."
exec /usr/local/bin/otelcol-contrib --config="$CONFIG_FILE"
