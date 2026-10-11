// Bridge from Swift to the RED R3D SDK (C++). Built against Vendor/RED (scripts/vendor-sdks.sh) when
// present (HAVE_R3D_SDK, set by Package.swift); otherwise a stub that reports "not available".
#include "R3DBridge.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>

#ifdef HAVE_R3D_SDK
#include "R3DSDK.h"
#include <mutex>
#include <string>

using namespace R3DSDK;

namespace {
std::mutex initLock;
int initState = 0;   // 0 = not tried, 1 = ready, -1 = failed

bool ensureInit(const char *libDir) {
    std::lock_guard<std::mutex> g(initLock);
    if (initState == 0) initState = InitializeSdk(libDir, OPTION_RED_NONE) == ISInitializeOK ? 1 : -1;
    return initState == 1;
}

// Decoding needs a 16-byte aligned buffer.
struct Aligned {
    void *raw = nullptr;
    uint8_t *p = nullptr;
    explicit Aligned(size_t n) { raw = malloc(n + 16); p = (uint8_t *)(((uintptr_t)raw + 15) & ~(uintptr_t)15); }
    ~Aligned() { free(raw); }
};

int grab(const char *path, double fraction, uint32_t maxWidth, R3DStill *out) {
    auto fail = [&](const char *msg) { snprintf(out->error, sizeof(out->error), "%s", msg); return 0; };
    Clip clip(path);
    if (clip.Status() != LSClipLoaded) return fail("Couldn't open the clip");
    size_t w = clip.Width(), h = clip.Height(), frames = clip.VideoFrameCount();
    float rate = clip.VideoAudioFramerate();
    out->clipWidth = (uint32_t)w; out->clipHeight = (uint32_t)h;
    out->duration = rate > 0 ? frames / rate : 0;

    // Smallest decode that's still at least maxWidth wide.
    struct { VideoDecodeMode mode; size_t div; } steps[] = {
        {DECODE_SIXTEENTH_RES_GOOD, 16}, {DECODE_EIGHT_RES_GOOD, 8}, {DECODE_QUARTER_RES_GOOD, 4}, {DECODE_HALF_RES_GOOD, 2}};
    VideoDecodeMode mode = DECODE_HALF_RES_GOOD;
    size_t div = 2;
    for (auto &s : steps) if (w / s.div >= maxWidth) { mode = s.mode; div = s.div; break; }
    size_t ow = w / div, oh = h / div;

    // Normal-looking Rec.709 rather than log, whatever the clip was set to.
    ImageProcessingSettings ips;
    clip.GetDefaultImageProcessingSettings(ips);
    ips.ColorSpace = ImageColorRec709;
    if (ips.Version >= ColorVersion3) {
        ips.GammaCurve = ImageGammaBT1886;
        ips.OutputToneMap = ToneMap_Medium;
    } else {
        ips.GammaCurve = ImageGammaRec709;
    }

    size_t size = ow * oh * 4;
    Aligned buf(size);
    if (!buf.raw) return fail("Out of memory");
    VideoDecodeJob job;
    job.Mode = mode;
    job.PixelType = PixelType_8Bit_BGRA_Interleaved;
    job.OutputBuffer = buf.p;
    job.OutputBufferSize = size;
    job.ImageProcessing = &ips;
    size_t index = frames > 1 ? (size_t)(fraction * (frames - 1)) : 0;
    if (clip.DecodeVideoFrame(index, job) != DSDecodeOK) return fail("Couldn't decode the frame");

    out->bgra = (uint8_t *)malloc(size);
    memcpy(out->bgra, buf.p, size);
    out->width = (uint32_t)ow; out->height = (uint32_t)oh;
    return 1;
}
} // namespace

extern "C" int r3d_available(const char *libDir) { return ensureInit(libDir) ? 1 : 0; }

extern "C" int r3d_grab(const char *libDir, const char *path, double fraction, uint32_t maxWidth, R3DStill *out) {
    memset(out, 0, sizeof(*out));
    if (!ensureInit(libDir)) { snprintf(out->error, sizeof(out->error), "R3D library not found"); return 0; }
    return grab(path, fraction, maxWidth, out);   // Clip lives in a deeper scope than InitializeSdk, as RED asks
}

#else

extern "C" int r3d_available(const char *) { return 0; }
extern "C" int r3d_grab(const char *, const char *, double, uint32_t, R3DStill *out) {
    memset(out, 0, sizeof(*out));
    snprintf(out->error, sizeof(out->error), "Built without the R3D SDK");
    return 0;
}

#endif

extern "C" void r3d_free(R3DStill *still) {
    if (still && still->bgra) { free(still->bgra); still->bgra = nullptr; }
}
