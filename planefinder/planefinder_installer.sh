#!/usr/bin/env bash
set -e

arch="$(dpkg --print-architecture)"
echo System Architecture: $arch

case "$arch" in
	arm64|amd64|armhf)
		planefinder_version="$PLANEFINDER_VERSION"
		planefinder_arch="$arch"
		;;
	*)
		echo "Unsupported architecture for PlaneFinder: $arch" >&2
		exit 1
		;;
esac

planefinder_packet="pfclient_${planefinder_version}_${planefinder_arch}.deb"

cd /tmp/

# PlaneFinder does not publish checksums for the pfclient .deb, so the
# download is unverified beyond TLS. Harden the wget call with explicit
# timeouts and retries to fail fast on transient network issues.
wget --tries=3 --timeout=60 --retry-connrefused \
	-O PlaneFinder.deb "https://client.planefinder.net/$planefinder_packet"
