#!/usr/bin/env bash
set -e

# Check if service has been opted in through the ENABLED_SERVICES environment variable.

if [[ ",$(echo -e "${ENABLED_SERVICES}" | tr -d '[:space:]')," != *",$BALENA_SERVICE_NAME,"* ]]; then
        echo "$BALENA_SERVICE_NAME is not enabled. Sending request to stop the service:"
        # `|| true` so a curl that exhausts its 24h retry budget doesn't trip
        # `set -e` and skip the sleep — under sustained supervisor failure
        # this ENABLED_SERVICES opt-out branch would otherwise restart every
        # 24h instead of idling cleanly.
        curl --fail --retry 86400 --retry-delay 1 --retry-all-errors --header "Content-Type:application/json" "$BALENA_SUPERVISOR_ADDRESS/v2/applications/$BALENA_APP_ID/stop-service?apikey=$BALENA_SUPERVISOR_API_KEY" -d '{"serviceName": "'$BALENA_SERVICE_NAME'"}' || true
        echo " "
        sleep infinity
fi

# Hand off to the upstream image's entrypoint + default command.
exec /usr/local/bin/docker-entrypoint.sh /usr/local/bin/identd
