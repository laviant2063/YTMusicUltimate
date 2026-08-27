"""Exercise the real native-card resolver with Foundation host-view doubles.

Unlike the gesture-delegate harness, this does not substitute a successful
visual context. Runtime class/ivar/selector checks and crop/participant decisions
are extracted verbatim from production. This is not a UIKit rendering test.
"""

from pathlib import Path
import sys


source_path, fixture_path, output_path = map(Path, sys.argv[1:])
source = source_path.read_text(encoding="utf-8")


def section(start, end):
    return source.split(start, 1)[1].split(end, 1)[0]


resolver = "\n".join([
    "static BOOL YTMURectsEqualWithinTolerance"
    + section("static BOOL YTMURectsEqualWithinTolerance",
              "static NSString *YTMUNativeViewDiagnostic"),
    "static BOOL YTMUMethodHasEncoding"
    + section("static BOOL YTMUMethodHasEncoding",
              "static UIView *YTMUClosestCommonAncestorForViews"),
    "@interface YTMUNativeMiniPlayerVisualContext"
    + section("@interface YTMUNativeMiniPlayerVisualContext",
              "@interface YTMUNativeMiniPlayerSwipeHandler"),
])
fixture = fixture_path.read_text(encoding="utf-8")
marker = "/* YTMU_PRODUCTION_VISUAL_CONTEXT */"
if fixture.count(marker) != 1:
    raise SystemExit("Expected exactly one production-resolver insertion point")
output_path.write_text(fixture.replace(marker, resolver), encoding="utf-8")
print("Native visual-context harness: actual resolver and runtime checks, no UIKit host")
