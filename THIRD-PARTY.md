# Third-party software in Clone Ranger

Clone Ranger is free to use and share. It includes these pieces of other people's software, each under its
own license. This file goes with every copy of the app (it's also inside the app at
Contents/Resources/Licenses).

## FFmpeg 7.1.1 (LGPL 2.1 or later)
Used only to grab still frames for the PDF report from clips macOS can't open itself (for example Sony
XAVC MXF). Clone Ranger runs it as a separate program, `Contents/MacOS/ffmpeg-cr`.

- License: GNU Lesser General Public License 2.1 or later; full text in `LICENSE-FFmpeg-LGPLv2.1.txt`.
- Built from the unmodified official source: https://ffmpeg.org/releases/ffmpeg-7.1.1.tar.xz
- Build settings: `scripts/build-ffmpeg.sh` in the Clone Ranger source (LGPL-only; no GPL parts enabled).
- You may replace `ffmpeg-cr` with your own build of FFmpeg; Clone Ranger will use it.
- FFmpeg is a trademark of Fabrice Bellard, originator of the FFmpeg project. https://ffmpeg.org

## Blackmagic RAW SDK (BlackmagicRawAPI.framework)
Used to grab frames from Blackmagic RAW (.braw) clips. Copyright Blackmagic Design Pty. Ltd.;
redistributed under the Blackmagic RAW SDK license, which permits shipping the API libraries with an app.

## RED R3D SDK (REDR3D.dylib)
Used to grab frames from RED and Nikon R3D clips. Copyright RED Digital Cinema / Nikon; redistributed
under the R3D SDK license as a redistributable runtime library.
