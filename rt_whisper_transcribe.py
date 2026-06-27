#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
rt_whisper_transcribe.py - Transcribe audio using WhisperX (forced alignment)
for frame-accurate word-level timestamps.

Pipeline:
  1. faster-whisper  → transcription text + rough segment timestamps
  2. wav2vec2/MMS    → forced alignment → precise per-word timestamps (~20-50ms)

Falls back to stable-whisper if whisperx is not installed.
"""

import argparse
import json
import sys
import os
import time
import multiprocessing

os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["TRANSFORMERS_OFFLINE"] = "1"
os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"

CPU_COUNT = multiprocessing.cpu_count()
WHISPERX_ALIGNMENT_FAILED = False

HAVE_WHISPERX = False
try:
    import whisperx  # noqa: F401
    HAVE_WHISPERX = True
except ImportError:
    pass


def set_hf_offline(enabled):
    """Update both environment flags and libraries that cache offline mode."""
    value = "1" if enabled else "0"
    os.environ["HF_HUB_OFFLINE"] = value
    os.environ["TRANSFORMERS_OFFLINE"] = value
    try:
        import huggingface_hub.constants as hf_constants
        hf_constants.HF_HUB_OFFLINE = enabled
    except Exception:
        pass
    try:
        import transformers.utils.hub as transformers_hub
        transformers_hub._is_offline_mode = enabled
    except Exception:
        pass


def write_status(path, payload):
    if not path:
        return False
    tmp_path = f"{path}.{os.getpid()}.tmp"
    last_error = None
    for _ in range(50):
        try:
            with open(tmp_path, "w", encoding="utf-8") as f:
                json.dump(payload, f, ensure_ascii=False)
            os.replace(tmp_path, path)
            return True
        except OSError as exc:
            last_error = exc
            time.sleep(0.02)
    print(f"[Status] Could not update {path}: {last_error}", file=sys.stderr)
    return False


def find_cached_model(model_size):
    """Return a complete local faster-whisper snapshot without network access."""
    if os.path.isdir(model_size):
        return model_size
    repo_dir = f"models--Systran--faster-whisper-{model_size}"
    cache_roots = []
    if os.environ.get("HUGGINGFACE_HUB_CACHE"):
        cache_roots.append(os.environ["HUGGINGFACE_HUB_CACHE"])
    if os.environ.get("HF_HOME"):
        cache_roots.append(os.path.join(os.environ["HF_HOME"], "hub"))
    cache_roots.extend([
        os.path.join(os.path.expanduser("~"), ".cache", "huggingface", "hub"),
        os.path.join(os.environ.get("LOCALAPPDATA", ""), "huggingface", "hub"),
    ])
    required = ("config.json", "model.bin", "tokenizer.json")
    for cache_root in cache_roots:
        model_root = os.path.join(cache_root, repo_dir)
        refs_main = os.path.join(model_root, "refs", "main")
        candidates = []
        if os.path.isfile(refs_main):
            try:
                revision = open(refs_main, "r", encoding="utf-8").read().strip()
                if revision:
                    candidates.append(os.path.join(model_root, "snapshots", revision))
            except OSError:
                pass
        snapshots = os.path.join(model_root, "snapshots")
        if os.path.isdir(snapshots):
            candidates.extend(
                os.path.join(snapshots, name) for name in os.listdir(snapshots))
        for candidate in candidates:
            if all(os.path.isfile(os.path.join(candidate, name)) and
                   os.path.getsize(os.path.join(candidate, name)) > 0
                   for name in required):
                return candidate
    return None


# WhisperX backend


def transcribe_whisperx(wav_path, model_size, language, duration, emit_progress):
    import whisperx

    device = "cpu"
    compute_type = "int8"

    emit_progress(phase="model", detail=f"Loading Whisper model: {model_size}")
    cached = find_cached_model(model_size)
    if cached:
        model_source = cached
        local_only = True
        print(f"[WhisperX] Using cached model: {cached}", file=sys.stderr)
    else:
        set_hf_offline(False)
        model_source = model_size
        local_only = False
        print(f"[WhisperX] Downloading model: {model_size}", file=sys.stderr)

    t0 = time.time()
    model = whisperx.load_model(
        model_source, device,
        compute_type=compute_type,
        language=language,
        # Use silero VAD - no HuggingFace token required
        vad_method="silero",
        asr_options={
            "temperatures": [0.0],
            "beam_size": 5,
            "patience": 1.2,
            "condition_on_previous_text": False,
            "suppress_blank": True,
            "suppress_tokens": [-1],
            "without_timestamps": False,
            "max_initial_timestamp": 1.0,
            "word_timestamps": True,
        },
        local_files_only=local_only,
        threads=CPU_COUNT,
    )
    set_hf_offline(True)
    print(f"[WhisperX] Whisper loaded in {time.time()-t0:.1f}s", file=sys.stderr)
    emit_progress(phase="model_ready", detail="Whisper ready, loading audio")

    # Step 1: Transcribe - load audio as numpy array (avoids torchcodec issue)
    import numpy as np
    import soundfile as sf
    try:
        audio_np, sr = sf.read(wav_path, dtype="float32", always_2d=False)
        if sr != 16000:
            import resampy
            audio_np = resampy.resample(audio_np, sr, 16000)
        audio = audio_np
    except Exception:
        # Fallback to whisperx native loader
        audio = whisperx.load_audio(wav_path)

    emit_progress(phase="transcribing", detail="Recognizing speech (Whisper)")
    t0 = time.time()
    result = model.transcribe(audio, batch_size=4, language=language)
    print(f"[WhisperX] Transcription done in {time.time()-t0:.1f}s", file=sys.stderr)

    if not result.get("segments"):
        print("[WhisperX] No segments found.", file=sys.stderr)
        return []

    detected_lang = result.get("language", language)
    print(f"[WhisperX] Detected language: {detected_lang}", file=sys.stderr)

    # Step 2: Forced alignment with wav2vec2
    emit_progress(phase="aligning", detail="Forced alignment (wav2vec2) - first run downloads ~300MB")
    set_hf_offline(False)
    t0 = time.time()
    aligned = False
    alignment_error = None
    try:
        align_model, metadata = whisperx.load_align_model(
            language_code=detected_lang, device=device)
        result = whisperx.align(
            result["segments"], align_model, metadata, audio, device,
            return_char_alignments=False)
        aligned = True
        print(f"[WhisperX] Alignment done in {time.time()-t0:.1f}s", file=sys.stderr)
        del align_model  # free memory
    except Exception as e:
        print(f"[WhisperX] Alignment failed ({type(e).__name__}: {e}) - using stable-whisper fallback",
              file=sys.stderr)
        alignment_error = e
    finally:
        set_hf_offline(True)

    if alignment_error is not None:
        global WHISPERX_ALIGNMENT_FAILED
        WHISPERX_ALIGNMENT_FAILED = True
        emit_progress(
            phase="aligning",
            detail="Alignment unavailable; switching to stable-whisper word timing")
        # Unaligned WhisperX segments contain no word timestamps. ReaTitles
        # needs those timestamps to distinguish removed speech from silence,
        # so use the same cached model through stable-whisper as a fallback.
        return transcribe_stable(
            wav_path, model_size, language, duration, emit_progress)

    emit_progress(phase="aligning", detail=f"Alignment {'OK' if aligned else 'skipped (fallback)'}")

    # Build output
    result_data = []
    for seg in result.get("segments", []):
        text = seg.get("text", "").strip()
        if not text:
            continue
        words = []
        for w in seg.get("words", []):
            ws = w.get("start")
            we = w.get("end")
            wt = w.get("word", "")
            if ws is not None and we is not None and wt:
                words.append([round(ws, 4), round(we, 4), wt])
        result_data.append([
            round(seg.get("start", 0), 4),
            round(seg.get("end", 0), 4),
            text,
            words
        ])
        print(f"[WhisperX] {seg.get('start', 0):.2f}-{seg.get('end', 0):.2f}: {text}",
              file=sys.stderr)
    return result_data


# ── stable-whisper fallback backend ──────────────────────────────────────────

def transcribe_stable(wav_path, model_size, language, duration, emit_progress):
    cached = find_cached_model(model_size)
    if cached:
        model_source = cached
        local_only = True
    else:
        set_hf_offline(False)
        model_source = model_size
        local_only = False
        print(f"[stable-whisper] Downloading model: {model_size}", file=sys.stderr)

    import stable_whisper
    emit_progress(phase="model", detail=f"Loading model (stable-whisper): {model_size}")
    t0 = time.time()
    model = stable_whisper.load_faster_whisper(
        model_source, device="cpu", compute_type="int8",
        cpu_threads=CPU_COUNT, num_workers=min(4, CPU_COUNT),
        local_files_only=local_only)
    set_hf_offline(True)
    print(f"[stable-whisper] Model loaded in {time.time()-t0:.1f}s", file=sys.stderr)
    emit_progress(phase="model_ready", detail="Model ready")

    t0 = time.time()
    result = model.transcribe_stable(
        wav_path, language=language,
        beam_size=5, patience=1.2, temperature=0.0,
        condition_on_previous_text=False,
        suppress_silence=True, vad=True)
    print(f"[stable-whisper] Done in {time.time()-t0:.1f}s", file=sys.stderr)

    result_data = []
    for seg in result.segments:
        text = seg.text.strip()
        if not text:
            continue
        words = []
        for word in (seg.words or []):
            if word.start is not None and word.end is not None and word.word:
                words.append([round(word.start, 4), round(word.end, 4), word.word])
        result_data.append([round(seg.start, 4), round(seg.end, 4), text, words])
        print(f"[stable-whisper] {seg.start:.2f}-{seg.end:.2f}: {text}", file=sys.stderr)
    return result_data


# ── Main ─────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--items", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--model", default="small")
    parser.add_argument("--language", default="ru")
    parser.add_argument("--status", required=True)
    parser.add_argument("--progress", required=True)
    parser.add_argument("--backend", default="auto",
                        choices=["auto", "whisperx", "stable"],
                        help="auto=whisperx if available, else stable-whisper")
    args = parser.parse_args()

    backend = args.backend
    if backend == "auto":
        backend = "whisperx" if HAVE_WHISPERX else "stable"
    print(f"[Setup] Backend: {backend}  (whisperx available: {HAVE_WHISPERX})",
          file=sys.stderr)
    print(f"[Setup] CPU threads: {CPU_COUNT}", file=sys.stderr)

    started_at = time.time()
    progress_state = {
        "percent": 0.0, "phase": "starting",
        "detail": "Starting transcription",
        "item": 0, "total_items": 0, "current_file": "",
        "text": "", "elapsed": 0.0,
        "backend": backend,
    }

    def emit_progress(**changes):
        progress_state.update(changes)
        progress_state["percent"] = max(0.0, min(1.0, float(progress_state.get("percent", 0.0))))
        progress_state["elapsed"] = round(time.time() - started_at, 1)
        write_status(args.progress, progress_state)

    emit_progress()

    with open(args.items, "r", encoding="utf-8") as f:
        items = json.load(f)
    total_duration = sum(max(0.0, float(item.get("duration", 0))) for item in items)
    completed_duration = 0.0
    emit_progress(total_items=len(items))

    all_results = []

    for item_number, item in enumerate(items, 1):
        wav = item["wav"]
        duration = max(0.0, float(item["duration"]))
        idx = item.get("index", 0)
        base_fraction = completed_duration / total_duration if total_duration > 0 else 0.0
        emit_progress(
            percent=base_fraction, phase="transcribing",
            item=item_number, total_items=len(items),
            current_file=os.path.basename(wav), text="")
        print(f"\n[Item {idx}] {os.path.basename(wav)}", file=sys.stderr)

        if not os.path.isfile(wav):
            print(f"[Item {idx}] Source WAV not found! path={wav}", file=sys.stderr)
            all_results.append([])
            completed_duration += duration
            continue

        try:
            if backend == "whisperx" and not WHISPERX_ALIGNMENT_FAILED:
                segments = transcribe_whisperx(
                    wav, args.model, args.language, duration, emit_progress)
            else:
                if backend == "whisperx":
                    progress_state["backend"] = "stable"
                segments = transcribe_stable(
                    wav, args.model, args.language, duration, emit_progress)
            all_results.append(segments)
        except Exception as e:
            import traceback
            traceback.print_exc()
            print(f"[Item {idx}] Error: {e}", file=sys.stderr)
            all_results.append([])

        completed_duration += duration
        emit_progress(
            percent=(completed_duration / total_duration if total_duration > 0
                     else item_number / len(items)),
            phase="item_done", detail="Audio item completed")

    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(all_results, f, ensure_ascii=False, indent=2)
    emit_progress(percent=1.0, phase="done", detail="Transcription completed")
    print(f"\n[Done] {args.output}", file=sys.stderr)


if __name__ == "__main__":
    status_path = None
    if "--status" in sys.argv:
        try:
            status_path = sys.argv[sys.argv.index("--status") + 1]
        except (ValueError, IndexError):
            pass
    try:
        main()
    except BaseException as exc:
        if status_path:
            try:
                write_status(status_path, {"ok": False, "error": str(exc)})
            except Exception:
                pass
        raise
    else:
        write_status(status_path, {"ok": True})
