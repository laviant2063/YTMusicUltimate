#pragma once

#include <stdbool.h>
#include <stdint.h>

typedef struct {
    double red;
    double green;
    double blue;
} YTMUOfflinePaletteColor;

double YTMUOfflineMiniPlayerHeight(bool sessionActive, bool hasCurrentTrack);
YTMUOfflinePaletteColor YTMUOfflineDarkPaletteColor(uint8_t red, uint8_t green, uint8_t blue);
