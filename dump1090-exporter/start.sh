#!/bin/sh
# POSIX sh (alpine /bin/sh = busybox ash) — no bashisms.
set -e

# Check if service has been opted in through the ENABLED_SERVICES environment variable.

enabled_services=$(printf '%s' "${ENABLED_SERVICES}" | tr -d '[:space:]')
case ",${enabled_services}," in
	*",${BALENA_SERVICE_NAME},"*) ;;
	*)
		echo "${BALENA_SERVICE_NAME} is not enabled. Sending request to stop the service:"
		curl --fail --retry 86400 --retry-delay 1 --retry-all-errors \
			--header "Content-Type:application/json" \
			"${BALENA_SUPERVISOR_ADDRESS}/v2/applications/${BALENA_APP_ID}/stop-service?apikey=${BALENA_SUPERVISOR_API_KEY}" \
			-d "{\"serviceName\": \"${BALENA_SERVICE_NAME}\"}"
		echo " "
		sleep infinity
		;;
esac

# DUMP1090_RESOURCE_PATH defaults to the shared aircraft-data named volume,
# which dump1090-fa writes to via --write-json /run/dump1090-fa. Reading from
# the filesystem avoids a network round-trip per scrape vs. the HTTP path
# (http://dump1090-fa:8080/data).

# shellcheck disable=SC2086  # intentional word-splitting on optional flags
exec dump1090exporter \
	--resource-path="${DUMP1090_RESOURCE_PATH:-/run/dump1090-fa}" \
	--port="${DUMP1090_EXPORTER_PORT:-9105}" \
	${LAT:+--latitude="${LAT}"} \
	${LON:+--longitude="${LON}"} \
	--log-level="${DUMP1090_EXPORTER_LOG_LEVEL:-info}"
