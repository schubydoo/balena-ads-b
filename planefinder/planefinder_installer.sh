#!/usr/bin/env bash
set -e

arch="$(dpkg --print-architecture)"
echo System Architecture: $arch

if [ "$arch" = "arm64" ]; then 
	planefinder_arch="armhf"
	dpkg --add-architecture armhf
	apt-get update && \
		apt-get install -y gcc-8-base:armhf libc6:armhf libgcc1:armhf libidn2-0:armhf libunistring2:armhf
elif [ "$arch" = "amd64" ]; then 
	planefinder_arch="i386"
	dpkg --add-architecture i386
	apt-get update && \
		apt-get install -y gcc-8-base:i386 libc6:i386 libgcc1:i386 libidn2-0:i386 libunistring2:i386
else 
	planefinder_arch="armhf" 
	apt-get update && \
		apt-get install -y libc6
fi

apt-get clean && rm -rf /var/lib/apt/lists/*

planefinder_packet="pfclient_${PLANEFINDER_VERSION}_$planefinder_arch.deb"

cd /tmp/

wget http://client.planefinder.net/$planefinder_packet && \
	dpkg -i $planefinder_packet && \
	rm -rf /tmp/*