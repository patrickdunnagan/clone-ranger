#ifndef BRAWBRIDGE_H
#define BRAWBRIDGE_H
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// One still from a Blackmagic RAW clip, as 8-bit RGBA.
typedef struct {
    uint8_t *rgba;          // width * height * 4 bytes, free with braw_free
    uint32_t width, height; // of the still
    uint32_t clipWidth, clipHeight;
    double duration;        // seconds
    char error[256];
} BRAWStill;

/// True if the Blackmagic RAW library can be loaded from `libDir` (the folder holding BlackmagicRawAPI.framework).
int braw_available(const char *libDir);

/// Decodes the frame `fraction` (0…1) of the way into the clip at about `maxWidth` wide, in Rec.709 so it
/// looks normal rather than flat log. Returns 1 on success; on failure `error` says why.
int braw_grab(const char *libDir, const char *path, double fraction, uint32_t maxWidth, BRAWStill *out);

void braw_free(BRAWStill *still);

/// Test aid: the gamma names this clip accepts, comma-separated, into buf.
int braw_gamma_options(const char *libDir, const char *path, char *buf, int bufSize);

#ifdef __cplusplus
}
#endif
#endif
