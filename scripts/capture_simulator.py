#!/usr/bin/env python3
"""Best-effort native UI screenshot after mandatory tests, with a total deadline."""
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import time


def main():
    preferred, app_path = sys.argv[1:3]
    log_path = Path('build/simulator-launch.log')
    deadline = time.monotonic() + 120
    records = []

    def run(arguments, timeout=30, required=True):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError('120-second capture budget exhausted')
        result = subprocess.run(arguments, capture_output=True, text=True,
                                timeout=min(timeout, remaining))
        records.append('$ ' + ' '.join(arguments) + '\n' + result.stdout + result.stderr)
        if required:
            result.check_returncode()
        return result.stdout

    try:
        devices = json.loads(run(['xcrun', 'simctl', 'list', 'devices', 'available', '--json']))['devices']
        booted = [d['udid'] for entries in devices.values() for d in entries
                  if d.get('state') == 'Booted' and 'iPhone' in d.get('name', '')]
        device = preferred if preferred in booted else (booted[0] if booted else preferred)
        if device not in booted:
            run(['xcrun', 'simctl', 'boot', device], required=False)
        run(['xcrun', 'simctl', 'bootstatus', device, '-b'], timeout=75)
        with (Path(app_path) / 'Info.plist').open('rb') as stream:
            bundle_id = plistlib.load(stream)['CFBundleIdentifier']
        run(['xcrun', 'simctl', 'install', device, app_path])
        run(['xcrun', 'simctl', 'launch', device, bundle_id])
        if deadline - time.monotonic() < 3:
            raise TimeoutError('No time remaining for first frame')
        time.sleep(2)
        run(['xcrun', 'simctl', 'io', device, 'screenshot', 'build/home-simulator.png'])
        records.append('Native simulator screenshot captured. No AirPods or speech-model validation.')
        print(records[-1])
    except (OSError, ValueError, KeyError, TimeoutError, subprocess.SubprocessError) as error:
        records.append('OPTIONAL UI CAPTURE NOT VERIFIED: ' + str(error))
        print('::warning::Optional simulator UI capture did not complete; see simulator-launch.log.')
    finally:
        log_path.parent.mkdir(exist_ok=True)
        log_path.write_text('\n'.join(records), encoding='utf-8')


if __name__ == '__main__':
    main()
