#import "YTMUOfflinePlayerVisualPolicy.h"

#include <math.h>

double YTMUOfflineMiniPlayerHeight(bool sessionActive, bool hasCurrentTrack) {
    return sessionActive && hasCurrentTrack ? 82.0 : 0.0;
}

YTMUOfflinePaletteColor YTMUOfflineDarkPaletteColor(uint8_t red, uint8_t green, uint8_t blue) {
    double normalizedRed = red / 255.0;
    double normalizedGreen = green / 255.0;
    double normalizedBlue = blue / 255.0;
    double maximum = fmax(normalizedRed, fmax(normalizedGreen, normalizedBlue));
    if (maximum < 0.08) {
        return (YTMUOfflinePaletteColor){.red = 0.055, .green = 0.065, .blue = 0.10};
    }
    return (YTMUOfflinePaletteColor){
        .red = fmin(0.30, normalizedRed * 0.42),
        .green = fmin(0.30, normalizedGreen * 0.42),
        .blue = fmin(0.34, normalizedBlue * 0.47),
    };
}

double YTMUOfflinePaletteLuminance(YTMUOfflinePaletteColor color) {
    return color.red * 0.2126 + color.green * 0.7152 + color.blue * 0.0722;
}
