# Clone Ranger

Verified offload for the Mac, in the spirit of ShotPut Pro. Reads the source once, writes it to up to four
destinations at the same time, then reads every copy back off its drive and compares xxHash64 checksums.
Anything that fails its verify is moved to "<folder> Unverified" (same subfolders), then just those files are copied again from the source (two more tries) and flagged.
A PDF report (frame per video clip) lands in "<folder> Reports" next to each copy.

Unplugged mid-transfer? The transfer stops (no automatic resume), notifies, and waits. When the card or drive is
back: Resume Safely (re-reads everything already copied from the card) or Quick Check & Resume (names, sizes,
dates, start/end of each file, last two files in full); destinations are always fully re-checked. A different card
with the same name is refused (volume ID + file list). A progress file in ~/Library/Application Support/Clone
Ranger/Unfinished lets a quit or crash be resumed the same way.

Build: `scripts/build-app.sh` → `build/Clone Ranger.app` and `dist/Clone Ranger <version>.zip` (keeps the 5 newest).

Engine notes
- Names are handled as raw bytes (`FS`, readdir/open/rename); Foundation URL paths rewrite accented names.
- Source is read through the page cache (read-ahead: ~980 vs ~700 MB/s on USB SSDs). Local destinations are
  written with F_NOCACHE. The verify uses a cached read only when mincore() shows none of the copy in memory,
  otherwise an uncached read, so every verify byte comes off the drive.
- Never overwrites: a taken name becomes "CLIP 2", "CLIP 3"…; partial files use a hidden `.cloneranger-partial` name.

Test tools
- `cr-cli <source> <dest>…` headless transfer; `--hash`, `--write`, `--resident` benchmarks.
- App env vars: `CR_AUTOPLAY="src|dest|…"` + `CR_SNAP_DIR` (screenshots), `CR_THROTTLE` (MB/s),
  `CR_TEST_CORRUPT`, `CR_TEST_CORRUPT_ALWAYS`, `CR_TEST_PAUSE`, `CR_TEST_CANCEL`, `CR_AUTOPLAY_RESUME`, `CR_AUTOPLAY_REOPEN`, `CR_JOURNAL_DIR`, `CR_TEST_FRAMES=<folder>`, `CR_MAKE_ICON=<png>`.
