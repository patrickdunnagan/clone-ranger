# Clone Ranger for Windows: handoff

Handoff version 1.0, written 2026-11-05, against Clone Ranger for Mac 0.7.0.

This is for the person (and their Claude) building the Windows version of Clone Ranger. Read it all before
writing code. The Mac app in this repo is the working reference: when this document and the Mac app disagree,
ask Patrick before picking one.

- Code: https://github.com/patrickdunnagan/clone-ranger
- Owner and the person who decides features: Patrick
- Finished builds go on the Horizon server: Projects › HORIZON IT › Clone Ranger for Windows

## What Clone Ranger is

A verified copy app, in the spirit of ShotPut Pro. You drop what to copy from, drop up to four places to copy to,
and press Start. It reads the source once, writes every destination at the same time, then reads every copy
back off its own drive and compares checksums. A PDF report goes next to each copy as proof.

On Windows it will mostly be used to copy ordinary project files (server to drive, drive to server). It must still
do everything the Mac version does with video, because any Windows machine might be handed a video job.

Accuracy first, speed second. A fast copy that is wrong is worthless.

## Rules that are never broken

1. **Never overwrite anything.** If a name is already taken at the destination:
   - identical file (same size and checksum) → leave it, count it as "already there";
   - different file → the new copy gets " 2" ("CLIP 2.MP4", then " 3"…). Folders work the same way
     ("Project 2" already there → "Project 2 2"). This is shown in red before Start and listed in the report.
2. **Never change, move or delete anything on the source.**
3. **Every copy is verified by reading it back off the destination drive**, not from memory or cache. Windows: open
   the copy with `FILE_FLAG_NO_BUFFERING` (or otherwise make sure the bytes come off the disk) for the verify.
   There is deliberately **no "skip verify" or "fast verify" mode**. Patrick decided this; don't add one.
4. **Checksum: xxHash64** (.NET has it built in: `System.IO.Hashing.XxHash64`). Must match the Mac's values for
   the same file, so reports from both apps can be compared.
5. **Partial files never look finished.** Write to a hidden temporary name (`.cloneranger-partial`), flush to disk
   (`FlushFileBuffers`), then rename to the real name, checking again right before the rename that the name is still
   free.
6. **Failed verify:** the bad copy is moved into "<folder> Unverified" (same subfolders), then just those files are
   copied again from the source, two more tries with a short pause before each (lets a network share recover).
   Anything still failing is flagged in red in the app and the report. Bad copies are moved, never deleted.
7. **Never trust a different drive with the same name.** On resume, check the volume ID and file list; refuse a
   different card or drive even if its name matches.
8. Keep file dates (created/modified) and attributes on every copy.

## How it works (match the Mac)

**Sources.** One source location per transfer. Drop a whole drive/card or folder → it is recreated as a new folder
in each destination. Drop several files/folders from the same parent (e.g. Project 1, 2, 3) → each keeps its own
name in the destination. Later drops add to the list, they don't replace it. Items from a different parent are
refused with a plain message saying why.

**Destinations.** Up to 4, copied at the same time. Each shows a small tree of what will be created there,
with clashes in red.

**Queue.** Transfers run one at a time by default (setting: transfers at once). You can set up the next one while
one runs ("Queue Next").

**Unplugged mid-copy.** The transfer stops (no automatic resume), notifies, and waits (orange). When the drive is
back, two choices:
- **Resume Safely:** re-reads everything already copied from the source.
- **Quick Check & Resume:** names, sizes, dates, start and end of each file, last two files in full.
Destinations are always fully re-checked either way.

**Quit or crash.** A progress file (Mac: ~/Library/Application Support/Clone Ranger/Unfinished; Windows:
%LOCALAPPDATA%\Clone Ranger\Unfinished) lets the transfer be offered for resume on next launch, same two choices.

**Reports.** "<folder> Reports" next to each copy, named "<folder> YYMMDD-HHMM.pdf". Contents: what, from where,
to where, when, totals, result per destination, every file with size and checksum, anything flagged
(clashes renamed, already there, failed, retried), and one frame grab per video clip. Optional setting: also save a
CSV checksum list next to the PDF. See `samples/` on the server for real report PDFs.

**Logs.** One log per transfer: version, Windows version, hardware, every stage, every error, a progress line every
60 s, outcome. Kept in %LOCALAPPDATA%\Clone Ranger\Logs (newest 100), plus a copy next to each PDF as
"<report name> log.txt". Help menu → Show Logs. Logs are how Patrick and Claude diagnose problems, so be generous.

**Eject.** Right-click a removable drive in the left column → Eject. Only offered when no active, queued or paused
transfer needs that drive; otherwise show it disabled with "Can't Eject: <transfer> needs it".

**Large folders.** Show what's happening during every slow step ("Listing files… 48,000 found", "Making
folders… 1,250 of 29,698", "Setting folder dates…"). Never sit at "Starting" with no movement. The time estimate
learns per-file cost and per-byte cost separately (small files are limited by the number of files, big ones by MB/s);
show files/s when the average file is small. A 134,777-file, 126 GB folder (mostly tiny files) is the real-world
stress case.

## Layout and look

Dark, three columns, separated by heavy 5 px grooves:

- **Left: places.** This PC (Desktop, Documents, Videos), Drives and Cards, Network. Each expands into a tree of
  folders first, then files with sizes (so people can tell Camera A from Camera B). Drag from here, or right-click a
  file → "Copy Just This File".
- **Center: compose, top to bottom.** "Copy From" block (list of items with ×, total, a dashed "Drop more… from
  <place>" strip), a line with a down arrow, then a larger "Copy To" block with one card per destination showing its
  tree. Start button above. Empty state = big dashed drop zones. After a transfer finishes, the center goes back to
  "ready for the next one" with a green/tan/red banner (View details, Open report, ×).
- **Right: transfers.** Active, Queued, a dividing line, then History. Each row has a progress bar. Right-click a row
  → Pause/Resume, Cancel, Open Report, Open Log, Show Details (only the actions that make sense for its state).
- **Top bar:** beveled, app name and logo centered.

Colors (hex):

| Use | Color |
|---|---|
| Background / side columns / panels | #262626 / #2B2B2B / #313131 |
| Copying | blue #2E8CE6 |
| Verifying | purple #9B7FE6 |
| Verified | green #4FB08F |
| Failed | red #EF5B5B |
| Paused or unplugged | orange #F08A3C |
| Canceled | tan #B08A62 |
| Queued | grey #8A8A8A |

Mockups and report samples: on the server in Clone Ranger for Windows › samples.

## Build order

1. **Core:** scan, copy to up to 4 destinations, read-back verify, never-overwrite rules, Unverified + retries,
   pause/cancel, unplug and resume, quit/crash resume, logs, PDF report without frames. Most Windows users need only
   this, so ship it as soon as it passes the test checklist.
2. **Video:** frame grabs for the report (bundle FFmpeg, LGPL build only, run as a separate program like the Mac
   does), then Blackmagic RAW and RED R3D frames (both SDKs have Windows versions; only their runtime libraries
   may be shipped, the SDKs themselves stay out of git, see THIRD-PARTY.md and scripts/vendor-sdks.sh).

Nothing in the Mac version is dropped for good; stage 2 brings it to parity.

## Suggested stack (the Windows builder's call)

C# on .NET 8 with WPF or WinUI 3, single self-contained .exe. Hashing: `System.IO.Hashing`. PDF: an MIT or
otherwise free-for-this-use library (e.g. PDFsharp). Whatever is picked: no installer that needs admin rights if it
can be avoided, and no license that costs money.

Code goes in a `windows/` folder of this repo. **Don't change the Mac app's files** (Sources/, scripts/,
Package.swift); Patrick's Mac Claude owns those. Shared changes go through the feature list below.

## Windows problems to handle on purpose

- **Filenames Windows refuses:** `< > : " / \ | ? *`, trailing dots or spaces, and reserved names (CON, PRN, AUX,
  NUL, COM1–9, LPT1–9). Files from Macs and cameras can have these. Never rename silently: list them before Start
  and in the report, and ask Patrick how he wants them handled before deciding.
- **Long paths over 260 characters:** use `\\?\` paths / long-path-aware APIs everywhere. Project folders are deep.
- **Windows Defender** scans every new file, which can make folders of many small files much slower. Measure it on
  the 100,000+ small-file case and report the numbers before trying to work around it. Don't turn Defender off
  or add exclusions without asking.
- **Case:** Windows and macOS both treat "Clip.mp4" and "clip.MP4" as the same name; treat that as a clash.
- **Card readers:** some show up as fixed drives rather than removable, which affects Eject. Check on the first
  real card.
- **SmartScreen:** an unsigned .exe triggers "Windows protected your PC". Fine for testing; signing is Patrick's
  decision later.
- **Network (SMB):** the Horizon server is a Synology. On the Mac, creating and renaming each file costs ~5 ms on
  that server, which limits small files to ~65–80 files/s no matter how many run at once (copy uses 4 at a time,
  verify 3). Measure on Windows; it may be different.

## Test checklist

Use spare drives and copies of footage only, never the only copy of anything. A USB thumb drive with a backed-up
card folder (original camera folder structure, a few real clips) stands in for a card.

1. Folder from the thumb drive → 2 local drives. Verified, report in each, checksums match the Mac's for the same
   files.
2. Three folders from one server folder → one drive. Each keeps its name.
3. Clash: destination already has one identical file and one different file with the same name. Identical → "already
   there"; different → " 2". Nothing overwritten (check the original file's date and checksum).
4. Corrupt a copy during verify (add a test hook like the Mac's `CR_TEST_CORRUPT`). Goes to Unverified, retried,
   flagged.
5. Pull the thumb drive mid-copy. Stops, orange, notifies. Plug back in → both resume choices work.
6. Plug in a different drive with the same name → refused.
7. Quit mid-copy, reopen → offered for resume, finishes verified.
8. Right-click a transfer: Pause, Resume, Cancel each work.
9. Eject: refused while a transfer needs the drive, works after.
10. Big server folder (thousands of folders, 100,000+ small files) → a drive. Progress moves the whole time,
    estimate is sensible, report the files/s.
11. Filenames with `:` or `?` and a path over 260 characters → flagged, not lost.
12. Stage 2: report frame grabs for MP4/MOV, Sony MXF, BRAW, R3D.

Report results to Patrick as pass/fail per item, with the log for any failure.

## Next-build list (shared)

Features Patrick asks for go in `docs/NEXT-BUILD.md` so both versions pick them up. Mark each item Mac done /
Windows done.
