#!/usr/bin/env python3
"""Cross-platform structural checks only; NOT a Swift compiler or device test."""
from pathlib import Path
import plistlib
import re
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]


def check(condition, message):
    if not condition:
        raise SystemExit("FAIL: " + message)


def main():
    project = ROOT / 'AirPodsTranslator.xcodeproj/project.pbxproj'
    text = project.read_text(encoding='utf-8')
    # TargetAttributes contains a second keyed occurrence of the app/test IDs.
    object_region = text.split('"objects" = {', 1)[1].rsplit('"rootObject"', 1)[0]
    objects = set(re.findall(r'^\t\t"([A-F0-9]{24})" = \{', object_region, re.M))
    refs = set(re.findall(r'"([A-F0-9]{24})"', text))
    check(objects and refs <= objects, 'all project object references resolve')
    paths = re.findall(r'"path" = "([^"\n]+)";', text)
    actual_sources = {p.relative_to(ROOT).as_posix() for p in (ROOT / 'Sources').rglob('*.swift')}
    actual_tests = {p.relative_to(ROOT).as_posix() for p in (ROOT / 'Tests').rglob('*.swift')}
    check(actual_sources and actual_tests, 'app sources and regression tests exist')
    check(actual_sources | actual_tests <= set(paths), 'all Swift files are in the Xcode project')
    for path in paths:
        if path.endswith(('.app', '.xctest')):
            continue
        check((ROOT / path).exists(), f'file reference exists: {path}')
    scheme = ET.parse(ROOT / 'AirPodsTranslator.xcodeproj/xcshareddata/xcschemes/AirPodsTranslator.xcscheme')
    for buildable in scheme.iter('BuildableReference'):
        check(buildable.attrib['BlueprintIdentifier'] in objects, 'scheme target resolves')
    check(len(list(scheme.iter('TestableReference'))) == 1, 'unit test target enabled in shared scheme')
    with (ROOT / 'Resources/Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    check('audio' in info.get('UIBackgroundModes', []), 'background audio declared')
    for key in ('NSMicrophoneUsageDescription', 'NSSpeechRecognitionUsageDescription'):
        check(bool(info.get(key)), key)
    check('NSAllowsArbitraryLoads' not in str(info), 'no arbitrary networking exception')
    with (ROOT / 'Resources/PrivacyInfo.xcprivacy').open('rb') as stream:
        privacy = plistlib.load(stream)
    check(privacy['NSPrivacyTracking'] is False, 'tracking disabled')
    check('"IPHONEOS_DEPLOYMENT_TARGET" = "26.0"' in text, 'iOS 26.0 deployment baseline')
    check((ROOT / 'codemagic.yaml').is_file(), 'Codemagic configuration present')
    print(f'PASS: structural checks ({len(actual_sources)} Swift source files, {len(actual_tests)} test files, {len(objects)} Xcode objects).')
    print('Swift compilation, XCTest execution, signing and AirPods behavior are NOT verified by this script.')


if __name__ == '__main__':
    main()
