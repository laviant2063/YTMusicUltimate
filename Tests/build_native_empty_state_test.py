"""Test the real native adapter's empty-state lifecycle without a UIKit host.

Only native layout execution and the host's controllers are test doubles. The
runtime getter checks, observation scheduling and generation guards are copied
verbatim from production, including the pre-fix scheduler for RED verification.
"""

from pathlib import Path
import re
import sys


source_path, fixture_path, output_path = map(Path, sys.argv[1:])
source = source_path.read_text(encoding="utf-8")
interface = source.split("@interface YTMUNativePlaybackAdapter ()", 1)[1].split("@end", 1)[0]
implementation = source.split("@implementation YTMUNativePlaybackAdapter", 1)[1].split("@end", 1)[0]
properties = "\n".join(line for line in interface.splitlines() if line.startswith("@property"))
required = {
    "initPrivate", "performOnMainSynchronously",
    "scheduleNativeMiniPlayerVisualShellReassertionIfNeeded",
    "registerPlayerViewController", "registerWatchViewController",
    "registerMiniPlayerViewController", "setNativeMiniPlayerSuppressed",
    "prepareNativeMiniPlayerForPlaybackStart", "nativePlaybackDidStart",
    "nativePlaybackDidPause", "nativePlaybackSessionDidEnd",
    "nativeMiniPlayerLayoutErrorWithCode",
    "nativeMiniPlayerVisualShellViewsForWatchView",
}
optional = {
    "dealloc", "nativeMiniPlayerContentState",
    "reconcileNativeMiniPlayerEmptyState",
    "nativeMiniPlayerEnvironmentDidChange",
}
starts = list(re.finditer(r"^-\s*\([^\n]+?\)\s*(\w+)", implementation, re.MULTILINE))
methods = []
found = set()
for index, match in enumerate(starts):
    name = match.group(1)
    if name not in required | optional:
        continue
    end = starts[index + 1].start() if index + 1 < len(starts) else len(implementation)
    methods.append(implementation[match.start():end].strip())
    found.add(name)
if required - found:
    raise SystemExit(f"Required production methods missing: {sorted(required - found)}")

helpers = ""
start_marker = "// BEGIN native empty-state observation helpers"
end_marker = "// END native empty-state observation helpers"
if start_marker in source:
    helpers = source.split(start_marker, 1)[1].split(end_marker, 1)[0]
declarations = "\n".join(method.split("{", 1)[0].strip() + ";" for method in methods)
adapter = f"""
{helpers}
@class YTMUNativeMiniPlayerSnapshot;
@interface YTMUNativePlaybackAdapter : NSObject
{properties}
@property (nonatomic) NSUInteger testCollapseCount;
@property (nonatomic) BOOL testGeometryCollapsed;
@property (nonatomic) BOOL testLayoutSucceeds;
{declarations}
- (void)applyMiniPlayerSuppressionToController:(UIViewController *)controller;
- (BOOL)collapseNativeMiniPlayerVisualShellAfterConfirmedSessionEnd:(NSError **)error;
- (BOOL)nativeMiniPlayerVisualShellIsGeometricallyCollapsed:(NSError **)error;
@end

@implementation YTMUNativePlaybackAdapter
{chr(10).join(methods)}
- (void)applyMiniPlayerSuppressionToController:(__unused UIViewController *)controller {{}}
- (BOOL)nativeMiniPlayerVisualShellIsGeometricallyCollapsed:(__unused NSError **)error {{
    return self.testGeometryCollapsed;
}}
- (BOOL)collapseNativeMiniPlayerVisualShellAfterConfirmedSessionEnd:(__unused NSError **)error {{
    if (YTMUPlaybackCoordinator.sharedCoordinator.owner != YTMUPlaybackOwnerNone
        || self.nativePlaybackAudible || self.miniPlayerSuppressed) return NO;
    self.testCollapseCount++;
    if (!self.testLayoutSucceeds) return NO;
    self.testGeometryCollapsed = YES;
    self.nativeMiniPlayerVisualShellCollapsed = YES;
    return YES;
}}
@end
"""
fixture = fixture_path.read_text(encoding="utf-8")
marker = "/* YTMU_PRODUCTION_EMPTY_STATE_ADAPTER */"
if fixture.count(marker) != 1:
    raise SystemExit("Expected one production-adapter insertion point")
output_path.write_text(fixture.replace(marker, adapter), encoding="utf-8")
print(f"Native empty-state harness: {len(methods)} production methods; no UIKit rendering")
