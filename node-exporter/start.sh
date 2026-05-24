#!/bin/sh
# POSIX sh — keep portable in case the base image changes again.
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

# Bind to 0.0.0.0 so the sibling otel-collector service can reach us via
# the balena compose bridge service name (node-exporter:9100). Filesystem
# exclusion patterns match the OTel hostmetricsreceiver defaults plus
# balena's data partition layout, so we don't waste cardinality on overlay
# layers, balena-engine bind mounts, or container runtime mounts.
exec /usr/local/bin/node_exporter \
	--web.listen-address="0.0.0.0:${NODE_EXPORTER_PORT:-9100}" \
	--collector.filesystem.mount-points-exclude="^/(dev|proc|sys|var/lib/docker/.+|var/lib/balena-engine/.+|mnt/data/docker/.+|mnt/data/balena-engine/.+)($|/)" \
	--collector.filesystem.fs-types-exclude="^(autofs|binfmt_misc|bpf|cgroup2?|configfs|debugfs|devpts|devtmpfs|fusectl|hugetlbfs|iso9660|mqueue|nsfs|overlay|proc|procfs|pstore|rpc_pipefs|securityfs|selinuxfs|squashfs|sysfs|tracefs)$"
