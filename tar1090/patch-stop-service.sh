#!/bin/bash
set -e
# Patch stop_service() in /scripts/common to avoid calling `ps` entirely.
#
# On ARM64/balenaOS, procps 4.0.4 (Debian Trixie) crashes with
# "fatal library error, lookup self" when `ps` tries to dlopen libnuma.
# The base image's stop_service() calls `ps` to walk the process tree and
# find the parent s6-supervise service name, triggering an infinite crash loop.
#
# Instead of fixing `ps`, we replace the lookup entirely: s6 service scripts
# live at /etc/s6-overlay/scripts/<service-name>, so basename "$0" gives us
# the service name directly — no process tree walking needed.
#
# See: https://github.com/ketilmo/balena-ads-b/issues/408

COMMON="/scripts/common"

if [ ! -f "$COMMON" ]; then
    echo "WARNING: $COMMON not found, skipping patch"
    exit 0
fi

# Replace the ps-based service name lookup with basename.
# Match the line containing both _SERVICE=$(ps and s6-supervise, replace the whole line.
if grep -q '_SERVICE=\$(ps.*s6-supervise' "$COMMON"; then
    sed -i '/_SERVICE=\$(ps.*s6-supervise/c\    _SERVICE=$(basename "$0")' "$COMMON"
    echo "Patched stop_service() in /scripts/common successfully"
else
    echo "WARNING: ps-based _SERVICE line not found in $COMMON, skipping patch"
fi
