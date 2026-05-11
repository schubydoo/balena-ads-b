#!/usr/bin/env bash
set -e

function setup_wingbits_client() {
	# Determine the architecture
        GOOS="linux"
	case "$(uname -m)" in
		x86_64)
			GOARCH="amd64"
			;;
		i386|i686)
			GOARCH="386"
			;;
		armv7l)
			GOARCH="arm"
			;;
		aarch64|arm64)
			GOARCH="arm64"
			;;
		*)
			echo "Unsupported architecture"
			exit 1
			;;
	esac
	WINGBITS_PATH="/usr/local/bin"
        WINGBITS_VERSION_PATH="/etc/wingbits"
	echo "Architecture: $GOOS-$GOARCH"
	mkdir -p $WINGBITS_PATH
        mkdir -p $WINGBITS_VERSION_PATH

	# Fetch arch-specific manifest to obtain the expected SHA256 of the
	# extracted binary. Manifest Sha256 is base64-encoded.
	curl -fsSL -o /tmp/wingbits-manifest.json "https://install.wingbits.com/$GOOS-$GOARCH.json"
	expected_sha256_b64=$(jq -r '.Sha256' /tmp/wingbits-manifest.json)
	expected_sha256_hex=$(printf '%s' "$expected_sha256_b64" | base64 -d | od -An -tx1 | tr -d ' \n')

	curl -fsSL -o $WINGBITS_PATH/wingbits.gz "https://install.wingbits.com/$WINGBITS_COMMIT_ID/$GOOS-$GOARCH.gz"
	gunzip $WINGBITS_PATH/wingbits.gz

	echo "$expected_sha256_hex  $WINGBITS_PATH/wingbits" | sha256sum -c -

	rm /tmp/wingbits-manifest.json
	chmod +x $WINGBITS_PATH/wingbits
	PATH=$WINGBITS_PATH:$PATH
}

setup_wingbits_client
