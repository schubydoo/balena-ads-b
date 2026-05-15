#!/usr/bin/env bash
set -e

arch="$(dpkg --print-architecture)"
echo "System Architecture: $arch"

# Per-arch version pins are passed in as separate env vars because
# upstream releases pfclient asymmetrically across architectures.
# See planefinder/Dockerfile.template for the tracking rationale.
case "$arch" in
	amd64)
		planefinder_version="$PLANEFINDER_VERSION_AMD64"
		;;
	arm64)
		planefinder_version="$PLANEFINDER_VERSION_ARM64"
		;;
	armhf)
		planefinder_version="$PLANEFINDER_VERSION_ARMHF"
		;;
	*)
		echo "Unsupported architecture for PlaneFinder: $arch" >&2
		exit 1
		;;
esac

if [ -z "$planefinder_version" ]; then
	echo "PlaneFinder version pin for $arch is empty" >&2
	exit 1
fi

planefinder_packet="pfclient_${planefinder_version}_${arch}.deb"

cd /tmp/

# PlaneFinder does not publish checksums for the pfclient .deb, so the
# download is unverified beyond TLS. Harden the wget call with explicit
# timeouts and retries to fail fast on transient network issues.
wget --tries=3 --timeout=60 --retry-connrefused \
	-O PlaneFinder.deb "https://client.planefinder.net/$planefinder_packet"
