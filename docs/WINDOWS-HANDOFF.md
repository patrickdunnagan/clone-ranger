# Clone Ranger for Windows: handoff

Handoff version 1.1, written 2026-11-19, against Clone Ranger for Mac 0.8.2. (1.0 was against Mac 0.7.0.)

This is for the person (and their Claude) building the Windows version of Clone Ranger. Read it all before
writing code. The Mac app in this repo is the working reference: when this document and the Mac app disagree,
ask Patrick before picking one.

- Code: https://github.com/patrickdunnagan/clone-ranger
- Owner and the person who decides features: Patrick
- Finished builds go on the Horizon server: Projects › HORIZON IT › Clone Ranger › Clone Ranger for Windows

## New in this version of the handoff (1.1)

Mac 0.8.0–0.8.2 added these; they're written into the sections below and the test checklist:

- **Naming a transfer** (Name box, automatic reel name from the card, three ways to rename). See "Transfer names".
- **Settings › Reports:** PDF with frames (default), PDF without frames, or Off.
- **Transfer list shows where each transfer went** ("→ SHUTTLE 01 › Day 2").
- **Right-click a finished transfer › Eject** its card.
- A whole card shows "the whole card" as where it's copied from.
- New sections: "Getting started", "Where things are in the Mac code".

## Getting started

1. Install Claude Code on the Windows PC and clone the repo:
   `git clone https://github.com/patrickdunnagan/clone-ranger`
2. Send Patrick your GitHub username. He'll add you as a collaborator so you can push; until then the repo is
   read-only for you.
3. Work on a branch called `windows`, with everything in a `windows/` folder. `main` is what the Mac app is
   built from, so nothing lands there until Patrick says so.
4. Start your Claude with something like:
   > Read docs/WINDOWS-HANDOFF.md and docs/NEXT-BUILD.md in full, then skim the Mac source files the handoff
   > points to. Before writing code, tell me the plan for stage 1 (stack, project layout, how you'll test on
   > this PC) and list anything in the handoff that's unclear or that you'd do differently. Don't change
   > anything outside the windows/ folder.
5. Send Patrick that plan and the questions before building. Settled decisions (the rules below) are not up for
   change without him.
6. Name every build with its version: `Clone Ranger for Windows 0.1.0.zip`, then 0.1.1, 0.2.0… Keep only the
   newest 4–5 builds in the server folder, and add a line for each one to a `What's in this folder.txt` there
   (the Mac folder next door has one to copy the style from).

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

**Reports.** "<folder> Reports" next to each copy, named "<folder> YYMMDD-HHMM.pdf" (or "<name> · <folder> …"
when the transfer has a name). Contents: what, from where,
to where, when, totals, result per destination, every file with size and checksum, anything flagged
(clashes renamed, already there, failed, retried), and one frame grab per video clip. Optional setting: also save a
CSV checksum list next to the PDF. The report also says who ran it and on which computer (the
Windows user's full name and PC name). `Sources/CloneRanger/Report.swift` is the reference for the layout; ask
Patrick to send a real report from the Mac to match.

**Logs.** One log per transfer: version, Windows version, hardware, every stage, every error, a progress line every
60 s, outcome. Kept in %LOCALAPPDATA%\Clone Ranger\Logs (newest 100), plus a copy next to each PDF as
"<report name> log.txt". Help menu → Show Logs. Logs are how Patrick and Claude diagnose problems, so be generous.

**Eject.** Right-click a removable drive in the left column → Eject. Also on a finished transfer's right-click menu:
"Eject <card name>" for the card it copied from, if that's still plugged in and removable. Either way it's only
offered when no active, queued or paused transfer needs that drive; otherwise show it disabled with
"Can't Eject: <transfer> needs it".

**Reports setting** (Settings › Reports): PDF with a frame from each clip (the default), PDF without frames (much
faster on big cards; the clips section is left out, every file is still listed), or Off (no Reports folder at all;
every file is still verified and the log is still kept; the log says "No report: reports are turned off").
The CSV option and the frame-size option are greyed out when they don't apply.

**Large folders.** Show what's happening during every slow step ("Listing files… 48,000 found", "Making
folders… 1,250 of 29,698", "Setting folder dates…"). Never sit at "Starting" with no movement. The time estimate
learns per-file cost and per-byte cost separately (small files are limited by the number of files, big ones by MB/s);
show files/s when the average file is small. A 134,777-file, 126 GB folder (mostly tiny files) is the real-world
stress case.

## Transfer names (Mac 0.8.0–0.8.2)

Cameras name every card's folder the same ("CLIP", "PRIVATE", "DCIM"), so a list of finished transfers used to
read "CLIP, Clip, Clip". A name fixes that, and tells people on set which card is done and can be ejected.

- **It's only a label.** The folders on the drives keep their real names; nothing on disk is renamed.
- **Name box** in the Copy From block, optional. Enter in it starts the transfer.
- **Filled in automatically with the card's reel name** when the camera put one in the file names (rules
  below). A note under the box says where it came from ("Reel A301 found on the card (from the clip names)").
  Typing replaces it, and from then on the box is the person's, so it is never refilled over their typing.
- **When there's no name at all:** a generic camera folder gets the card name in front ("CAM B › CLIP");
  anything else shows its folder name. Generic folders: CLIP, CLIPS, DCIM, PRIVATE, XDROOT, M4ROOT, AVCHD, BPAV,
  CONTENTS, STREAM, SUB, MEDIA, FOOTAGE, VIDEO, CAMERA, 100MEDIA, 100CANON, 100MSDCF, 100GOPRO, 100_PANA,
  100NIKON, UNTITLED (any case).
- **Rename afterwards, three ways:** right-click › Rename…; the pencil next to the big name in the details; or
  like a file in Explorer: click a selected transfer's name again and it becomes a text box (Enter saves, Esc
  cancels, clicking away saves, a double-click never starts a rename). Empty = back to the automatic name.
- **Where it shows:** transfer list, details, the "finished" banner, notifications, the log ("named A301",
  "Renamed: …"), and the report: the title line "A301 · CLIP", a "Transfer name" row, the footer, and the start of
  the PDF's file name ("A301 · CLIP 261119-0931.pdf", with `/` and `:` replaced by `-`).
- **Survives a quit or crash** with the rest of the unfinished transfer (the Mac keeps it in "<id>.name" beside the
  progress file).
- Names are trimmed and capped at 60 characters.

**Reel rules** (Mac: `Sources/CRCore/Reel.swift`, small and easy to port; `cr-cli --reel <folder>` prints what it
finds). Only names already found by the listing are looked at; nothing extra is read.

1. RED reel folder anywhere on the card: `^([A-Z][0-9]{3})_[0-9A-Z]+\.RDM$` (case-insensitive) → "A001".
2. Otherwise video file names (mov, mp4, mxf, braw, r3d, ari, arx, crm, mts, avi, mkv, m4v) matching
   `^([A-Z]_[0-9]{4}|[A-Z][0-9]{3})(?=C[0-9]{3}|_C[0-9]{3}|_[0-9]{6,})`. That covers ARRI / Canon / Sony
   camera-ID naming (A301C004_…), RED clips (A001_C004_…), Blackmagic (A001_08201230_C004.braw) and ALEXA 35
   (A_0001C004_…).
3. One reel → "A301". Several → first and last, sorted naturally: "A001–A003". None (Sony FX3 default C0001.MP4,
   GoPro, phones) → no suggestion.

These were tested on file names laid out like each camera's, not yet on every real card; Patrick is checking real
FX6 and RED cards. Use the same rules so both apps name the same card the same way.

## Layout and look

Dark, three columns, separated by heavy 5 px grooves:

- **Left: places.** This PC (Desktop, Documents, Videos), Drives and Cards, Network. Each expands into a tree of
  folders first, then files with sizes (so people can tell Camera A from Camera B). Drag from here, or right-click a
  file → "Copy Just This File".
- **Center: compose, top to bottom.** "Copy From" block (list of items with ×, total, a dashed "Drop more… from
  <place>" strip), a line with a down arrow, then a larger "Copy To" block with one card per destination showing its
  tree. Start button above. Empty state = big dashed drop zones. After a transfer finishes, the center goes back to
  "ready for the next one" with a green/tan/red banner (View details, Open report, ×).
- **Right: transfers.** Active, Queued, a dividing line, then History. Each row: name, status pill, progress bar,
  and a grey line with time, size, where it went ("→ SHUTTLE 01 › Day 2" for one drive, "→ SHUTTLE 01, RAID 02" for
  more) and how long it took. Right-click a row → Pause/Resume, Cancel, Eject <card>, Open Report, Open Log,
  Rename…, Show Details (only the actions that make sense for its state).
- **Copy From label:** a whole card says "the whole card"; anything else shows where it is ("Horizon › Projects").
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

Pictures: on the server in Clone Ranger for Windows › mockups (the early drawings) and › screenshots (the real Mac app,
0.7.0–0.8.1, with made-up cards and footage). Match the screenshots where they differ from the drawings.

## Build order

1. **Core:** scan, copy to up to 4 destinations, read-back verify, never-overwrite rules, Unverified + retries,
   pause/cancel, unplug and resume, quit/crash resume, logs, PDF report without frames. Most Windows users need only
   this, so ship it as soon as it passes the test checklist.
2. **Video:** frame grabs for the report (bundle FFmpeg, LGPL build only, run as a separate program like the Mac
   does), then Blackmagic RAW and RED R3D frames (both SDKs have Windows versions; only their runtime libraries
   may be shipped, the SDKs themselves stay out of git, see THIRD-PARTY.md and scripts/vendor-sdks.sh).

Nothing in the Mac version is dropped for good; stage 2 brings it to parity.

## Where things are in the Mac code

Read these for exact behavior; port the logic, not the Swift.

| What | File |
|---|---|
| Copy, verify, never-overwrite, Unverified + retries, resume, progress file contents | `Sources/CRCore/Engine.swift` |
| Reading the source once and writing every destination at the same time; the verify read | `Sources/CRCore/MultiCopy.swift` |
| Listing a folder (what's skipped, problems) | `Sources/CRCore/Scan.swift` |
| Reel name rules | `Sources/CRCore/Reel.swift` |
| xxHash64 (compare your output against it) | `Sources/CRCore/XXHash64.swift` |
| Transfers, queue, names, eject, logs, resume flow, settings | `Sources/CloneRanger/Model.swift` |
| PDF and CSV report | `Sources/CloneRanger/Report.swift` |
| Frame grabs (which formats, FFmpeg, BRAW, R3D) | `Sources/CloneRanger/FrameGrab.swift` |
| Left column / center / right column | `Sidebar.swift` / `Center.swift` / `RightColumn.swift` |
| Logs and the unfinished-transfer files | `Sources/CloneRanger/Support.swift` |
| Test switches (environment variables) | README "Test tools" and `Sources/CloneRanger/Autoplay.swift` |

The Mac app has test switches that drive a whole transfer and save screenshots without anyone clicking
(`CR_AUTOPLAY`, `CR_SNAP_DIR`, `CR_THROTTLE`, `CR_TEST_CORRUPT`…). Building the same into the Windows app early
makes every later test much faster for your Claude.

## Suggested stack (the Windows builder's call)

C# on .NET 8 with WPF or WinUI 3, single self-contained .exe. Hashing: `System.IO.Hashing`. PDF: an MIT or
otherwise free-for-this-use library (e.g. PDFsharp). Whatever is picked: no installer that needs admin rights if it
can be avoided, and no license that costs money.

Code goes in a `windows/` folder of this repo, on the `windows` branch. **Don't change the Mac app's files** (Sources/, scripts/,
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
13. Name box: a folder of files named like each camera (A301C004_….mov, A001_0101XY.RDM/…, C0001.MP4) suggests
    A301, A001, and nothing. Type over a suggestion, add more items: the typed name stays.
14. Named transfer: the name shows in the list, details, notification, log, and the report (title, "Transfer name"
    row, file name). The folders on the drive keep their real names.
15. Rename three ways (right-click, pencil, click the selected name again); Esc cancels; double-click doesn't
    rename. Quit mid-copy with a name, reopen: the name is still there.
16. Two cards that both have a CLIP folder into the same destination: second lands as "CLIP 2", and the list shows
    "CAM A › CLIP" and "CAM B › CLIP" (no names typed).
17. Settings › Reports: each of the three choices does what it says; Off leaves no Reports folder.
18. Right-click a finished transfer › Eject its card: works; refused while another transfer needs that card.

Report results to Patrick as pass/fail per item, with the log for any failure.

## Next-build list (shared)

Features Patrick asks for go in `docs/NEXT-BUILD.md` so both versions pick them up. Mark each item Mac done /
Windows done.
