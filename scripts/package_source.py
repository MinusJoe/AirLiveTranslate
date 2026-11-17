#!/usr/bin/env python3
"""Package only this standalone app; never include parent repo, credentials or builds."""
from pathlib import Path
import hashlib
import zipfile

ROOT = Path(__file__).resolve().parents[1]
ALLOWED_TOP = {'Sources', 'Tests', 'Resources', 'scripts', 'docs', 'AirPodsTranslator.xcodeproj'}
ALLOWED_FILES = {'README.md', 'LICENSE', 'Package.swift', 'codemagic.yaml', '.gitignore', '.gitattributes'}
ALLOWED_EXTENSIONS = {'.swift', '.py', '.sh', '.md', '.plist', '.xcprivacy', '.png', '.json', '.pbxproj', '.xcscheme'}


def main():
    destination = ROOT / 'build/AirPodsTranslator-source.zip'
    destination.parent.mkdir(exist_ok=True)
    files = []
    for path in sorted(ROOT.rglob('*')):
        if not path.is_file() or path.is_symlink():
            continue
        relative = path.relative_to(ROOT)
        if any(part in {'__pycache__', 'xcuserdata', '.git'} for part in relative.parts):
            continue
        if relative.as_posix() in ALLOWED_FILES or (relative.parts[0] in ALLOWED_TOP and path.suffix in ALLOWED_EXTENSIONS):
            files.append((path, relative.as_posix()))
    with zipfile.ZipFile(destination, 'w', zipfile.ZIP_DEFLATED) as archive:
        for path, relative in files:
            archive.write(path, relative)
    checksum = hashlib.sha256(destination.read_bytes()).hexdigest()
    destination.with_suffix('.zip.sha256').write_text(f'{checksum}  {destination.name}\n', encoding='utf-8')
    print(f'{destination}\n{len(files)} files; SHA256 {checksum}')


if __name__ == '__main__':
    main()
