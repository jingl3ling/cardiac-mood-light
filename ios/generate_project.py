#!/usr/bin/env python3
"""Writes CardiacMood.xcodeproj/project.pbxproj using ../uids.txt identifiers."""

from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
uids = Path(ROOT / "uids.txt").read_text().strip().split()

# Apple Developer Team ID (10 chars). Both iOS + Watch must match for embedded Watch apps.
DEV_TEAM = "877MZL68G8"

# False: CardiacMood scheme builds only the iOS app (faster iteration; no Watch in the IPA).
# True: Watch app is a dependency and is embedded (restore before shipping a companion Watch build).
EMBED_WATCH_IN_IOS_APP = False
it = iter(uids)


def U() -> str:
    return next(it)


PJ = U()
GR = U()
PRODUCTS = U()
IOS_GROUP = U()
WATCH_GROUP = U()
IOS_APP_R = U()
WATCH_APP_R = U()
TARGET_IOS = U()
TARGET_WATCH = U()
IOS_FW = U()
WATCH_FW = U()
IOS_SRC = U()
WATCH_SRC = U()
IOS_RES = U()
WATCH_RES = U()
EMB_PHASE = U()
PROXY = U()
TGT_DEP = U()

F_ios_app = U()
F_ios_cv = U()
F_ios_cfg = U()
F_ios_api = U()
F_ios_hr = U()
F_ios_mood = U()
F_ios_ent = U()

F_w_app = U()
F_w_cv = U()
F_w_cfg = U()
F_w_sender = U()
F_w_buf = U()

BF_ios = [U() for _ in range(6)]
BF_w = [U() for _ in range(5)]
BF_EMB = U()

XC_PD = U()
XC_PR = U()
XC_IOS_D = U()
XC_IOS_R = U()
XC_W_D = U()
XC_W_R = U()
LIST_P = U()
LIST_I = U()
LIST_W = U()

txt: list[str] = []


def ln(s: str = "") -> None:
    txt.append(s)


IOS_FILES = [
    (F_ios_app, BF_ios[0], "CardiacMoodApp.swift"),
    (F_ios_cv, BF_ios[1], "ContentView.swift"),
    (F_ios_cfg, BF_ios[2], "Config.swift"),
    (F_ios_api, BF_ios[3], "CardiacAPIClient.swift"),
    (F_ios_hr, BF_ios[4], "HealthBaselineReader.swift"),
    (F_ios_mood, BF_ios[5], "MoodHub.swift"),
]
W_FILES = [
    (F_w_app, BF_w[0], "CardiacMoodWatchApp.swift"),
    (F_w_cv, BF_w[1], "ContentView.swift"),
    (F_w_cfg, BF_w[2], "Config.swift"),
    (F_w_sender, BF_w[3], "WatchConnectivitySender.swift"),
    (F_w_buf, BF_w[4], "WorkoutHeartBuffer.swift"),
]


ln("// !$*UTF8*$!")
ln("{")
ln("\tarchiveVersion = 1;")
ln("\tclasses = {};")
ln("\tobjectVersion = 56;")
ln("\tobjects = {")
ln("")

ln("/* Begin PBXBuildFile section */")
for fr, bf, name in IOS_FILES:
    ln(f"\t\t{bf} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {fr} /* {name} */; }};")

for fr, bf, name in W_FILES:
    ln(f"\t\t{bf} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {fr} /* {name} */; }};")

if EMBED_WATCH_IN_IOS_APP:
    ln(f"\t\t{BF_EMB} /* CardiacMoodWatch.app in Embed Watch Content */ = {{isa = PBXBuildFile; fileRef = {WATCH_APP_R} /* CardiacMoodWatch.app */; settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }}; }};")
ln("/* End PBXBuildFile section */")
ln("")
if EMBED_WATCH_IN_IOS_APP:
    ln("/* Begin PBXCopyFilesBuildPhase section */")
    ln(f"\t\t{EMB_PHASE} /* Embed Watch Content */ = {{")
    ln("\t\t\tisa = PBXCopyFilesBuildPhase;")
    ln("\t\t\tbuildActionMask = 2147483647;")
    ln('\t\t\tdstPath = "";')
    ln("\t\t\tdstSubfolderSpec = 16;")
    ln("\t\t\tfiles = (")
    ln(f"\t\t\t\t{BF_EMB} /* CardiacMoodWatch.app in Embed Watch Content */,")
    ln("\t\t\t);")
    ln('\t\t\tname = "Embed Watch Content";')
    ln("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    ln("\t\t};")
    ln("/* End PBXCopyFilesBuildPhase section */")
    ln("")

ln("/* Begin PBXFileReference section */")
ln(f"\t\t{IOS_APP_R} /* CardiacMood.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = CardiacMood.app; sourceTree = BUILT_PRODUCTS_DIR; }};")
ln(f"\t\t{WATCH_APP_R} /* CardiacMoodWatch.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = CardiacMoodWatch.app; sourceTree = BUILT_PRODUCTS_DIR; }};")

for fr, _, name in IOS_FILES:
    ln(f'\t\t{fr} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = "<group>"; }};')

ln(f'\t\t{F_ios_ent} /* CardiacMood.entitlements */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = CardiacMood.entitlements; sourceTree = "<group>"; }};')

for fr, _, name in W_FILES:
    ln(f'\t\t{fr} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = "<group>"; }};')

ln("/* End PBXFileReference section */")
ln("")
ln("/* Begin PBXFrameworksBuildPhase section */")
ln(f"\t\t{IOS_FW} /* Frameworks */ = {{ isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ( ); runOnlyForDeploymentPostprocessing = 0; }};")
ln(f"\t\t{WATCH_FW} /* Frameworks */ = {{ isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ( ); runOnlyForDeploymentPostprocessing = 0; }};")
ln("/* End PBXFrameworksBuildPhase section */")
ln("")

ln("/* Begin PBXGroup section */")
ln(f"\t\t{GR} = {{")
ln('\t\t\tisa = PBXGroup;')
ln("\t\t\tchildren = (")
ln(f"\t\t\t\t{IOS_GROUP} /* CardiacMood */,")
ln(f"\t\t\t\t{WATCH_GROUP} /* CardiacMoodWatch */,")
ln(f"\t\t\t\t{PRODUCTS} /* Products */,")
ln("\t\t\t);")
ln('\t\t\tsourceTree = "<group>";')
ln("\t\t};")

ln(f"\t\t{IOS_GROUP} /* CardiacMood */ = {{")
ln('\t\t\tisa = PBXGroup;')
ln("\t\t\tchildren = (")
ln(f'\t\t\t\t{F_ios_app} /* CardiacMoodApp.swift */,')
ln(f'\t\t\t\t{F_ios_cv} /* ContentView.swift */,')
ln(f'\t\t\t\t{F_ios_cfg} /* Config.swift */,')
ln(f'\t\t\t\t{F_ios_api} /* CardiacAPIClient.swift */,')
ln(f'\t\t\t\t{F_ios_hr} /* HealthBaselineReader.swift */,')
ln(f'\t\t\t\t{F_ios_mood} /* MoodHub.swift */,')
ln(f'\t\t\t\t{F_ios_ent} /* CardiacMood.entitlements */,')
ln("\t\t\t);")
ln('\t\t\tpath = CardiacMood;')
ln('\t\t\tsourceTree = "<group>";')
ln("\t\t};")

ln(f"\t\t{WATCH_GROUP} /* CardiacMoodWatch */ = {{")
ln('\t\t\tisa = PBXGroup;')
ln("\t\t\tchildren = (")
for fr, _, name in W_FILES:
    ln(f"\t\t\t\t{fr} /* {name} */,")
ln("\t\t\t);")
ln('\t\t\tpath = CardiacMoodWatch;')
ln('\t\t\tsourceTree = "<group>";')
ln("\t\t};")

ln(f"\t\t{PRODUCTS} /* Products */ = {{")
ln('\t\t\tisa = PBXGroup;')
ln("\t\t\tchildren = (")
ln(f"\t\t\t\t{IOS_APP_R} /* CardiacMood.app */,")
ln(f"\t\t\t\t{WATCH_APP_R} /* CardiacMoodWatch.app */,")
ln("\t\t\t);")
ln('\t\t\tname = Products;')
ln('\t\t\tsourceTree = "<group>";')
ln("\t\t};")
ln("/* End PBXGroup section */")
ln("")

ln("/* Begin PBXNativeTarget section */")
ln(f"\t\t{TARGET_IOS} /* CardiacMood */ = {{")
ln("\t\t\tisa = PBXNativeTarget;")
ln(f'\t\t\tbuildConfigurationList = {LIST_I} /* Build configuration list for PBXNativeTarget "CardiacMood" */;')
ln("\t\t\tbuildPhases = (")
ln(f"\t\t\t\t{IOS_SRC} /* Sources */,")
ln(f"\t\t\t\t{IOS_FW} /* Frameworks */,")
ln(f"\t\t\t\t{IOS_RES} /* Resources */,")
if EMBED_WATCH_IN_IOS_APP:
    ln(f"\t\t\t\t{EMB_PHASE} /* Embed Watch Content */,")
ln("\t\t\t);")
ln("\t\t\tbuildRules = ( );")
ln("\t\t\tdependencies = (")
if EMBED_WATCH_IN_IOS_APP:
    ln(f"\t\t\t\t{TGT_DEP} /* PBXTargetDependency */,")
ln("\t\t\t);")
ln('\t\t\tname = CardiacMood;')
ln('\t\t\tproductName = CardiacMood;')
ln(f"\t\t\tproductReference = {IOS_APP_R} /* CardiacMood.app */;")
ln('\t\t\tproductType = "com.apple.product-type.application";')
ln("\t\t};")

ln(f"\t\t{TARGET_WATCH} /* CardiacMoodWatch */ = {{")
ln("\t\t\tisa = PBXNativeTarget;")
ln(f'\t\t\tbuildConfigurationList = {LIST_W} /* Build configuration list for PBXNativeTarget "CardiacMoodWatch" */;')
ln("\t\t\tbuildPhases = (")
ln(f"\t\t\t\t{WATCH_SRC} /* Sources */,")
ln(f"\t\t\t\t{WATCH_FW} /* Frameworks */,")
ln(f"\t\t\t\t{WATCH_RES} /* Resources */,")
ln("\t\t\t);")
ln("\t\t\tbuildRules = ( );")
ln("\t\t\tdependencies = ( );")
ln('\t\t\tname = CardiacMoodWatch;')
ln('\t\t\tproductName = CardiacMoodWatch;')
ln(f"\t\t\tproductReference = {WATCH_APP_R} /* CardiacMoodWatch.app */;")
ln('\t\t\tproductType = "com.apple.product-type.application";')
ln("\t\t};")
ln("/* End PBXNativeTarget section */")
ln("")

ln("/* Begin PBXProject section */")
ln(f"\t\t{PJ} /* Project object */ = {{")
ln("\t\t\tisa = PBXProject;")
ln("\t\t\tattributes = {")
ln("\t\t\t\tBuildIndependentTargetsInParallel = 1;")
ln("\t\t\t\tLastSwiftUpdateCheck = 1520; LastUpgradeCheck = 1520;")
ln("\t\t\t\tTargetAttributes = {")
ln(
    f"\t\t\t\t\t{TARGET_IOS} = {{ CreatedOnToolsVersion = 15.2; DevelopmentTeam = {DEV_TEAM}; ProvisioningStyle = Automatic; }};"
)
ln(
    f"\t\t\t\t\t{TARGET_WATCH} = {{ CreatedOnToolsVersion = 15.2; DevelopmentTeam = {DEV_TEAM}; ProvisioningStyle = Automatic; }};"
)
ln("\t\t\t\t};")
ln("\t\t\t};")
ln(f'\t\t\tbuildConfigurationList = {LIST_P} /* Build configuration list for PBXProject "CardiacMood" */;')
ln('\t\t\tcompatibilityVersion = "Xcode 14.0"; developmentRegion = en;')
ln('\t\t\thasScannedForEncodings = 0; knownRegions = ( en, Base );')
ln(f"\t\t\tmainGroup = {GR};")
ln(f"\t\t\tproductRefGroup = {PRODUCTS} /* Products */;")
ln('\t\t\tprojectDirPath = ""; projectRoot = "";')
ln("\t\t\ttargets = (")
ln(f'\t\t\t\t{TARGET_IOS} /* CardiacMood */,')
ln(f'\t\t\t\t{TARGET_WATCH} /* CardiacMoodWatch */,')
ln("\t\t\t);")
ln("\t\t};")
ln("/* End PBXProject section */")
ln("")

ln("/* Begin PBXResourcesBuildPhase section */")
ln(f"\t\t{IOS_RES} /* Resources */ = {{ isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ( ); runOnlyForDeploymentPostprocessing = 0; }};")
ln(f"\t\t{WATCH_RES} /* Resources */ = {{ isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ( ); runOnlyForDeploymentPostprocessing = 0; }};")
ln("/* End PBXResourcesBuildPhase section */")
ln("")

ln("/* Begin PBXSourcesBuildPhase section */")
ln(f"\t\t{IOS_SRC} /* Sources */ = {{")
ln("\t\t\tisa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (")
for _, bf, name in IOS_FILES:
    ln(f"\t\t\t\t{bf} /* {name} in Sources */,")
ln("\t\t\t); runOnlyForDeploymentPostprocessing = 0; };")

ln(f"\t\t{WATCH_SRC} /* Sources */ = {{")
ln("\t\t\tisa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (")
for _, bf, name in W_FILES:
    ln(f"\t\t\t\t{bf} /* {name} in Sources */,")
ln("\t\t\t); runOnlyForDeploymentPostprocessing = 0; };")
ln("/* End PBXSourcesBuildPhase section */")
ln("")

if EMBED_WATCH_IN_IOS_APP:
    ln("/* Begin PBXTargetDependency section */")
    ln(f"\t\t{TGT_DEP} /* PBXTargetDependency */ = {{ isa = PBXTargetDependency; target = {TARGET_WATCH} /* CardiacMoodWatch */; targetProxy = {PROXY}; }};")
    ln("/* End PBXTargetDependency section */")
    ln("")

    ln("/* Begin PBXContainerItemProxy section */")
    ln(f"\t\t{PROXY} /* PBXContainerItemProxy */ = {{")
    ln(f"\t\t\tisa = PBXContainerItemProxy; containerPortal = {PJ} /* Project object */; proxyType = 1;")
    ln(f"\t\t\tremoteGlobalIDString = {TARGET_WATCH}; remoteInfo = CardiacMoodWatch;")
    ln("\t\t};")
    ln("/* End PBXContainerItemProxy section */")
    ln("")

SHARED_DEBUG = """\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;
\t\t\t\tCLANG_ANALYZER_NONNULL = YES;
\t\t\t\tCLANG_ENABLE_MODULES = YES;
\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;
\t\t\t\tCOPY_PHASE_STRIP = NO;
\t\t\t\tDEBUG_INFORMATION_FORMAT = dwarf;
\t\t\t\tGCC_DYNAMIC_NO_PIC = NO;
\t\t\t\tGCC_OPTIMIZATION_LEVEL = 0;
\t\t\t\tGCC_PREPROCESSOR_DEFINITIONS = ( "DEBUG=1", "$(inherited)" );
\t\t\t\tONLY_ACTIVE_ARCH = YES;
\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;
\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-Onone";
\t\t\t\tSWIFT_VERSION = 5.0;
\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 17.0;
\t\t\t\tWATCHOS_DEPLOYMENT_TARGET = 10.0;"""

SHARED_REL = """\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;
\t\t\t\tCLANG_ANALYZER_NONNULL = YES;
\t\t\t\tCLANG_ENABLE_MODULES = YES;
\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;
\t\t\t\tCOPY_PHASE_STRIP = NO;
\t\t\t\tDEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
\t\t\t\tENABLE_NS_ASSERTIONS = NO;
\t\t\t\tSWIFT_COMPILATION_MODE = wholemodule;
\t\t\t\tSWIFT_VERSION = 5.0;
\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 17.0;
\t\t\t\tWATCHOS_DEPLOYMENT_TARGET = 10.0;"""

IOS_SETTINGS = f"""CODE_SIGN_STYLE = Automatic;
CURRENT_PROJECT_VERSION = 1;
DEVELOPMENT_TEAM = {DEV_TEAM};
GENERATE_INFOPLIST_FILE = YES;
INFOPLIST_KEY_CFBundleDisplayName = "Cardiac Mood";
INFOPLIST_KEY_NSHealthShareUsageDescription = "Reads heart rate and resting heart rate from Health (including Apple Watch) to show your latest BPM on screen and for lamp moods.";
INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES;
INFOPLIST_KEY_UILaunchScreen_Generation = YES;
INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad = "UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";
INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone = "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";
MARKETING_VERSION = 1.0;
PRODUCT_BUNDLE_IDENTIFIER = com.cardiacmood.CardiacMood;
PRODUCT_NAME = "$(TARGET_NAME)";
SDKROOT = iphoneos;
SUPPORTED_PLATFORMS = "iphoneos iphonesimulator";
SUPPORTS_MACCATALYST = NO;
SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD = NO;
TARGETED_DEVICE_FAMILY = "1,2";
SWIFT_EMIT_LOC_STRINGS = YES;
CODE_SIGN_ENTITLEMENTS = CardiacMood/CardiacMood.entitlements;
LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/Frameworks",
				);"""

WATCH_SETTINGS = f"""CODE_SIGN_STYLE = Automatic;
CURRENT_PROJECT_VERSION = 1;
DEVELOPMENT_TEAM = {DEV_TEAM};
GENERATE_INFOPLIST_FILE = YES;
INFOPLIST_KEY_CFBundleDisplayName = "Cardiac Mood";
INFOPLIST_KEY_NSHealthShareUsageDescription = "Reads heart rate while a workout session collects samples for the lamp demo";
INFOPLIST_KEY_UISupportedInterfaceOrientations = "UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown";
INFOPLIST_KEY_WKCompanionAppBundleIdentifier = com.cardiacmood.CardiacMood;
INFOPLIST_KEY_WKRunsIndependentlyCompanionApp = NO;
MARKETING_VERSION = 1.0;
PRODUCT_BUNDLE_IDENTIFIER = com.cardiacmood.CardiacMood.watchkitapp;
PRODUCT_NAME = "$(TARGET_NAME)";
SDKROOT = watchos;
SUPPORTED_PLATFORMS = "watchos watchsimulator";
SKIP_INSTALL = YES;
SWIFT_EMIT_LOC_STRINGS = YES;
TARGETED_DEVICE_FAMILY = 4;
LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/Frameworks",
				);"""

ln("/* Begin XCBuildConfiguration section */")
ln(f"\t\t{XC_PD} /* Debug */ = {{")
ln("\t\t\tisa = XCBuildConfiguration; buildSettings = {")
ln(SHARED_DEBUG)
ln("\t\t\t}; name = Debug; };")

ln(f"\t\t{XC_PR} /* Release */ = {{")
ln("\t\t\tisa = XCBuildConfiguration; buildSettings = {")
ln(SHARED_REL)
ln("\t\t\t}; name = Release; };")

for dbg, xc in [(True, XC_IOS_D), (False, XC_IOS_R)]:
    ln(f"\t\t{xc} /* {'Debug' if dbg else 'Release'} */ = {{")
    ln("\t\t\tisa = XCBuildConfiguration; buildSettings = {")
    for line in IOS_SETTINGS.split("\n"):
        ln("\t\t\t\t" + line)
    ln("\t\t\t};")
    ln(f'\t\t\tname = {"Debug" if dbg else "Release"};')
    ln("\t\t};")

for dbg, xc in [(True, XC_W_D), (False, XC_W_R)]:
    ln(f"\t\t{xc} /* {'Debug' if dbg else 'Release'} */ = {{")
    ln("\t\t\tisa = XCBuildConfiguration; buildSettings = {")
    for line in WATCH_SETTINGS.split("\n"):
        ln("\t\t\t\t" + line)
    ln("\t\t\t};")
    ln(f'\t\t\tname = {"Debug" if dbg else "Release"};')
    ln("\t\t};")

ln("/* End XCBuildConfiguration section */")
ln("")

ln("/* Begin XCConfigurationList section */")
ln(f"\t\t{LIST_P} /* project */ = {{ isa = XCConfigurationList; buildConfigurations = ( {XC_PD} /* Debug */, {XC_PR} /* Release */ ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }};")
ln(f"\t\t{LIST_I} /* ios */ = {{ isa = XCConfigurationList; buildConfigurations = ( {XC_IOS_D} /* Debug */, {XC_IOS_R} /* Release */ ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }};")
ln(f"\t\t{LIST_W} /* watch */ = {{ isa = XCConfigurationList; buildConfigurations = ( {XC_W_D} /* Debug */, {XC_W_R} /* Release */ ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }};")
ln("/* End XCConfigurationList section */")
ln("\t};")
ln(f"\trootObject = {PJ} /* Project object */;")
ln("}")

out_path = Path(__file__).parent / "CardiacMood.xcodeproj" / "project.pbxproj"
out_path.write_text("\n".join(txt))
rest = sum(1 for _ in it)
print("Wrote", out_path, "; unused uids remaining:", rest)
