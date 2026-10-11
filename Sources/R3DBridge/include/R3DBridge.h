#ifndef R3DBRIDGE_H
#define R3DBRIDGE_H
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// One still from a RED (or Nikon R3D NE) clip, as 8-bit BGRA.
typedef struct {
    uint8_t *bgra;          // width * height * 4 bytes, free with r3d_free
    uint32_t width, height;
    uint32_t clipWidth, clipHeight;
    double duration;        // seconds
    char error[256];
} R3DStill;

/// True if the R3D library (REDR3D.dylib) loads from `libDir`.
int r3d_available(const char *libDir);

/// Decodes the frame `fraction` (0…1) into the clip at about `maxWidth` wide, Rec.709 / BT.1886.
int r3d_grab(const char *libDir, const char *path, double fraction, uint32_t maxWidth, R3DStill *out);

void r3d_free(R3DStill *still);

#ifdef __cplusplus
}
#endif
#endif
