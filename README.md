# ReaTitles

ReaTitles is a subtitle, dialogue-editing and offline transcription toolkit for REAPER.

## Installation through ReaPack

1. Install [ReaPack](https://reapack.com/) and **ReaImGui**.
2. In REAPER open `Extensions > ReaPack > Import repositories`.
3. Add:

   `https://raw.githubusercontent.com/uncleosmixing/ReaTitles/main/index.xml`

4. Synchronize packages and search for **ReaTitles**.
5. Select and install all four ReaTitles packages:
   - ReaTitles - Core
   - ReaTitles - Offline Transcription
   - ReaTitles - Smart Split
   - ReaTitles - SubOverlay
6. Restart REAPER.
7. Run the installed ReaTitles actions from the Action List.

## Included tools

- Prompter with navigation, text editing, phrase colors and magnetic reordering.
- Subtitle import.
- Offline faster-whisper transcription with live progress.
- Smart Split action.
- Ripple Edit and ordinary item movement preserve subtitle text exactly.
- Word timing is stored relative to each subtitle item and is used only by
  explicit Smart Split or one-time legacy recovery.
- Word `.docx` export/import for editor review.
- Word round-trip supports text edits, paragraph reordering, deletions and colors.
- Import creates `ПЕРЕНОС` and `УДАЛ` markers at changed joins.

## Dependencies

### Required

- REAPER 7
- ReaPack
- ReaImGui

### Only for offline transcription

- Python 3.8 or newer
- `faster-whisper` (installed automatically with `pip` when missing)
- FFmpeg (installed automatically through WinGet on Windows when missing)
- Whisper model `small` by default (downloaded automatically once when absent)

The first dependency and model setup requires internet access. When the model is absent, ReaTitles downloads it once into the local Hugging Face cache; later transcriptions use the cached model offline.

### Word review

Word exchange uses OpenXML directly and does not require Microsoft Word on the REAPER computer. Any editor capable of preserving `.docx` formatting may be used.

## Diagnostics

Missing dependencies are reported in message boxes. Detailed diagnostics are stored beside the scripts in `rt_transcribe.log` and `rt_setup.log`; normal use does not require the ReaScript console.

## Word workflow

1. Open Prompter and press `Word`.
2. Choose **Yes** to export.
3. The editor may change text, move whole paragraphs, delete paragraphs and apply text color or highlighting.
4. Press `Word` again and choose **No** to import.

Do not enable “show hidden text” or manually edit hidden `RTID` fields. They connect Word paragraphs to REAPER items.

Before the first import, work on a copy of the REAPER project and verify the result with Undo available.

## Subtitle data safety

`P_NOTES` is the authoritative subtitle text. Prompter refresh, Ripple Edit,
item movement and trimming never regenerate or overwrite it. Smart Split is the
only editing action that divides phrase text from Whisper word timing.

When Prompter first opens an older project, legacy absolute word timing is
migrated to movement-safe relative timing. Empty notes are restored only when
their own timing data contains an unambiguous phrase. The migration is recorded
as one REAPER Undo step.
