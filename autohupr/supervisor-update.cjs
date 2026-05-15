#!/usr/bin/env node
// Sidecar to autohupr-example's host-OS updater: keeps the balena Supervisor
// pinned to SUPERVISOR_TARGET_VERSION via the balenaCloud API. Runs alongside
// build/main.js (the upstream HUP loop) — see start.sh.
//
// Auto-injected env (io.balena.features.balena-api):
//   BALENA_API_KEY, BALENA_API_URL, BALENA_DEVICE_UUID
//
// User config:
//   SUPERVISOR_TARGET_VERSION   '' (disabled) | 'latest' | 'recommended' |
//                               version substring, e.g. '16.8.2' or '16.8'.
//                               Do NOT prefix with 'v' — balena-sdk's
//                               raw_version field has no leading 'v'.
//   SUPERVISOR_CHECK_INTERVAL   default '1d'. Supports s/m/h/d suffixes.

'use strict';

const { getSdk } = require('balena-sdk');

const LOG_PREFIX = '[supervisor-update]';
const log = (...a) => console.log(LOG_PREFIX, ...a);
const err = (...a) => console.error(LOG_PREFIX, ...a);

const apiKey = process.env.BALENA_API_KEY;
const apiUrl = process.env.BALENA_API_URL;
const deviceUuid = process.env.BALENA_DEVICE_UUID;
const userTargetVersion = (process.env.SUPERVISOR_TARGET_VERSION || '').trim();
const checkIntervalRaw = process.env.SUPERVISOR_CHECK_INTERVAL || '1d';

for (const [name, value] of [
	['BALENA_API_KEY', apiKey],
	['BALENA_API_URL', apiUrl],
	['BALENA_DEVICE_UUID', deviceUuid],
]) {
	if (!value) {
		err(`${name} required in environment`);
		process.exit(1);
	}
}

const parseDurationMs = (v) => {
	const m = String(v).trim().match(/^(\d+(?:\.\d+)?)\s*(ms|s|m|h|d)$/i);
	if (!m) {
		throw new Error(`expected a number with unit (e.g. '30s', '5m', '1h', '1d'), got '${v}'`);
	}
	const n = Number(m[1]);
	const unit = m[2].toLowerCase();
	const ms = n * { ms: 1, s: 1e3, m: 6e4, h: 36e5, d: 864e5 }[unit];
	// setTimeout silently clamps to 1ms when the delay > 2^31-1, which would
	// turn the loop into a busy poller. Reject anything below 1s or above the
	// ~24.8d setTimeout ceiling.
	if (ms < 1000) {
		throw new Error(`duration '${v}' is below the 1s minimum`);
	}
	if (ms > 2_147_483_647) {
		throw new Error(`duration '${v}' exceeds the ~24.8d maximum`);
	}
	return ms;
};

const DEFAULT_INTERVAL = '1d';
let checkIntervalMs;
let checkIntervalDisplay;
try {
	checkIntervalMs = parseDurationMs(checkIntervalRaw);
	checkIntervalDisplay = checkIntervalRaw;
} catch (e) {
	err(`Invalid SUPERVISOR_CHECK_INTERVAL='${checkIntervalRaw}': ${e.message}. Falling back to ${DEFAULT_INTERVAL}.`);
	checkIntervalMs = parseDurationMs(DEFAULT_INTERVAL);
	checkIntervalDisplay = DEFAULT_INTERVAL;
}

const balena = getSdk({ apiUrl, dataDirectory: '/tmp/work' });

const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const stripV = (s) => String(s || '').replace(/^v/i, '');

const getCpuArch = async (uuid) => {
	const device = await balena.models.device.get(uuid, {
		$expand: { is_of__device_type: { $select: 'slug' } },
	});
	const dtSlug = Array.isArray(device.is_of__device_type)
		? device.is_of__device_type[0]?.slug
		: undefined;
	if (!dtSlug) {
		throw new Error(`Could not resolve device-type slug for ${uuid}`);
	}
	const dt = await balena.models.deviceType.getBySlugOrName(dtSlug, {
		$select: 'slug',
		$expand: { is_of__cpu_architecture: { $select: 'slug' } },
	});
	const arch = Array.isArray(dt.is_of__cpu_architecture)
		? dt.is_of__cpu_architecture[0]?.slug
		: undefined;
	if (!arch) {
		throw new Error(`Could not resolve CPU architecture for device-type ${dtSlug}`);
	}
	return { dtSlug, arch };
};

const getCurrentSupervisorVersion = async (uuid) => {
	const device = await balena.models.device.get(uuid, {
		$select: ['supervisor_version'],
	});
	return stripV(device.supervisor_version || '');
};

// Segment-aware match: '16.8.2' matches only the exact '16.8.2' (not
// '16.8.20'), and '16.8' matches '16.8.x' (not '16.80.x' or '16.81.x').
const matchesTargetVersion = (raw, wanted) =>
	raw === wanted || raw.startsWith(wanted + '.');

const resolveTargetVersion = async (arch) => {
	const releases = await balena.models.os.getSupervisorReleasesForCpuArchitecture(
		arch,
		{ $select: ['id', 'raw_version'] },
	);
	if (!releases.length) {
		return null;
	}
	if (['latest', 'recommended'].includes(userTargetVersion.toLowerCase())) {
		return stripV(releases[0].raw_version);
	}
	const wanted = stripV(userTargetVersion);
	const match = releases.find((r) => matchesTargetVersion(stripV(r.raw_version), wanted));
	return match ? stripV(match.raw_version) : null;
};

// SDK 20.x exposes setSupervisorRelease; SDK 23+ renamed it to
// pinToSupervisorRelease and dropped the old name. Pick whichever exists so a
// future balena-sdk bump doesn't silently break.
const pinSupervisor = async (uuid, version) => {
	const fn =
		balena.models.device.pinToSupervisorRelease ||
		balena.models.device.setSupervisorRelease;
	if (typeof fn !== 'function') {
		throw new Error('balena-sdk has neither pinToSupervisorRelease nor setSupervisorRelease');
	}
	return fn.call(balena.models.device, uuid, version);
};

const tick = async () => {
	if (userTargetVersion === '') {
		log("SUPERVISOR_TARGET_VERSION not set; skipping. (Set to 'latest' or e.g. '16.8.2' to enable.)");
		return;
	}

	await balena.auth.loginWithToken(apiKey);

	while (!(await balena.models.device.isOnline(deviceUuid))) {
		log('Device is offline...');
		await delay(120_000);
	}

	const { dtSlug, arch } = await getCpuArch(deviceUuid);
	const currentVersion = await getCurrentSupervisorVersion(deviceUuid);
	log(`Current supervisor: ${currentVersion || '(unknown)'} (device type ${dtSlug}, arch ${arch})`);

	const targetVersion = await resolveTargetVersion(arch);
	if (!targetVersion) {
		log(`No supervisor release matching '${userTargetVersion}' found for ${arch}.`);
		return;
	}

	if (currentVersion === targetVersion) {
		log(`Already on target supervisor ${targetVersion}.`);
		return;
	}

	log(`Setting target supervisor release ${targetVersion} (current ${currentVersion || 'unknown'})...`);
	await pinSupervisor(deviceUuid, targetVersion);
	log('Target set. On-device updater applies it on next poll (15min after boot, then every 24h).');
};

const main = async () => {
	while (true) {
		try {
			await tick();
		} catch (e) {
			err('Error in loop:', e?.message || e);
		}
		log(`Will check again in ${checkIntervalDisplay}.`);
		await delay(checkIntervalMs);
	}
};

log('Starting up...');
main().catch((e) => {
	err('Fatal:', e);
	process.exit(1);
});
