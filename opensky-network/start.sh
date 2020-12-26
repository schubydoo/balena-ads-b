#!/usr/bin/env bash
set -e

# Check if service has been disabled through the DISABLED_SERVICES environment variable.

if [[ ",$DISABLED_SERVICES," =~ ",$BALENA_SERVICE_NAME," ]]; then
        echo "$BALENA_SERVICE_NAME is manually disabled."
        sleep infinity
fi

# Verify that all the required varibles are set before starting up the application.

echo "Verifying settings..."
echo " "
sleep 2

missing_variables=false
        
# Begin defining all the required configuration variables.

[ -z "$OPENSKY_USERNAME" ] && echo "OpenSky Network Username is missing, will abort startup." && missing_variables=true || echo "OpenSky Network Username is set: $OPENSKY_USERNAME"
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
        sleep infinity
fi

echo "Settings verified, proceeding with startup."
echo " "

# Variables are verified – continue with startup procedure.

# Write settings to config file.
envsubst < /var/lib/openskyd/conf.tpl/10-debconf.conf.tpl> /var/lib/openskyd/conf.d/10-debconf.conf

# Check if OpenSky Network serial number is missing.

echo "Looking for OpenSky Network Serial..."
echo " "
sleep 2
        
# Begin defining all the required configuration variables.

missing_variables=false
[ -z "$OPENSKY_SERIAL" ] && echo "OpenSky Network Serial is missing, will abort startup." && missing_variables=true || echo "OpenSky Network Serial is set: $OPENSKY_SERIAL"

echo " "

if [ "$missing_variables" = true ]
then
        echo "OpenSky Network Serial is missing, aborting..."
        echo " "
        sleep infinity
fi

envsubst < /var/lib/openskyd/conf.tpl/05-serial.conf.tpl> /var/lib/openskyd/conf.d/05-serial.conf

echo "Settings verified, proceeding with startup."
echo " "

# Variables are verified – continue with startup procedure.

# Start openskyd-dump1090 and put it in the background.
/usr/bin/openskyd-dump1090 &

# Wait for any services to exit.
wait -n
