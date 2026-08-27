"""Build a Foundation-only harness from the real swipe-handler state methods.

The lightweight UIView doubles test property ownership, not UIKit rendering.
Production methods are extracted verbatim so the RED test exercises the faulty
callback code instead of a separately reimplemented state machine.
"""

from pathlib import Path
import re
import sys


source_path, fixture_path, output_path = map(Path, sys.argv[1:])
source = source_path.read_text(encoding="utf-8")
interface = source.split("@interface YTMUNativeMiniPlayerSwipeHandler", 1)[1].split("@end", 1)[0]
implementation = source.split("@implementation YTMUNativeMiniPlayerSwipeHandler", 1)[1].split("@end", 1)[0]
properties = "\n".join(line for line in interface.splitlines() if line.startswith("@property"))

required = {
    "prepareForPresentation",
    "coverNativeViews",
    "restoreCoveredNativeViews",
    "discardAnimationSnapshot",
    "restoreVisualRootIncludingNativeState",
    "restoreSwipeAnimated",
    "cancelSwipeForExternalStateChange",
    "nativePlaybackWillStart",
    "playbackOwnershipDidChange",
}
optional = {"restoreOwnedInteraction", "disableInteractionAfterFailedCollapse", "coverConfirmedEmptyShell"}
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

missing = required - found
if missing:
    raise SystemExit(f"Required production methods missing: {sorted(missing)}")

declarations = "\n".join(method.split("{", 1)[0].strip() + ";" for method in methods)
handler = f"""
@interface YTMUNativeMiniPlayerSwipeHandler : NSObject
{properties}
{declarations}
- (void)logVisualState:(NSString *)reason;
@end

@implementation YTMUNativeMiniPlayerSwipeHandler
- (void)logVisualState:(__unused NSString *)reason {{}}
{chr(10).join(methods)}
@end
"""
fixture = fixture_path.read_text(encoding="utf-8")
output_path.write_text(fixture.replace("/* YTMU_PRODUCTION_HANDLER */", handler), encoding="utf-8")
print(f"Native visual-state harness: {len(methods)} production methods, no UIKit host")
