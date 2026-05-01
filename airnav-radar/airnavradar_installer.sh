#!/usr/bin/env bash
set -e

# Import our key into a dedicated keyring (apt-key removed in Trixie).
# Fetch the ASCII-armored key over HTTPS rather than via gpg+dirmngr,
# which fails to bootstrap in a fresh container (no /root/.gnupg, no
# running dirmngr daemon).
mkdir -p /etc/apt/keyrings
curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&options=mr&search=0x1D043681" \
    -o /etc/apt/keyrings/rb24.asc

# Create a new debian repository source file (overwrites if exists)
echo 'deb [signed-by=/etc/apt/keyrings/rb24.asc] https://apt.rb24.com/ trixie main' > /etc/apt/sources.list.d/rb24.list

arch="$(dpkg --print-architecture)"
echo "System Architecture: $arch"

# --- CONFIGURATION ---
# Configure multi-arch if necessary before updating sources
if [ "$arch" = "i386" ] || [ "$arch" = "amd64" ]; then
    dpkg --add-architecture armhf
fi

# Refresh sources
apt update

# --- PRE-INSTALL SYSTEMD ---
# We install systemd explicitly first to ensure the real /usr/bin/systemctl is on disk.
# This prevents race conditions or overwrites during the main install transaction.
apt install -y --no-install-recommends systemd

# --- MOCKING SYSTEMCTL ---
# Divert /usr/bin/systemctl (moves the now-existing real binary to .real)
if ! dpkg-divert --list | grep -q "/usr/bin/systemctl"; then
    dpkg-divert --add --rename --divert /usr/bin/systemctl.real /usr/bin/systemctl
fi

# Create the dummy mock script
echo '#!/bin/sh' > /usr/bin/systemctl
echo 'echo "Mock systemctl: command ignored during build"' >> /usr/bin/systemctl
echo 'exit 0' >> /usr/bin/systemctl
chmod +x /usr/bin/systemctl

# --- INSTALL RBFEEDER ---
if [ "$arch" = "i386" ] || [ "$arch" = "amd64" ]; then
    apt install -y --no-install-recommends \
       rbfeeder:armhf qemu-user qemu-user-static binfmt-support libc6-armhf-cross
else
    apt install -y --no-install-recommends \
       rbfeeder
fi

# --- RESTORE SYSTEMCTL ---
rm -f /usr/bin/systemctl

# Restore original binary from diversion
if dpkg-divert --list | grep -q "/usr/bin/systemctl"; then
    dpkg-divert --remove --rename /usr/bin/systemctl
fi

# Cleanup
apt-get clean && apt-get autoremove -y && \
 rm -rf /var/lib/apt/lists/*
