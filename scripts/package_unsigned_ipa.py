#!/usr/bin/env python3
"""Validate a real iPhone archive and package it for the owner's separate signing step."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import stat
import struct
import zipfile


def validate_app(app):
    with (app / 'Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    if info.get('DTPlatformName') != 'iphoneos' or info.get('CFBundleSupportedPlatforms') != ['iPhoneOS']:
        raise ValueError('Refusing to package a simulator or unknown-platform application as an iPhone IPA')
    executable_name = info.get('CFBundleExecutable', '')
    if not executable_name or Path(executable_name).name != executable_name:
        raise ValueError('Invalid bundle executable name')
    binary = (app / executable_name).read_bytes()
    if len(binary) < 32:
        raise ValueError('Missing Mach-O header')
    magic, cpu, _, filetype, commands, command_bytes, _, _ = struct.unpack_from('<8I', binary)
    if magic != 0xFEEDFACF or cpu != 0x0100000C or filetype != 2:
        raise ValueError('Expected an arm64 iPhone Mach-O executable')
    if 32 + command_bytes > len(binary):
        raise ValueError('Truncated Mach-O load commands')
    platforms = []
    cursor = 32
    for _ in range(commands):
        if cursor + 8 > 32 + command_bytes:
            raise ValueError('Invalid load-command boundary')
        command, size = struct.unpack_from('<II', binary, cursor)
        if size < 8 or cursor + size > 32 + command_bytes:
            raise ValueError('Invalid Mach-O load-command size')
        if command == 0x32:
            if size < 24:
                raise ValueError('Invalid LC_BUILD_VERSION command')
            platforms.append(struct.unpack_from('<I', binary, cursor + 8)[0])
        cursor += size
    if cursor != 32 + command_bytes or platforms != [2]:
        raise ValueError('Executable is not built for the iOS device platform')
    if (app / 'embedded.mobileprovision').exists() or (app / '_CodeSignature').exists():
        raise ValueError('Expected an unsigned archive without a distribution profile/resource seal')
    return info


def package(app, destination):
    app = app.resolve(strict=True)
    if not app.is_dir() or app.suffix != '.app':
        raise ValueError('Input must be an archived .app directory')
    info = validate_app(app)
    destination = destination.resolve()
    if destination.is_relative_to(app):
        raise ValueError('Output cannot be inside the application bundle')
    destination.parent.mkdir(parents=True, exist_ok=True)
    prefix = Path('Payload') / app.name
    with zipfile.ZipFile(destination, 'w', zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(app.rglob('*')):
            name = (prefix / path.relative_to(app)).as_posix()
            if path.is_symlink():
                if not path.resolve().is_relative_to(app):
                    raise ValueError('Refusing a bundle symlink outside the application')
                entry = zipfile.ZipInfo(name)
                entry.create_system = 3
                entry.external_attr = (stat.S_IFLNK | 0o777) << 16
                archive.writestr(entry, os.readlink(path))
            elif path.is_file():
                archive.write(path, name)
    with zipfile.ZipFile(destination) as archive:
        if archive.testzip() is not None:
            raise ValueError('IPA integrity check failed')
        executable_path = (prefix / info['CFBundleExecutable']).as_posix()
        if not (archive.getinfo(executable_path).external_attr >> 16) & stat.S_IXUSR:
            raise ValueError('Bundle executable lost its executable permission')
    summary = {
        'artifact': destination.name,
        'platform': 'iPhoneOS',
        'architecture': 'arm64',
        'signed_for_installation': False,
        'bundle_id': info.get('CFBundleIdentifier'),
        'version': info.get('CFBundleShortVersionString'),
        'build': info.get('CFBundleVersion'),
        'minimum_ios': info.get('MinimumOSVersion'),
        'sha256': hashlib.sha256(destination.read_bytes()).hexdigest(),
        'bytes': destination.stat().st_size,
    }
    destination.with_suffix('.json').write_text(json.dumps(summary, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(summary, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    package(args.app, args.output)
