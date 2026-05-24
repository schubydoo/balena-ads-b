#!/usr/bin/env sh
set -e

# Check if service has been opted in through the ENABLED_SERVICES environment variable.

case ",$(echo "${ENABLED_SERVICES:-}" | tr -d '[:space:]')," in
	*",${BALENA_SERVICE_NAME},"*)
		;;
	*)
		echo "$BALENA_SERVICE_NAME is not enabled. Sending request to stop the service:"
		curl --fail --retry 86400 --retry-delay 1 --retry-all-errors --header "Content-Type:application/json" "$BALENA_SUPERVISOR_ADDRESS/v2/applications/$BALENA_APP_ID/stop-service?apikey=$BALENA_SUPERVISOR_API_KEY" -d '{"serviceName": "'"$BALENA_SERVICE_NAME"'"}'
		echo " "
		sleep infinity
		;;
esac

# Announce the chosen authentication method. Three are supported:
#
#   1. Pre-auth key:    TS_AUTHKEY=tskey-auth-…   (Admin console → Settings → Keys)
#   2. OAuth client:    TS_AUTHKEY=tskey-client-…?ephemeral=false&preauthorized=true
#                       (Admin console → Settings → OAuth clients; recommended
#                       for fleets backed by SSO since the client inherits the
#                       authenticated identity)
#   3. Interactive SSO: TS_AUTHKEY left empty. tailscaled prints a one-time
#                       login URL to the container logs; open it in your
#                       SSO-enabled browser to authorize the device.

if [ -z "${TS_AUTHKEY:-}" ]; then
	echo "TS_AUTHKEY is not set – Tailscale will print an interactive login URL"
	echo "to the container logs. Open it in your SSO-enabled browser to authorize"
	echo "this device, or set TS_AUTHKEY to a pre-auth key / OAuth client secret."
else
	echo "TS_AUTHKEY is set, proceeding with non-interactive authentication."
fi

echo " "

# balena-friendly defaults; only set when the user has not overridden.

: "${TS_USERSPACE:=false}"
: "${TS_ACCEPT_DNS:=false}"
: "${TS_HOSTNAME:=${BALENA_DEVICE_NAME_AT_INIT:-}}"
: "${TS_EXCLUDED_INTERFACES:=resin-vpn resin-dns}"
export TS_USERSPACE TS_ACCEPT_DNS TS_HOSTNAME TS_EXCLUDED_INTERFACES

# Kernel-mode tailscaled needs /dev/net/tun. balenaOS usually exposes the host
# device via io.balena.features.kernel-modules, but on some base images we
# still have to mknod it ourselves.

modprobe tun 2>/dev/null || true
modprobe wireguard 2>/dev/null || true
mkdir -p /dev/net
if [ ! -c /dev/net/tun ]; then
	mknod /dev/net/tun c 10 200
fi

mount -o remount,rw /proc/sys 2>/dev/null || \
	echo "remount /proc/sys rw failed; tailscaled will warn about src_valid_mark and connmark rp_filter workaround will be ineffective."

# Optional: terminate Tailscale Serve (HTTPS on :443) in front of traefik. The
# file ships unmodified — ${TS_CERT_DOMAIN} inside is a magic placeholder
# tailscaled substitutes for the device's tailnet hostname at runtime.

case "$(echo "${TAILSCALE_SERVE_TRAEFIK:-}" | tr '[:upper:]' '[:lower:]')" in
	true|yes|on|1|y|enable|enabled)
		export TS_SERVE_CONFIG=/etc/tailscale/serve.json
		;;
esac

# In interactive-SSO mode (TS_AUTHKEY empty) tailscaled emits a one-time login
# URL on first boot. Background-poll the LocalAPI so the URL surfaces as a
# clear banner in the container logs rather than buried in normal startup
# chatter. The poller exits on its own once the URL is shown or the backend
# reaches Running, so it does not linger past first authentication.

if [ -z "${TS_AUTHKEY:-}" ]; then
	(
		s=0
		while [ ! -S /var/run/tailscale/tailscaled.sock ]; do
			s=$((s + 1))
			if [ "$s" -gt 180 ]; then
				echo "Tailscale SSO URL poller: tailscaled socket never appeared after 3 minutes; giving up."
				exit 0
			fi
			sleep 1
		done
		i=0
		while [ "$i" -lt 120 ]; do
			STATUS=$(/usr/local/bin/tailscale status --json 2>/dev/null || true)
			# `tailscale status --json` pretty-prints with `"key": "value"`
			# (space after colon); the regex permits zero-or-more spaces so
			# both pretty and compact JSON are handled.
			URL=$(echo "$STATUS" | sed -n 's/.*"AuthURL"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
			BACKEND=$(echo "$STATUS" | sed -n 's/.*"BackendState"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
			if [ -n "$URL" ]; then
				printf '\n========================================================================\n'
				printf 'Tailscale needs interactive sign-in. Open this URL in an SSO-signed-in\n'
				printf 'browser to authorize this device:\n'
				printf '    %s\n' "$URL"
				printf '========================================================================\n\n'
				break
			fi
			if [ "$BACKEND" = "Running" ]; then
				break
			fi
			i=$((i + 1))
			sleep 2
		done
		if [ "$i" -ge 120 ]; then
			echo "Tailscale SSO URL poller: gave up after 4 minutes without finding URL or Running state."
		fi
	) &
fi

# Optional post-up `tailscale set` preferences. Two layers:
#   TS_UPDATE_CHECK      convenience var; if non-empty, becomes
#                        --update-check=$value (true|false), toggling
#                        tailscaled's outbound update-check probes.
#   TS_POST_UP_SET_ARGS  escape hatch; raw `tailscale set` args appended
#                        verbatim (space-separated).
# Applied in two stages: stage 1 pushes --update-check as soon as the
# LocalAPI accepts prefs edits (any non-empty BackendState); stage 2
# waits for BackendState=Running and applies TS_POST_UP_SET_ARGS,
# re-applying --update-check defensively. Skipped silently if neither
# var is set.

if [ -n "${TS_UPDATE_CHECK:-}" ] || [ -n "${TS_POST_UP_SET_ARGS:-}" ]; then
	(
		s=0
		while [ ! -S /var/run/tailscale/tailscaled.sock ]; do
			s=$((s + 1))
			if [ "$s" -gt 180 ]; then
				echo "tailscale set: tailscaled socket never appeared after 3 minutes; skipping post-up runner."
				exit 0
			fi
			sleep 1
		done

		# Stage 1: push --update-check as soon as the LocalAPI accepts
		# prefs edits (any non-empty BackendState).
		if [ -n "${TS_UPDATE_CHECK:-}" ]; then
			k=0
			while [ "$k" -lt 30 ]; do
				BACKEND=$(/usr/local/bin/tailscale status --json 2>/dev/null \
					| sed -n 's/.*"BackendState"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
				if [ -n "$BACKEND" ]; then
					/usr/local/bin/tailscale set --update-check="$TS_UPDATE_CHECK" \
						|| echo "early tailscale set --update-check failed (exit $?); will retry post-Running."
					break
				fi
				k=$((k + 1))
				sleep 1
			done
		fi

		# Stage 2: wait for Running, then apply TS_POST_UP_SET_ARGS (and
		# re-apply --update-check defensively in case stage 1 lost the race).
		j=0
		BACKEND=""
		while [ "$j" -lt 60 ]; do
			BACKEND=$(/usr/local/bin/tailscale status --json 2>/dev/null \
				| sed -n 's/.*"BackendState"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
			[ "$BACKEND" = "Running" ] && break
			j=$((j + 1))
			sleep 2
		done
		if [ "$BACKEND" != "Running" ]; then
			echo "tailscale set: backend did not reach Running within 2 minutes; skipping."
			exit 0
		fi
		SET_ARGS=""
		[ -n "${TS_UPDATE_CHECK:-}" ] && SET_ARGS="$SET_ARGS --update-check=$TS_UPDATE_CHECK"
		[ -n "${TS_POST_UP_SET_ARGS:-}" ] && SET_ARGS="$SET_ARGS $TS_POST_UP_SET_ARGS"
		echo "Applying post-up tailscale set:$SET_ARGS"
		# shellcheck disable=SC2086   # intentional word-splitting on SET_ARGS
		/usr/local/bin/tailscale set $SET_ARGS || \
			echo "tailscale set failed (exit $?); continuing."
	) &
fi

# Hand off to upstream containerboot.

exec /usr/local/bin/containerboot
