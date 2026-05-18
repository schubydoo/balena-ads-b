#!/usr/bin/env bash
set -e

# Check if service has been enabled through the ENABLED_SERVICES environment variable.

if [[ ",$(echo -e "${ENABLED_SERVICES}" | tr -d '[:space:]')," != *",$BALENA_SERVICE_NAME,"* ]]; then
        echo "$BALENA_SERVICE_NAME is not enabled. Sending request to stop the service:"
        curl --fail --retry 86400 --retry-delay 1 --retry-all-errors --header "Content-Type:application/json" "$BALENA_SUPERVISOR_ADDRESS/v2/applications/$BALENA_APP_ID/stop-service?apikey=$BALENA_SUPERVISOR_API_KEY" -d '{"serviceName": "'$BALENA_SERVICE_NAME'"}'
        echo " "
        tail -f /dev/null
fi

# Stats.json shim: dump1090-fa emits a different stats.json schema than readsb,
# which Ident's frontend was written against. Mirror the source dir into a
# writable dir, transforming stats.json so Msg/s, Gain, and Uptime populate.
# Max Range remains "—" — dump1090-fa doesn't track max_distance.
# See https://github.com/Ident-1090/Ident/discussions/9
IDENT_SOURCE_DIR="${IDENT_SOURCE_DIR:-/run/dump1090-fa}"
IDENT_DATA_DIR="${IDENT_DATA_DIR:-/run/ident-data}"
mkdir -p "$IDENT_DATA_DIR"

JQ_STATS_XFORM='
def hoist: if type=="object" then .messages_valid = (.messages_valid // .messages) else . end;
.now      = (.now      // .total.end)
| .gain_db = (.gain_db // (.last1min.local.gain_db // .last5min.local.gain_db // .total.local.gain_db))
| .last1min  |= hoist
| .last5min  |= hoist
| .last15min |= hoist
| .total     |= hoist
| .latest    |= hoist
'

sync_once() {
        for src in "$IDENT_SOURCE_DIR"/aircraft.json "$IDENT_SOURCE_DIR"/receiver.json "$IDENT_SOURCE_DIR"/history_*.json; do
                [ -f "$src" ] || continue
                base="$(basename "$src")"
                cp "$src" "$IDENT_DATA_DIR/$base.tmp" && mv "$IDENT_DATA_DIR/$base.tmp" "$IDENT_DATA_DIR/$base"
        done
        if [ -f "$IDENT_SOURCE_DIR/stats.json" ]; then
                jq "$JQ_STATS_XFORM" "$IDENT_SOURCE_DIR/stats.json" > "$IDENT_DATA_DIR/stats.json.tmp" \
                        && mv "$IDENT_DATA_DIR/stats.json.tmp" "$IDENT_DATA_DIR/stats.json"
        fi
}

sync_once
(
        while inotifywait -qq -e close_write,moved_to "$IDENT_SOURCE_DIR" >/dev/null 2>&1; do
                sync_once
        done
) &

# Hand off to the upstream image's entrypoint + default command.
exec /usr/local/bin/docker-entrypoint.sh /usr/local/bin/identd
