# Uncle Os ReaScripts

The Uncle Os ReaPack repository contains:

- **ReaTitles** - subtitle, dialogue-editing and offline transcription tools.
- **Room Control Center** - a dockable monitoring, metering, reference playback
  and headphone correction center.

## Installation through ReaPack

1. Install [ReaPack](https://reapack.com/) and **ReaImGui**.
2. In REAPER open `Extensions > ReaPack > Import repositories`.
3. Add:

   `https://raw.githubusercontent.com/uncleosmixing/Uncle-Os/main/index.xml`

4. Synchronize packages.
5. Search for **ReaTitles** or **Room Control Center**.
6. For ReaTitles, select the required packages:
   - ReaTitles - Core
   - ReaTitles - Offline Transcription
   - ReaTitles - Smart Split
   - ReaTitles - SubOverlay
7. For RCC, install **Room Control Center**.
8. Restart REAPER.
9. Run the installed actions from the Action List.

## Included tools

- Prompter with navigation, text editing, phrase colors and magnetic reordering.
- Subtitle import.
- Offline faster-whisper transcription with live progress.
- Smart Split action.
- Native REAPER Split, trim, item deletion and Ripple Edit are reconciled
  automatically while Prompter is running.
- Whisper word timing is stored both relative to the displayed subtitle and in
  source-media coordinates on managed audio. Source timing determines which
  spoken words remain after montage edits.
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

Audio is the montage authority. Each transcribed phrase receives a persistent
`REATITLES_PHRASE_ID`, and its Whisper words are attached to the managed audio
in source-media coordinates. Subtitle items are the visible projection of the
audio that remains on the timeline.

`P_NOTES` remains the displayed and manually editable phrase text. A manual
correction is preserved while the active word set is unchanged. If spoken words
are actually removed, ReaTitles rebuilds that phrase from the surviving words.
Silence and breath fragments contain no words, are removed from the temporary
phrase group, and never receive copied subtitle text.

`I_GROUPID` is only a temporary REAPER editing convenience. Phrase identity no
longer depends on it, so inherited group IDs from native Split are repaired
automatically.

When Prompter first opens an older project, legacy absolute word timing is
migrated to movement-safe relative timing. Empty notes are restored only when
their own timing data contains an unambiguous phrase. The migration is recorded
as one REAPER Undo step.
