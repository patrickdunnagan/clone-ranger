# Next-build list

Features asked for go here so the Mac and Windows versions both pick them up. Add new items at the bottom.

| Feature | Asked | Mac | Windows |
|---|---|---|---|
| Everything in Mac 0.7.0 (see WINDOWS-HANDOFF.md) | 2026-11-05 | done | to do |
| Name a transfer: optional Name field before Start, right-click › Rename or the pencil afterwards. Only a label (folders keep their names). Shown in the transfer list, details, notifications, log, and the report (title line, "Transfer name" row, start of the PDF's file name). | 2026-11-19 | done (0.8.0) | to do |
| Automatic name when the folder has a generic camera name (CLIP, DCIM, PRIVATE, XDROOT, M4ROOT…): "<card name> › CLIP". | 2026-11-19 | done (0.8.0) | to do |
| Transfer list shows where each went: "→ SHUTTLE 01 › Day 2", or the drive names when there are several. | 2026-11-19 | done (0.8.0) | to do |
| Right-click a finished transfer › Eject <card>, same safety rule as the left column. | 2026-11-19 | done (0.8.0) | to do |
| Settings › Reports: PDF with clip frames (default) / PDF without frames (faster) / Off (verify still runs, log still kept). | 2026-11-19 | done (0.8.0) | to do |
| Name box fills itself with the card's reel name, found from how the camera names things: RED reel folder (A001_xxxx.RDM), clip names starting A301C004 / A301_C004 / A001_08201230_C004 (ARRI, Canon, Sony camera-ID naming, Blackmagic) / A_0001C004 (ALEXA 35). Several reels → "A001–A003". Cameras without a reel in the names (FX3 C0001, GoPro, phones) → left empty, card name used. Typing replaces it. Logic in Sources/CRCore/Reel.swift. | 2026-11-19 | done (0.8.1) | to do |
| A whole card shows "the whole card" as where it's copied from (was "Macintosh HD › Volumes"). | 2026-11-19 | done (0.8.1) | to do |
| Click-to-rename like the Finder: click a selected transfer's name again (or the big name in the details) and it becomes a text box; Enter saves, Esc cancels, clicking away saves; a double-click never renames. Right-click › Rename stays. | 2026-11-19 | done (0.8.2) | to do |
