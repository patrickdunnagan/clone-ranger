// Bridge from Swift to the Blackmagic RAW SDK (C++ / COM-style). The SDK's headers come from
// Vendor/BlackmagicRAW (scripts/vendor-sdks.sh); without them this builds as a stub that reports
// "not available", and BRAW clips just get no preview.
#include "BRAWBridge.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>

#if __has_include("BlackmagicRawAPI.h")
#include "BlackmagicRawAPI.h"
#include "BlackmagicRawAPIDispatch.cpp"
#include <atomic>
#include <condition_variable>
#include <mutex>
#include <string>
#include <vector>

namespace {

CFStringRef cfstr(const char *s) { return CFStringCreateWithCString(kCFAllocatorDefault, s, kCFStringEncodingUTF8); }

template <class T> struct Owned {   // releases a COM pointer when it goes out of scope
    T *p = nullptr;
    ~Owned() { if (p) p->Release(); }
    T **out() { return &p; }
    T *operator->() { return p; }
    explicit operator bool() const { return p != nullptr; }
};

std::mutex factoryLock;
IBlackmagicRawFactory *sharedFactory(const char *libDir) {
    static IBlackmagicRawFactory *factory = nullptr;
    static std::string loadedFrom;
    std::lock_guard<std::mutex> g(factoryLock);
    if (factory && loadedFrom == libDir) return factory;
    CFStringRef dir = cfstr(libDir);
    IBlackmagicRawFactory *f = CreateBlackmagicRawFactoryInstanceFromPath(dir);
    CFRelease(dir);
    if (f) { factory = f; loadedFrom = libDir; }
    return f;
}

/// Waits for the SDK's callbacks for one frame.
class Grabber : public IBlackmagicRawCallback {
public:
    BlackmagicRawResolutionScale scale = blackmagicRawResolutionScaleEighth;
    IBlackmagicRawClipProcessingAttributes *attrs = nullptr;
    HRESULT result = S_OK;
    std::vector<uint8_t> pixels;
    uint32_t width = 0, height = 0;

    void wait() {
        std::unique_lock<std::mutex> l(m);
        cv.wait(l, [&] { return done; });
    }

    void ReadComplete(IBlackmagicRawJob *, HRESULT r, IBlackmagicRawFrame *frame) override {
        Owned<IBlackmagicRawJob> job;
        if (SUCCEEDED(r)) r = frame->SetResolutionScale(scale);
        if (SUCCEEDED(r)) r = frame->SetResourceFormat(blackmagicRawResourceFormatRGBAU8);
        if (SUCCEEDED(r)) r = frame->CreateJobDecodeAndProcessFrame(attrs, nullptr, job.out());
        if (SUCCEEDED(r)) r = job->Submit();
        // Our reference is dropped when `job` goes out of scope; the SDK keeps its own until done.
        if (FAILED(r)) finish(r);
    }

    void ProcessComplete(IBlackmagicRawJob *job, HRESULT r, IBlackmagicRawProcessedImage *img) override {
        void *data = nullptr;
        uint32_t w = 0, h = 0, size = 0;
        if (SUCCEEDED(r)) r = img->GetWidth(&w);
        if (SUCCEEDED(r)) r = img->GetHeight(&h);
        if (SUCCEEDED(r)) r = img->GetResourceSizeBytes(&size);
        if (SUCCEEDED(r)) r = img->GetResource(&data);
        if (SUCCEEDED(r) && data && size >= w * h * 4) {
            pixels.assign((uint8_t *)data, (uint8_t *)data + (size_t)w * h * 4);
            width = w; height = h;
        }
        (void)job;
        finish(r);
    }

    void DecodeComplete(IBlackmagicRawJob *, HRESULT) override {}
    void TrimProgress(IBlackmagicRawJob *, float) override {}
    void TrimComplete(IBlackmagicRawJob *, HRESULT) override {}
    void SidecarMetadataParseWarning(IBlackmagicRawClip *, CFStringRef, uint32_t, CFStringRef) override {}
    void SidecarMetadataParseError(IBlackmagicRawClip *, CFStringRef, uint32_t, CFStringRef) override {}
    void PreparePipelineComplete(void *, HRESULT) override {}
    void ReadAudioComplete(IBlackmagicRawJob *, HRESULT, IBlackmagicRawAudioBuffer *) override {}

    HRESULT QueryInterface(REFIID iid, LPVOID *out) override {
        if (!out) return E_POINTER;
        if (memcmp(&iid, &IID_IBlackmagicRawCallback, sizeof(REFIID)) == 0) { *out = this; AddRef(); return S_OK; }
        *out = nullptr;
        return E_NOINTERFACE;
    }
    ULONG AddRef() override { return ++refs; }
    ULONG Release() override { return --refs; }   // lives on the stack; never deleted through Release

private:
    void finish(HRESULT r) {
        std::lock_guard<std::mutex> l(m);
        if (FAILED(r)) result = r;
        done = true;
        cv.notify_all();
    }
    std::mutex m;
    std::condition_variable cv;
    bool done = false;
    std::atomic<ULONG> refs{1};
};

void setString(IBlackmagicRawClipProcessingAttributes *a, BlackmagicRawClipProcessingAttribute key, const char *value) {
    Variant v;
    VariantInit(&v);
    v.vt = blackmagicRawVariantTypeString;
    v.bstrVal = cfstr(value);
    a->SetClipAttribute(key, &v);
    VariantClear(&v);
}

} // namespace

extern "C" int braw_available(const char *libDir) { return sharedFactory(libDir) != nullptr; }

extern "C" int braw_grab(const char *libDir, const char *path, double fraction, uint32_t maxWidth, BRAWStill *out) {
    memset(out, 0, sizeof(*out));
    auto fail = [&](const char *msg) { snprintf(out->error, sizeof(out->error), "%s", msg); return 0; };
    IBlackmagicRawFactory *factory = sharedFactory(libDir);
    if (!factory) return fail("Blackmagic RAW library not found");

    Owned<IBlackmagicRaw> codec;
    if (FAILED(factory->CreateCodec(codec.out()))) return fail("Couldn't start the Blackmagic RAW decoder");
    Owned<IBlackmagicRawClip> clip;
    CFStringRef p = cfstr(path);
    HRESULT r = codec->OpenClip(p, clip.out());
    CFRelease(p);
    if (FAILED(r)) return fail("Couldn't open the clip");

    uint32_t w = 0, h = 0;
    uint64_t frames = 0;
    float rate = 0;
    clip->GetWidth(&w); clip->GetHeight(&h); clip->GetFrameCount(&frames); clip->GetFrameRate(&rate);
    out->clipWidth = w; out->clipHeight = h;
    out->duration = rate > 0 ? frames / rate : 0;

    Grabber g;
    // Smallest decode that's still at least maxWidth wide (an eighth of 12K is plenty for a thumbnail).
    g.scale = w / 8 >= maxWidth ? blackmagicRawResolutionScaleEighth
            : w / 4 >= maxWidth ? blackmagicRawResolutionScaleQuarter
            : w / 2 >= maxWidth ? blackmagicRawResolutionScaleHalf : blackmagicRawResolutionScaleFull;
    Owned<IBlackmagicRawClipProcessingAttributes> attrs;
    if (SUCCEEDED(clip->CloneClipProcessingAttributes(attrs.out()))) {
        // Normal-looking video instead of flat Blackmagic Film log.
        setString(attrs.p, blackmagicRawClipProcessingAttributeGamma, "Rec.709");
        setString(attrs.p, blackmagicRawClipProcessingAttributeGamut, "Rec.709");
        g.attrs = attrs.p;
    }
    if (FAILED(codec->SetCallback(&g))) return fail("Couldn't set up the decoder");
    uint64_t index = frames > 1 ? (uint64_t)(fraction * (frames - 1)) : 0;
    Owned<IBlackmagicRawJob> read;
    if (FAILED(clip->CreateJobReadFrame(index, read.out())) || FAILED(read->Submit())) return fail("Couldn't read a frame");
    read.p->Release();   // FlushJobs waits for every job to be released, so let ours go now
    read.p = nullptr;
    g.wait();
    codec->FlushJobs();
    codec->SetCallback(nullptr);
    if (FAILED(g.result) || g.pixels.empty()) return fail("Couldn't decode the frame");

    out->width = g.width; out->height = g.height;
    out->rgba = (uint8_t *)malloc(g.pixels.size());
    memcpy(out->rgba, g.pixels.data(), g.pixels.size());
    return 1;
}

extern "C" int braw_gamma_options(const char *libDir, const char *path, char *buf, int bufSize) {
    buf[0] = 0;
    IBlackmagicRawFactory *factory = sharedFactory(libDir);
    if (!factory) return 0;
    Owned<IBlackmagicRaw> codec;
    Owned<IBlackmagicRawClip> clip;
    CFStringRef p = cfstr(path);
    bool ok = SUCCEEDED(factory->CreateCodec(codec.out())) && SUCCEEDED(codec->OpenClip(p, clip.out()));
    CFRelease(p);
    if (!ok) return 0;
    Owned<IBlackmagicRawClipProcessingAttributes> attrs;
    if (FAILED(clip->CloneClipProcessingAttributes(attrs.out()))) return 0;
    for (auto key : {blackmagicRawClipProcessingAttributeGamma, blackmagicRawClipProcessingAttributeGamut}) {
        uint32_t count = 0;
        bool ro = false;
        if (FAILED(attrs->GetClipAttributeList(key, nullptr, &count, &ro)) || count == 0) continue;
        std::vector<Variant> list(count);
        for (auto &v : list) VariantInit(&v);
        if (SUCCEEDED(attrs->GetClipAttributeList(key, list.data(), &count, &ro))) {
            for (auto &v : list) {
                char s[128] = {0};
                if (v.vt == blackmagicRawVariantTypeString && v.bstrVal) CFStringGetCString(v.bstrVal, s, sizeof(s), kCFStringEncodingUTF8);
                strncat(buf, s, bufSize - strlen(buf) - 3);
                strncat(buf, ", ", bufSize - strlen(buf) - 1);
            }
        }
        for (auto &v : list) VariantClear(&v);
        strncat(buf, " | ", bufSize - strlen(buf) - 1);
    }
    return 1;
}

#else   // SDK not vendored: stubs

extern "C" int braw_available(const char *) { return 0; }
extern "C" int braw_grab(const char *, const char *, double, uint32_t, BRAWStill *out) {
    memset(out, 0, sizeof(*out));
    snprintf(out->error, sizeof(out->error), "Built without the Blackmagic RAW SDK");
    return 0;
}
extern "C" int braw_gamma_options(const char *, const char *, char *buf, int) { buf[0] = 0; return 0; }

#endif

extern "C" void braw_free(BRAWStill *still) {
    if (still && still->rgba) { free(still->rgba); still->rgba = nullptr; }
}
