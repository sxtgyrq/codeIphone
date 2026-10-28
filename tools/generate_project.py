"""Generate a dependency-free Xcode project on Windows or macOS (Python 3)."""
from pathlib import Path
import hashlib
import os
from datetime import datetime, timezone, timedelta
import json
import plistlib
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
NAME = "HelloYrq"
objects = {}


def oid(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()


def obj(object_key, isa, **fields):
    key = oid(object_key)
    objects[key] = dict(isa=isa, **fields)
    return key


def settings(name, values):
    return obj(name, "XCBuildConfiguration", buildSettings=values, name=name.split("/")[-1])


def configs(name, values):
    ids = []
    for mode in ("Debug", "Release"):
        s = dict(values)
        if name == "project":
            s.update(SWIFT_OPTIMIZATION_LEVEL="-Onone" if mode == "Debug" else "-O",
                     DEBUG_INFORMATION_FORMAT="dwarf" if mode == "Debug" else "dwarf-with-dsym")
            if mode == "Debug":
                s["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "DEBUG $(inherited)"
        ids.append(settings(name + "/" + mode, s))
    return obj(name + "/configs", "XCConfigurationList", buildConfigurations=ids,
               defaultConfigurationIsVisible="0", defaultConfigurationName="Release")


def file(name, path, kind):
    return obj(name, "PBXFileReference", lastKnownFileType=kind, path=path, sourceTree="<group>")


def buildfile(name, ref):
    return obj(name, "PBXBuildFile", fileRef=ref)


def phase(name, isa, files=()):
    return obj(name, isa, buildActionMask="2147483647", files=list(files), runOnlyForDeploymentPostprocessing="0")


def swift_sources(folder, key):
    """Stable references for all checked-in Swift sources, including subfolders."""
    paths = sorted((ROOT / folder).rglob("*.swift"))
    refs = []
    builds = []
    for path in paths:
        relative = path.relative_to(ROOT / folder).as_posix()
        ref = file(key + "/source/" + relative, relative, "sourcecode.swift")
        refs.append(ref)
        builds.append(buildfile(key + "/build/" + relative, ref))
    return refs, builds


def emit(value, depth=0):
    tab = "\t" * depth
    if isinstance(value, dict):
        return "{\n" + "".join(tab + "\t" + json.dumps(str(k)) + " = " + emit(v, depth + 1) + ";\n" for k, v in value.items()) + tab + "}"
    if isinstance(value, list):
        return "(\n" + "".join(tab + "\t" + emit(v, depth + 1) + ",\n" for v in value) + tab + ")"
    return json.dumps(str(value), ensure_ascii=False)


def main():
    objects.clear()
    release_date = os.environ.get("RELEASE_DATE") or datetime.now(timezone(timedelta(hours=8))).strftime("%Y.%m.%d")
    datetime.strptime(release_date, "%Y.%m.%d")
    app_sources, app_builds = swift_sources(NAME, "app")
    unit_sources, unit_builds = swift_sources(NAME + "Tests", "unit")
    test_sources, test_builds = swift_sources(NAME + "UITests", "test")
    app_info = file("app/info", "Info.plist", "text.plist.xml")
    app_assets = file("app/assets", "Assets.xcassets", "folder.assetcatalog")
    extra_resources = []
    guide_refs = []
    if (ROOT / NAME / "FlowDiagramLanguage.md").exists():
        guide = file("app/flow-guide", "FlowDiagramLanguage.md", "net.daringfireball.markdown")
        guide_refs.append(guide)
        extra_resources.append(buildfile("app/build-flow-guide", guide))
    product = obj("app/product", "PBXFileReference", explicitFileType="wrapper.application",
                  includeInIndex="0", path=NAME + ".app", sourceTree="BUILT_PRODUCTS_DIR")
    test_product = obj("test/product", "PBXFileReference", explicitFileType="wrapper.cfbundle",
                       includeInIndex="0", path=NAME + "UITests.xctest", sourceTree="BUILT_PRODUCTS_DIR")
    unit_product = obj("unit/product", "PBXFileReference", explicitFileType="wrapper.cfbundle",
                       includeInIndex="0", path=NAME + "Tests.xctest", sourceTree="BUILT_PRODUCTS_DIR")
    products = obj("products", "PBXGroup", children=[product, unit_product, test_product], name="Products", sourceTree="<group>")
    app_group = obj("app/group", "PBXGroup", children=[*app_sources, app_info, app_assets, *guide_refs], path=NAME, sourceTree="<group>")
    unit_group = obj("unit/group", "PBXGroup", children=unit_sources, path=NAME + "Tests", sourceTree="<group>")
    test_group = obj("test/group", "PBXGroup", children=test_sources, path=NAME + "UITests", sourceTree="<group>")
    root_group = obj("main/group", "PBXGroup", children=[app_group, unit_group, test_group, products], sourceTree="<group>")

    base = dict(CLANG_ENABLE_MODULES="YES", CLANG_ENABLE_OBJC_ARC="YES", SDKROOT="iphoneos",
                IPHONEOS_DEPLOYMENT_TARGET="16.0", SWIFT_VERSION="5.0", ENABLE_TESTABILITY="YES")
    project_configs = configs("project", base)
    common = dict(PRODUCT_NAME="$(TARGET_NAME)", CODE_SIGN_STYLE="Automatic", TARGETED_DEVICE_FAMILY="1",
                  SUPPORTED_PLATFORMS="iphoneos iphonesimulator", SUPPORTS_MACCATALYST="NO",
                  SWIFT_EMIT_LOC_STRINGS="YES")
    app_settings = dict(common, PRODUCT_BUNDLE_IDENTIFIER="com.yaoruiqing.helloyrq",
                        INFOPLIST_FILE=NAME + "/Info.plist", ASSETCATALOG_COMPILER_APPICON_NAME="AppIcon",
                        GENERATE_INFOPLIST_FILE="NO", CURRENT_PROJECT_VERSION="1", MARKETING_VERSION=release_date,
                        LD_RUNPATH_SEARCH_PATHS=["$(inherited)", "@executable_path/Frameworks"])
    app_target = obj("app/target", "PBXNativeTarget", buildConfigurationList=configs("app", app_settings),
                     buildPhases=[phase("app/sources", "PBXSourcesBuildPhase", app_builds),
                                  phase("app/frameworks", "PBXFrameworksBuildPhase"),
                                  phase("app/resources", "PBXResourcesBuildPhase", [buildfile("app/build-assets", app_assets), *extra_resources])],
                     buildRules=[], dependencies=[], name=NAME, productName=NAME,
                     productReference=product, productType="com.apple.product-type.application")
    project_id = oid("project/root")
    proxy = obj("test/proxy", "PBXContainerItemProxy", containerPortal=project_id, proxyType="1",
                remoteGlobalIDString=app_target, remoteInfo=NAME)
    dependency = obj("test/dependency", "PBXTargetDependency", target=app_target, targetProxy=proxy)
    unit_proxy = obj("unit/proxy", "PBXContainerItemProxy", containerPortal=project_id, proxyType="1",
                     remoteGlobalIDString=app_target, remoteInfo=NAME)
    unit_dependency = obj("unit/dependency", "PBXTargetDependency", target=app_target, targetProxy=unit_proxy)
    unit_settings = dict(common, PRODUCT_BUNDLE_IDENTIFIER="com.yaoruiqing.helloyrq.tests",
                         GENERATE_INFOPLIST_FILE="YES", BUNDLE_LOADER="$(TEST_HOST)",
                         TEST_HOST="$(BUILT_PRODUCTS_DIR)/HelloYrq.app/HelloYrq",
                         LD_RUNPATH_SEARCH_PATHS=["$(inherited)", "@executable_path/Frameworks", "@loader_path/Frameworks"])
    unit_target = obj("unit/target", "PBXNativeTarget", buildConfigurationList=configs("unit", unit_settings),
                      buildPhases=[phase("unit/sources", "PBXSourcesBuildPhase", unit_builds),
                                   phase("unit/frameworks", "PBXFrameworksBuildPhase"),
                                   phase("unit/resources", "PBXResourcesBuildPhase")],
                      buildRules=[], dependencies=[unit_dependency], name=NAME + "Tests", productName=NAME + "Tests",
                      productReference=unit_product, productType="com.apple.product-type.bundle.unit-test")
    test_settings = dict(common, PRODUCT_BUNDLE_IDENTIFIER="com.yaoruiqing.helloyrq.uitests",
                         GENERATE_INFOPLIST_FILE="YES", TEST_TARGET_NAME=NAME)
    test_target = obj("test/target", "PBXNativeTarget", buildConfigurationList=configs("test", test_settings),
                      buildPhases=[phase("test/sources", "PBXSourcesBuildPhase", test_builds),
                                   phase("test/frameworks", "PBXFrameworksBuildPhase"),
                                   phase("test/resources", "PBXResourcesBuildPhase")],
                      buildRules=[], dependencies=[dependency], name=NAME + "UITests", productName=NAME + "UITests",
                      productReference=test_product, productType="com.apple.product-type.bundle.ui-testing")
    obj("project/root", "PBXProject", attributes={"BuildIndependentTargetsInParallel": "YES", "LastUpgradeCheck": "1600",
         "TargetAttributes": {app_target: {"CreatedOnToolsVersion": "16.0"},
                              unit_target: {"CreatedOnToolsVersion": "16.0", "TestTargetID": app_target},
                              test_target: {"CreatedOnToolsVersion": "16.0", "TestTargetID": app_target}}},
        buildConfigurationList=project_configs, compatibilityVersion="Xcode 14.0", developmentRegion="zh-Hans",
        hasScannedForEncodings="0", knownRegions=["en", "Base", "zh-Hans"], mainGroup=root_group,
        productRefGroup=products, projectDirPath="", projectRoot="", targets=[app_target, unit_target, test_target])
    out = ROOT / (NAME + ".xcodeproj")
    out.mkdir(exist_ok=True)
    (out / "project.pbxproj").write_text("// !$*UTF8*$!\n" + emit(dict(archiveVersion="1", classes={}, objectVersion="56",
        objects=objects, rootObject=project_id)) + "\n", encoding="utf-8", newline="\n")
    scheme = ET.Element("Scheme", LastUpgradeVersion="1600", version="1.3")
    target_names = {app_target: NAME, unit_target: NAME + "Tests", test_target: NAME + "UITests"}
    def reference(parent, target, build_name):
        ET.SubElement(parent, "BuildableReference", BuildableIdentifier="primary", BlueprintIdentifier=target,
                      BuildableName=build_name, BlueprintName=target_names[target],
                      ReferencedContainer="container:" + NAME + ".xcodeproj")
    build = ET.SubElement(scheme, "BuildAction", parallelizeBuildables="YES", buildImplicitDependencies="YES")
    entries = ET.SubElement(build, "BuildActionEntries")
    entry = ET.SubElement(entries, "BuildActionEntry", buildForTesting="YES", buildForRunning="YES",
                          buildForProfiling="YES", buildForArchiving="YES", buildForAnalyzing="YES")
    reference(entry, app_target, NAME + ".app")
    for target, build_name in ((unit_target, NAME + "Tests.xctest"), (test_target, NAME + "UITests.xctest")):
        test_entry = ET.SubElement(entries, "BuildActionEntry", buildForTesting="YES", buildForRunning="NO",
                                  buildForProfiling="NO", buildForArchiving="NO", buildForAnalyzing="YES")
        reference(test_entry, target, build_name)
    test = ET.SubElement(scheme, "TestAction", buildConfiguration="Debug", selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB",
                         selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB", shouldUseLaunchSchemeArgsEnv="YES")
    testables = ET.SubElement(test, "Testables")
    reference(ET.SubElement(testables, "TestableReference", skipped="NO", parallelizable="NO"), unit_target, NAME + "Tests.xctest")
    reference(ET.SubElement(testables, "TestableReference", skipped="NO"), test_target, NAME + "UITests.xctest")
    launch = ET.SubElement(scheme, "LaunchAction", buildConfiguration="Debug", selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB",
                           selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB", launchStyle="0",
                           useCustomWorkingDirectory="NO", ignoresPersistentStateOnLaunch="NO", debugDocumentVersioning="YES",
                           debugServiceExtension="internal", allowLocationSimulation="YES")
    reference(ET.SubElement(launch, "BuildableProductRunnable", runnableDebuggingMode="0"), app_target, NAME + ".app")
    profile = ET.SubElement(scheme, "ProfileAction", buildConfiguration="Release", shouldUseLaunchSchemeArgsEnv="YES",
                            savedToolIdentifier="", useCustomWorkingDirectory="NO", debugDocumentVersioning="YES")
    reference(ET.SubElement(profile, "BuildableProductRunnable", runnableDebuggingMode="0"), app_target, NAME + ".app")
    ET.SubElement(scheme, "AnalyzeAction", buildConfiguration="Debug")
    ET.SubElement(scheme, "ArchiveAction", buildConfiguration="Release", revealArchiveInOrganizer="YES")
    schemes = out / "xcshareddata" / "xcschemes"
    schemes.mkdir(parents=True, exist_ok=True)
    ET.indent(scheme)
    ET.ElementTree(scheme).write(schemes / (NAME + ".xcscheme"), encoding="utf-8", xml_declaration=True)
    with (ROOT / NAME / "Info.plist").open("wb") as f:
        plistlib.dump({"CFBundleDevelopmentRegion": "zh-Hans", "CFBundleDisplayName": "Argument Map",
                      "CFBundleExecutable": "$(EXECUTABLE_NAME)", "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
                      "CFBundleInfoDictionaryVersion": "6.0", "CFBundleName": "$(PRODUCT_NAME)", "CFBundlePackageType": "APPL",
                      "CFBundleShortVersionString": "$(MARKETING_VERSION)", "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                      "ArgumentMapReleaseDate": release_date,
                      "LSRequiresIPhoneOS": True, "UILaunchScreen": {},
                      "NSLocalNetworkUsageDescription": "连接同一局域网中的 ArgumentMap Server，登录、查看与编辑逻辑地图。",
                      # Apple supports IP/CIDR ATS exceptions on iOS 17+. iOS 16
                      # permits local IP loads; keep global internet ATS intact.
                      # https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsexceptiondomains
                      "NSAppTransportSecurity": {
                          "NSAllowsLocalNetworking": True,
                          "NSExceptionDomains": {network: {"NSExceptionAllowsInsecureHTTPLoads": True}
                                                 for network in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16")}},
                      "UIApplicationSceneManifest": {"UIApplicationSupportsMultipleScenes": False},
                      "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationLandscapeLeft",
                                                           "UIInterfaceOrientationLandscapeRight"]}, f, sort_keys=False)
    print("Generated HelloYrq.xcodeproj")


if __name__ == "__main__":
    main()
