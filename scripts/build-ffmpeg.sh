#!/bin/zsh
# Builds the small FFmpeg Clone Ranger uses for frame grabs from clips the Mac can't open itself
# (Sony XAVC MXF, etc.). LGPL-only (no --enable-gpl), decoding/frame-grab parts only: ~3.6 MB.
# Output: Vendor/FFmpeg/ffmpeg-cr plus its license; the app bundles both (see THIRD-PARTY.md).
set -euo pipefail
cd "$(dirname "$0")/.."
VER=7.1.1
OUT=Vendor/FFmpeg
mkdir -p "$OUT/src"
[[ -f "$OUT/src/ffmpeg-$VER.tar.xz" ]] || curl -sSL -o "$OUT/src/ffmpeg-$VER.tar.xz" "https://ffmpeg.org/releases/ffmpeg-$VER.tar.xz"
rm -rf "$OUT/src/ffmpeg-$VER" && tar xf "$OUT/src/ffmpeg-$VER.tar.xz" -C "$OUT/src"
cd "$OUT/src/ffmpeg-$VER"
./configure --cc=clang --arch=arm64 --extra-cflags="-mmacosx-version-min=14.0" --extra-ldflags="-mmacosx-version-min=14.0" \
  --disable-everything --disable-autodetect --disable-network --disable-doc --disable-debug --disable-ffplay --disable-ffprobe \
  --enable-small --enable-static --disable-shared \
  --enable-protocol=file,pipe \
  --enable-demuxer=mxf,mov,mpegts,mpegps,avi,matroska,h264,hevc,m4v,mpegvideo,mjpeg \
  --enable-decoder=h264,hevc,prores,mpeg2video,mpeg1video,mpeg4,dnxhd,mjpeg,dvvideo,vp9,vc1,pcm_s16le,pcm_s24le \
  --enable-parser=h264,hevc,mpegvideo,mpeg4video,dnxhd,mjpeg,vp9 \
  --enable-filter=scale,format,null,anull \
  --enable-encoder=mjpeg --enable-muxer=image2,image2pipe,null --enable-swscale > configure.log
make -j"$(sysctl -n hw.ncpu)" ffmpeg > make.log
cd - >/dev/null
strip -o "$OUT/ffmpeg-cr" "$OUT/src/ffmpeg-$VER/ffmpeg"
cp "$OUT/src/ffmpeg-$VER/COPYING.LGPLv2.1" "$OUT/LICENSE-FFmpeg-LGPLv2.1.txt"
echo "FFmpeg $VER (LGPL) → $OUT/ffmpeg-cr ($(du -h "$OUT/ffmpeg-cr" | cut -f1))"
