#import "YTMUOfflinePlayerVisualPolicy.h"

#include <math.h>

double YTMUOfflineMiniPlayerHeight(bool sessionActive, bool hasCurrentTrack) {
    return sessionActive && hasCurrentTrack ? 78.0 : 0.0;
}

YTMUOfflinePaletteColor YTMUOfflineDarkPaletteColor(uint8_t red, uint8_t green, uint8_t blue) {
    double normalizedRed = red / 255.0;
    double normalizedGreen = green / 255.0;
    double normalizedBlue = blue / 255.0;
    double maximum = fmax(normalizedRed, fmax(normalizedGreen, normalizedBlue));
    if (maximum < 0.12) {
        return (YTMUOfflinePaletteColor){.red = 0.08, .green = 0.08, .blue = 0.11};
    }
    return (YTMUOfflinePaletteColor){
        .red = fmin(0.32, normalizedRed * 0.45),
        .green = fmin(0.32, normalizedGreen * 0.45),
        .blue = fmin(0.36, normalizedBlue * 0.50),
    };
}
