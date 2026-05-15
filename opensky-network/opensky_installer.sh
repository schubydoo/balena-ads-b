#!/usr/bin/env bash
set -e

arch="$(dpkg --print-architecture)"
echo System Architecture: $arch

if [ "$arch" = "arm64" ]; then
	opensky_arch="arm64"
elif [ "$arch" = "amd64" ]; then
	opensky_arch="amd64"
else
	opensky_arch="armhf"
fi

opensky_packet="opensky-feeder_${OPENSKY_VERSION}_$opensky_arch.deb"

packages_file="/tmp/.Packages.${opensky_arch}"
if [ ! -r "$packages_file" ]; then
	echo "Missing mirrored Packages index: $packages_file" >&2
	exit 1
fi

expected_sha256=$(awk -v ver="$OPENSKY_VERSION" -v arch="$opensky_arch" '
	/^Package: opensky-feeder$/ { in_pkg=1; pkg_ver=""; pkg_arch=""; next }
	/^Package: / { in_pkg=0; next }
	in_pkg && /^Version: / { pkg_ver=$2 }
	in_pkg && /^Architecture: / { pkg_arch=$2 }
	in_pkg && /^SHA256: / {
		if (pkg_ver == ver && pkg_arch == arch) { print $2; exit }
	}
' "$packages_file")

if [ -z "$expected_sha256" ]; then
	echo "Could not find SHA256 for opensky-feeder $OPENSKY_VERSION $opensky_arch in $packages_file" >&2
	exit 1
fi

wget -O /tmp/OpenSky.deb https://opensky-network.org/files/firmware/$opensky_packet

echo "$expected_sha256  /tmp/OpenSky.deb" | sha256sum -c -
