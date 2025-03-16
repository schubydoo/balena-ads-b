#!/usr/bin/env bash
set -e

# Check if service has been disabled through the DISABLED_SERVICES environment variable.

if [[ ",$(echo -e "${DISABLED_SERVICES}" | tr -d '[:space:]')," = *",$BALENA_SERVICE_NAME,"* ]]; then
        echo "$BALENA_SERVICE_NAME is manually disabled. Sending request to stop the service:"
        curl --retry 10 --retry-all-errors --header "Content-Type:application/json" "$BALENA_SUPERVISOR_ADDRESS/v2/applications/$BALENA_APP_ID/stop-service?apikey=$BALENA_SUPERVISOR_API_KEY" -d '{"serviceName": "'$BALENA_SERVICE_NAME'"}'
        echo " "
        balena-idle
fi

# Verify that all the required variables are set before starting up the application.

echo "Verifying settings..."
echo " "
sleep 2

missing_variables=false

# Begin defining all the required configuration variables.

# Temporary legacy RADARBOX_KEY usage check

# Function to fetch service status
get_service_status() {
    RESPONSE=$(curl -s -f "$BALENA_SUPERVISOR_ADDRESS/v2/state/status?apikey=$BALENA_SUPERVISOR_API_KEY") || {
        # echo "Failed to fetch service status from Balena Supervisor API."
        exit 1
    }
    
    STATUS=$(echo "$RESPONSE" | jq -r '.containers[] | select(.serviceName=="radarbox") | .status')
    echo "$STATUS"
}

if [ -n "$AIRNAV_RADAR_KEY" ] && [ -n "$RADARBOX_KEY" ]; then
    echo "RADARBOX_KEY is deprecated. Please remove it from your environment variables."
elif [ -z "$AIRNAV_RADAR_KEY" ] && [ -n "$RADARBOX_KEY" ]; then
    export AIRNAV_RADAR_KEY="$RADARBOX_KEY"
    echo "Found legacy radarbox variable RADARBOX_KEY. Using it to set AIRNAV_RADAR_KEY."
    echo "RADARBOX_KEY is deprecated. Please transfer its contents to AIRNAV_RADAR_KEY and remove it."
elif [ -z "$AIRNAV_RADAR_KEY" ] && [ -z "$RADARBOX_KEY" ]; then
    # Check if there is a legacy radarbox container running


    # Check for radarbox service status
    while true; do
        SERVICE_STATUS=$(get_service_status)
        
        if [ -z "$SERVICE_STATUS" ]; then
            #echo "Service 'radarbox' not found. Exiting."
            break
        fi

        case "$SERVICE_STATUS" in
            "Running")
                #echo "Service 'radarbox' is running. Fetching RADARBOX_KEY..."
                RESPONSE=$(curl -s -f http://radarbox:32088/RADARBOX_KEY) || RESPONSE=""
                
                if [ -n "$RESPONSE" ]; then
                    PARSED_KEY=$(echo "$RESPONSE" | jq -r '.RADARBOX_KEY')
                    
                    if [ -n "$PARSED_KEY" ]; then
                        export AIRNAV_RADAR_KEY="$PARSED_KEY"
                        echo "Found legacy radarbox variable RADARBOX_KEY. Using it to set AIRNAV_RADAR_KEY."
                        echo "RADARBOX_KEY is deprecated. Please transfer its contents to AIRNAV_RADAR_KEY and remove it."
                    else
                        echo " "
                       # echo "Failed to extract a valid key from the endpoint response."
                    fi
                else
                    echo " "
                    #echo "Failed to fetch RADARBOX_KEY from the legacy endpoint."
                fi
                
                break
                ;;
            "exited"|"stopped")
                echo " "
                # echo "Service 'radarbox' is stopping or has exited."
                break
                ;;
            *)
                echo "Legacy service 'radarbox' has status '$SERVICE_STATUS'. Retrying in a few seconds to check for key..."
                sleep 5
                ;;
        esac
    done
fi

# End temporary legacy RADARBOX_KEY usage check

[ -z "$AIRNAV_RADAR_KEY" ] && echo "AirNav Radar key is missing, will abort startup." && missing_variables=true  || echo "AirNav Radar key is set: $AIRNAV_RADAR_KEY"
[ -z "$LAT" ] && echo "Receiver latitude is missing, will abort startup." && missing_variables=true || echo "Receiver latitude is set: $LAT"
[ -z "$LON" ] && echo "Receiver longitude is missing, will abort startup." && missing_variables=true || echo "Receiver longitude is set: $LON"
[ -z "$ALT" ] && echo "Receiver altitude is missing, will abort startup." && missing_variables=true || echo "Receiver altitude is set: $ALT"
[ -z "$RECEIVER_HOST" ] && echo "Receiver host is missing, will abort startup." && missing_variables=true || echo "Receiver host is set: $RECEIVER_HOST"
[ -z "$RECEIVER_PORT" ] && echo "Receiver port is missing, will abort startup." && missing_variables=true || echo "Receiver port is set: $RECEIVER_PORT"

# End defining all the required configuration variables.

echo " "

if [ "$missing_variables" = true ]
then
        echo "Settings missing, aborting..."
        echo " "
        balena-idle
fi

# If UAT is enabled through config, enable it in rbfeed.
if [[ "$UAT_ENABLED" = "true" ]]; then
	export UAT_ANR_ENABLED=true
else
	export UAT_ANR_ENABLED=false
fi

echo "Settings verified, proceeding with startup."
echo " "

# Variables are verified – continue with startup procedure.

# Write settings to config file and set permissions.
envsubst < /etc/rbfeeder.ini.tpl > /etc/rbfeeder.ini
chmod a+rw /etc/rbfeeder.ini

# Start rbfeeder and put it in the background.

arch="$(dpkg --print-architecture)"
echo System Architecture: $arch

# If UAT is enabled through config, activate socat port routing.
if [[ "$UAT_ENABLED" = "true" ]]; then
	socat TCP-LISTEN:30979,fork TCP:dump978-fa:30979 &
fi

# If host architecture is i386 or amd64, run AirNav Radar through armhf software emulation.
if [ "$arch" = "i386" ] || [ "$arch" = "amd64" ]; then 
	/usr/bin/qemu-arm-static /usr/bin/rbfeeder &
else 
	/usr/bin/rbfeeder &
fi

# Wait for any services to exit.
wait -n