#!/usr/bin/env python3
"""Generate the deterministic Xcode project. Run from any directory."""
from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "AirPodsTranslator.xcodeproj"
APP = "AirPodsTranslator"


def identifier(name: str) -> str:
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()


def serialize(value, depth=0):
    indent = "\t" * depth
    if isinstance(value, dict):
        lines = ["{"]
        lines.extend(f'{indent}\t{json.dumps(str(k))} = {serialize(v, depth + 1)};' for k, v in value.items())
        return "\n".join(lines + [indent + "}"])
    if isinstance(value, list):
        return "(\n" + "".join(f"{indent}\t{serialize(v, depth + 1)},\n" for v in value) + indent + ")"
    return str(value) if isinstance(value, int) else json.dumps(str(value), ensure_ascii=False)


def generate(bundle_id: str, team: str, build_number: str):
    if not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", bundle_id):
        raise ValueError("Bundle ID must contain dot-separated alphanumeric/hyphen components")
    if team and not re.fullmatch(r"[A-Z0-9]{10}", team):
        raise ValueError("Apple Team ID must have ten uppercase letters/digits")
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", build_number):
        raise ValueError("Build number must have one to three numeric components")
    objects = {}

    def add(object_key, isa, **values):
        key = identifier(object_key)
        objects[key] = {"isa": isa, **values}
        return key

    source_files = sorted((ROOT / "Sources").rglob("*.swift"))
    test_files = sorted((ROOT / "Tests").rglob("*.swift"))
    if not source_files or not test_files:
        raise ValueError("Sources and Tests must both contain Swift files")
    groups = {"Sources": [], "Tests": [], "Resources": []}
    source_builds, test_builds, resource_builds = [], [], []
    for folder, files, builds in (("Sources", source_files, source_builds), ("Tests", test_files, test_builds)):
        for path in files:
            relative = path.relative_to(ROOT).as_posix()
            ref = add(relative, "PBXFileReference", lastKnownFileType="sourcecode.swift", path=relative, sourceTree="SOURCE_ROOT")
            groups[folder].append(ref)
            builds.append(add("build:" + relative, "PBXBuildFile", fileRef=ref))
    for relative, kind in (("Resources/PrivacyInfo.xcprivacy", "text.xml"), ("Resources/Assets.xcassets", "folder.assetcatalog")):
        if not (ROOT / relative).exists():
            continue
        ref = add(relative, "PBXFileReference", lastKnownFileType=kind, path=relative, sourceTree="SOURCE_ROOT")
        groups["Resources"].append(ref)
        resource_builds.append(add("build:" + relative, "PBXBuildFile", fileRef=ref))
    info_ref = add("Info.plist", "PBXFileReference", lastKnownFileType="text.plist.xml", path="Resources/Info.plist", sourceTree="SOURCE_ROOT")
    groups["Resources"].append(info_ref)
    app_product = add("app-product", "PBXFileReference", explicitFileType="wrapper.application", includeInIndex=0, path=APP + ".app", sourceTree="BUILT_PRODUCTS_DIR")
    test_product = add("test-product", "PBXFileReference", explicitFileType="wrapper.cfbundle", includeInIndex=0, path=APP + "Tests.xctest", sourceTree="BUILT_PRODUCTS_DIR")
    product_group = add("products", "PBXGroup", children=[app_product, test_product], name="Products", sourceTree="<group>")
    group_ids = [add("group:" + key, "PBXGroup", children=refs, name=key, sourceTree="<group>") for key, refs in groups.items()]
    main_group = add("main", "PBXGroup", children=group_ids + [product_group], sourceTree="<group>")
    project_id, app_id, test_id = map(identifier, ("project", "app", "test"))

    def phase(name, isa, files):
        return add(name, isa, buildActionMask=2147483647, files=files, runOnlyForDeploymentPostprocessing=0)

    audio_package = add("fluid-package", "XCRemoteSwiftPackageReference", repositoryURL="https://github.com/FluidInference/FluidAudio.git",
                        requirement={"kind": "exactVersion", "version": "0.18.4"})
    audio_product = add("fluid-product", "XCSwiftPackageProductDependency", package=audio_package, productName="FluidAudio")
    audio_link = add("fluid-framework", "PBXBuildFile", productRef=audio_product)
    app_phases = [phase("app-sources", "PBXSourcesBuildPhase", source_builds), phase("app-frameworks", "PBXFrameworksBuildPhase", [audio_link]), phase("app-resources", "PBXResourcesBuildPhase", resource_builds)]
    test_phases = [phase("test-sources", "PBXSourcesBuildPhase", test_builds), phase("test-frameworks", "PBXFrameworksBuildPhase", [])]
    proxy = add("proxy", "PBXContainerItemProxy", containerPortal=project_id, proxyType=1, remoteGlobalIDString=app_id, remoteInfo=APP)
    dependency = add("test-dependency", "PBXTargetDependency", target=app_id, targetProxy=proxy)

    def configurations(kind):
        refs = []
        for name in ("Debug", "Release"):
            settings = {}
            if kind == "project":
                settings = {"IPHONEOS_DEPLOYMENT_TARGET": "26.0", "SDKROOT": "iphoneos", "SWIFT_VERSION": "5.0", "CLANG_ENABLE_MODULES": "YES", "CLANG_ENABLE_OBJC_ARC": "YES", "ENABLE_USER_SCRIPT_SANDBOXING": "YES", "DEBUG_INFORMATION_FORMAT": "dwarf" if name == "Debug" else "dwarf-with-dsym", "SWIFT_OPTIMIZATION_LEVEL": "-Onone" if name == "Debug" else "-O", "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG $(inherited)" if name == "Debug" else "$(inherited)", "ENABLE_TESTABILITY": "YES" if name == "Debug" else "NO"}
                if name == "Debug":
                    # Match SwiftPM's architecture for the selected simulator.
                    settings["ONLY_ACTIVE_ARCH[sdk=iphonesimulator*]"] = "YES"
            else:
                settings = {"PRODUCT_NAME": "$(TARGET_NAME)", "CODE_SIGN_STYLE": "Automatic", "TARGETED_DEVICE_FAMILY": "1", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator", "SUPPORTS_MACCATALYST": "NO", "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD": "NO", "CURRENT_PROJECT_VERSION": build_number, "MARKETING_VERSION": "0.1.11", "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"]}
                if team:
                    settings["DEVELOPMENT_TEAM"] = team
                if kind == "app":
                    settings.update({"PRODUCT_BUNDLE_IDENTIFIER": bundle_id, "PRODUCT_MODULE_NAME": APP, "INFOPLIST_FILE": "Resources/Info.plist", "GENERATE_INFOPLIST_FILE": "NO", "INFOPLIST_KEY_UILaunchScreen_Generation": "YES"})
                    if (ROOT / "Resources/Assets.xcassets/AppIcon.appiconset").exists():
                        settings["ASSETCATALOG_COMPILER_APPICON_NAME"] = "AppIcon"
                else:
                    settings.update({"PRODUCT_BUNDLE_IDENTIFIER": bundle_id + ".tests", "GENERATE_INFOPLIST_FILE": "YES", "TEST_HOST": f"$(BUILT_PRODUCTS_DIR)/{APP}.app/{APP}", "BUNDLE_LOADER": "$(TEST_HOST)"})
            refs.append(add(f"{kind}-{name}", "XCBuildConfiguration", buildSettings=settings, name=name))
        return add(kind + "-configurations", "XCConfigurationList", buildConfigurations=refs, defaultConfigurationIsVisible=0, defaultConfigurationName="Release")

    project_configs = configurations("project")
    app_configs = configurations("app")
    test_configs = configurations("test")
    add("app", "PBXNativeTarget", buildConfigurationList=app_configs, buildPhases=app_phases, buildRules=[], dependencies=[], packageProductDependencies=[audio_product], name=APP, productName=APP, productReference=app_product, productType="com.apple.product-type.application")
    add("test", "PBXNativeTarget", buildConfigurationList=test_configs, buildPhases=test_phases, buildRules=[], dependencies=[dependency], name=APP + "Tests", productName=APP + "Tests", productReference=test_product, productType="com.apple.product-type.bundle.unit-test")
    add("project", "PBXProject", attributes={"BuildIndependentTargetsInParallel": "YES", "LastUpgradeCheck": "2620", "TargetAttributes": {app_id: {"CreatedOnToolsVersion": "26.2"}, test_id: {"CreatedOnToolsVersion": "26.2", "TestTargetID": app_id}}}, buildConfigurationList=project_configs, compatibilityVersion="Xcode 14.0", developmentRegion="zh-Hans", hasScannedForEncodings=0, knownRegions=["zh-Hans", "en", "Base"], mainGroup=main_group, productRefGroup=product_group, projectDirPath="", projectRoot="", targets=[app_id, test_id])
    content = {"archiveVersion": 1, "classes": {}, "objectVersion": 56, "objects": objects, "rootObject": project_id}
    objects[project_id]["packageReferences"] = [audio_package]
    PROJECT.mkdir(parents=True, exist_ok=True)
    (PROJECT / "project.pbxproj").write_text("// !$*UTF8*$!\n" + serialize(content) + "\n", encoding="utf-8")

    def buildable(target_id, product, name):
        return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target_id}" BuildableName="{escape(product)}" BlueprintName="{escape(name)}" ReferencedContainer="container:{APP}.xcodeproj"/>'
    app_ref = buildable(app_id, APP + ".app", APP)
    test_ref = buildable(test_id, APP + "Tests.xctest", APP + "Tests")
    scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2620" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
  <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{app_ref}</BuildActionEntry>
  <BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="NO">{test_ref}</BuildActionEntry>
 </BuildActionEntries></BuildAction>
 <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{test_ref}</TestableReference></Testables></TestAction>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{app_ref}</BuildableProductRunnable></LaunchAction>
 <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{app_ref}</BuildableProductRunnable></ProfileAction>
 <AnalyzeAction buildConfiguration="Debug"/>
 <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
'''
    schemes = PROJECT / "xcshareddata/xcschemes"
    schemes.mkdir(parents=True, exist_ok=True)
    (schemes / f"{APP}.xcscheme").write_text(scheme, encoding="utf-8")
    return content


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle-id", default="com.example.airpodstranslator")
    parser.add_argument("--team", default="")
    parser.add_argument("--build-number", default="1")
    args = parser.parse_args()
    generate(args.bundle_id, args.team, args.build_number)
    print(f"Generated {PROJECT.name} (iOS 26.0+, build SDK 26.2+)")
