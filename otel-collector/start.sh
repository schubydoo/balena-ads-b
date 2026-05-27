#!/bin/sh
# Single-container entrypoint: background node_exporter, exec otelcol-contrib.
# tini (PID 1) reaps zombies and forwards signals to both via -g.
set -e

# --- ENABLED_SERVICES gate (matches the existing mlat-client pattern) ---
enabled=$(printf '%s' "${ENABLED_SERVICES}" | tr -d '[:space:]')
case ",${enabled}," in
    *",${BALENA_SERVICE_NAME},"*) ;;
    *)
        echo "${BALENA_SERVICE_NAME} not in ENABLED_SERVICES; asking supervisor to stop us."
        # `|| true` so a curl that exhausts its 24h retry budget doesn't trip
        # `set -e` and skip the sleep — under sustained supervisor failure
        # this ENABLED_SERVICES opt-out branch would otherwise restart every
        # 24h instead of idling cleanly.
        curl --fail --retry 86400 --retry-delay 1 --retry-all-errors \
            --header "Content-Type:application/json" \
            "${BALENA_SUPERVISOR_ADDRESS}/v2/applications/${BALENA_APP_ID}/stop-service?apikey=${BALENA_SUPERVISOR_API_KEY}" \
            -d "{\"serviceName\": \"${BALENA_SERVICE_NAME}\"}" || true
        sleep infinity
        ;;
esac

# --- Grafana Cloud convenience: derive OTLP_AUTH_HEADER from instance + token ---
if [ -z "${OTLP_AUTH_HEADER}" ] && [ -n "${GRAFANA_INSTANCE_ID}" ] && [ -n "${GRAFANA_API_KEY}" ]; then
    OTLP_AUTH_HEADER="Basic $(printf '%s:%s' "${GRAFANA_INSTANCE_ID}" "${GRAFANA_API_KEY}" | base64 -w0)"
    export OTLP_AUTH_HEADER
    echo "OTLP_AUTH_HEADER computed from GRAFANA_INSTANCE_ID + GRAFANA_API_KEY."
fi
[ -z "${OTLP_ENDPOINT}" ]    && { echo "OTLP_ENDPOINT missing, aborting.";    sleep infinity; }
[ -z "${OTLP_AUTH_HEADER}" ] && { echo "OTLP_AUTH_HEADER missing (or GRAFANA_INSTANCE_ID + GRAFANA_API_KEY), aborting."; sleep infinity; }

# --- Defaults + exports for OTel ${env:...} substitution ---
export OTEL_NODE_METRICS_ENABLED="${OTEL_NODE_METRICS_ENABLED:-true}"
export OTEL_DOCKER_STATS_ENABLED="${OTEL_DOCKER_STATS_ENABLED:-true}"
export OTEL_DUMP1090_ENABLED="${OTEL_DUMP1090_ENABLED:-false}"
export OTEL_LOGS_ENABLED="${OTEL_LOGS_ENABLED:-false}"
export OTEL_COLLECTION_INTERVAL="${OTEL_COLLECTION_INTERVAL:-30s}"
export OTEL_DOCKER_ENDPOINT="${OTEL_DOCKER_ENDPOINT:-unix:///var/run/balena.sock}"
export DUMP1090_EXPORTER_HOST="${DUMP1090_EXPORTER_HOST:-dump1090-exporter}"
export DUMP1090_EXPORTER_PORT="${DUMP1090_EXPORTER_PORT:-9105}"
# Friendly instance label for prebuilt Linux Server dashboards.
export NODE_EXPORTER_INSTANCE="${NODE_EXPORTER_INSTANCE:-${BALENA_DEVICE_NAME_AT_INIT:-${BALENA_DEVICE_UUID:-balena-device}}}"

# --- Journald directory: prefer persistent, fall back to volatile ---
if [ -n "${OTEL_JOURNALD_DIRECTORY}" ]; then
    JOURNAL_DIR="${OTEL_JOURNALD_DIRECTORY}"
elif find /var/log/journal -maxdepth 2 -name '*.journal' 2>/dev/null | head -1 | grep -q .; then
    JOURNAL_DIR=/var/log/journal
else
    JOURNAL_DIR=/run/log/journal
fi
export JOURNAL_DIR

# --- Build --config flag list ---
CFG="--config /etc/otelcol/config/base.yaml"
[ "${OTEL_DOCKER_STATS_ENABLED}" = "true" ] && CFG="${CFG} --config /etc/otelcol/config/metrics-docker.yaml"
[ "${OTEL_NODE_METRICS_ENABLED}" = "true" ] && CFG="${CFG} --config /etc/otelcol/config/metrics-host.yaml"
[ "${OTEL_DUMP1090_ENABLED}"     = "true" ] && CFG="${CFG} --config /etc/otelcol/config/metrics-dump1090.yaml"
[ "${OTEL_LOGS_ENABLED}"         = "true" ] && CFG="${CFG} --config /etc/otelcol/config/logs-journald.yaml"

# --- Background node_exporter on loopback if host metrics are on ---
if [ "${OTEL_NODE_METRICS_ENABLED}" = "true" ]; then
    echo "Starting node_exporter on 127.0.0.1:9100"
    /usr/local/bin/node_exporter \
        --web.listen-address=127.0.0.1:9100 \
        --collector.filesystem.mount-points-exclude='^/(?:dev|proc|sys|var/lib/(docker|balena-engine|containers))($|/)' &
fi

# --- otelcol-contrib runs in the foreground; balena restarts the container on exit ---
echo "Starting otelcol-contrib with: ${CFG}"
exec /usr/local/bin/otelcol-contrib ${CFG}
