#!/usr/bin/env bash
set -e

arch="$(dpkg --print-architecture)"
echo System Architecture: $arch

if [ "$arch" = "arm64" ]; then 
	traefik_arch="arm64"
elif [ "$arch" = "amd64" ]; then 
	traefik_arch="amd64"
else 
	traefik_arch="armv6" 
fi

traefik_packet="traefik_v${TRAEFIK_VERSION}_linux_$traefik_arch.tar.gz"

cd /tmp/

wget --quiet -O traefik.tar.gz "https://github.com/traefik/traefik/releases/download/v${TRAEFIK_VERSION}/$traefik_packet"
wget --quiet -O traefik_checksums.txt "https://github.com/traefik/traefik/releases/download/v${TRAEFIK_VERSION}/traefik_v${TRAEFIK_VERSION}_checksums.txt"

expected_sha256=$(awk -v f="$traefik_packet" '$NF == f { print $1 }' traefik_checksums.txt)
if [ -z "$expected_sha256" ]; then
	echo "Could not find SHA256 for $traefik_packet in checksums.txt" >&2
	exit 1
fi

echo "$expected_sha256  traefik.tar.gz" | sha256sum -c -

rm traefik_checksums.txt
