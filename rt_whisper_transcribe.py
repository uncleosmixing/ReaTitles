#!/usr/bin/env python3
"""
rt_whisper_transcribe.py - Extract audio and transcribe using faster-whisper
Called by REAPER Lua script for subtitle generation
"""

import argparse
import json
import sys
import os
import subprocess
import shutil
import time
import tempfile
import multiprocessing

# Cached models are always preferred. Network access is enabled temporarily only
# when the requested model is absent and must be downloaded once.
os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["TRANSFORMERS_OFFLINE"] = "1"
os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"

CPU_COUNT = multiprocessing.cpu_count()


def write_status(path, payload):
    """Publish JSON without letting a transient Windows file lock stop Whisper."""
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
    try:
        if os.path.isfile(tmp_path):
            os.remove(tmp_path)
    except OSError:
        pass
    print(f"[Status] Could not update {path}: {last_error}", file=sys.stderr)
    return False


def find_ffmpeg():
    if shutil.which("ffmpeg"):
        return shutil.which("ffmpeg")
    if sys.platform == "win32":
        try:
            result = subprocess.run(["where", "ffmpeg"], capture_output=True, text=True,
                                    encoding="utf-8", errors="replace")
            if result.returncode == 0 and result.stdout.strip():
                return result.stdout.strip().split("\n")[0].strip()
        except Exception:
            pass
    home = os.path.expanduser("~")
    for env_var in ["LOCALAPPDATA", "APPDATA", "PROGRAMFILES", "PROGRAMFILES(X86)"]:
        val = os.environ.get(env_var, "")
        if val:
            for sub in ["Microsoft\\WinGet\\Packages", "FFmpeg\\bin", "Gyan\\ffmpeg\\bin"]:
                d = os.path.join(val, sub)
                if os.path.isdir(d):
                    for root, dirs, files in os.walk(d):
                        if "ffmpeg.exe" in files:
                            return os.path.join(root, "ffmpeg.exe")
                        if len(root.split(os.sep)) - len(d.split(os.sep)) > 4:
                            dirs.clear()
    for p in [os.path.join(home, "AppData", "Local", "Microsoft", "WinGet", "Packages"),
              "C:\\ffmpeg\\bin"]:
        if os.path.isdir(p):
            for root, dirs, files in os.walk(p):
                if "ffmpeg.exe" in files:
                    return os.path.join(root, "ffmpeg.exe")
    return None


def install_ffmpeg():
    """Install FFmpeg on Windows without blocking REAPER's main process."""
    if sys.platform != "win32" or not shutil.which("winget"):
        print("[Setup] Cannot auto-install FFmpeg: WinGet is unavailable.",
              file=sys.stderr)
        return False
    print("[Setup] FFmpeg is missing. Installing Gyan.FFmpeg through WinGet...",
          file=sys.stderr)
    command = [
        "winget", "install", "--id", "Gyan.FFmpeg", "-e",
        "--accept-package-agreements", "--accept-source-agreements", "--silent",
    ]
    try:
        process = subprocess.run(
            command,
            stdout=sys.stderr,
            stderr=sys.stderr,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
        if process.returncode != 0:
            print(f"[Setup] WinGet failed with exit code {process.returncode}.",
                  file=sys.stderr)
            return False
    except Exception as error:
        print(f"[Setup] Could not start WinGet: {error}", file=sys.stderr)
        return False
    return find_ffmpeg() is not None


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


def extract_audio(src_path, start_sec, duration_sec, output_path, ffmpeg_path):
    cmd = [ffmpeg_path, "-y", "-i", src_path,
           "-ss", f"{start_sec:.6f}", "-t", f"{duration_sec:.6f}",
           "-ar", "16000", "-ac", "1", "-f", "wav",
           "-loglevel", "error",
           output_path]
    kwargs = {"capture_output": True, "text": True, "encoding": "utf-8", "errors": "replace"}
    if sys.platform == "win32":
        kwargs["creationflags"] = 0x08000000
    subprocess.run(cmd, **kwargs)
    if not os.path.isfile(output_path):
        print("[Extract] FAILED", file=sys.stderr)
        return False
    return True


def create_model(model_size="small", progress=None):
    cached_model = find_cached_model(model_size)
    if cached_model:
        model_source = cached_model
        local_only = True
        if progress:
            progress(
                phase="model",
                detail=f"Loading cached Whisper model: {model_size}")
    else:
        os.environ["HF_HUB_OFFLINE"] = "0"
        os.environ["TRANSFORMERS_OFFLINE"] = "0"
        model_source = model_size
        local_only = False
        if progress:
            progress(
                phase="model_download",
                detail=f"Downloading Whisper model once: {model_size}")
        print(
            f"[Whisper] Model '{model_size}' is not cached. "
            "Downloading it once from Hugging Face...", file=sys.stderr)

    from faster_whisper import WhisperModel
    print(
        f"[Whisper] Loading model '{model_source}' "
        f"(CPU, int8, {CPU_COUNT} threads)...", file=sys.stderr)
    t0 = time.time()
    model = WhisperModel(
        model_source,
        device="cpu",
        compute_type="int8",
        cpu_threads=CPU_COUNT,
        num_workers=min(4, CPU_COUNT),
        local_files_only=local_only,
    )
    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["TRANSFORMERS_OFFLINE"] = "1"
    print(f"[Whisper] Model loaded in {time.time()-t0:.1f}s", file=sys.stderr)
    if progress:
        progress(phase="model_ready", detail="Whisper model loaded")
    return model


def transcribe_file(model, filepath, language="ru", duration=0, progress=None):
    print(f"[Whisper] Transcribing {os.path.basename(filepath)}...", file=sys.stderr)
    t0 = time.time()
    segments, info = model.transcribe(
        filepath,
        language=language,
        beam_size=5,
        patience=1.2,
        temperature=0.0,
        condition_on_previous_text=False,
        word_timestamps=True,
        vad_filter=True,
        vad_parameters=dict(
            min_silence_duration_ms=180,
            speech_pad_ms=60,
            threshold=0.35
        ))
    result = []
    for seg in segments:
        text = seg.text.strip()
        if text:
            words = []
            for word in (seg.words or []):
                if word.start is not None and word.end is not None and word.word:
                    words.append([
                        round(word.start, 3),
                        round(word.end, 3),
                        word.word,
                    ])
            result.append([round(seg.start, 3), round(seg.end, 3), text, words])
            print(f"[Whisper] {seg.start:.2f}-{seg.end:.2f}: {text}", file=sys.stderr)
        if progress:
            local_fraction = min(1.0, seg.end / duration) if duration > 0 else 0.0
            try:
                progress(local_fraction=local_fraction, text=text)
            except Exception as exc:
                # Progress is optional UI telemetry. Never discard recognized
                # segments because Windows briefly locked the progress file.
                print(f"[Progress] Update skipped: {exc}", file=sys.stderr)
    elapsed = time.time() - t0
    print(f"[Whisper] Done in {elapsed:.1f}s", file=sys.stderr)
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--items", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--model", default="small")
    parser.add_argument("--language", default="ru")
    parser.add_argument("--status", required=True)
    parser.add_argument("--progress", required=True)
    args = parser.parse_args()

    started_at = time.time()
    progress_state = {
        "percent": 0.0,
        "phase": "starting",
        "detail": "Starting transcription",
        "item": 0,
        "total_items": 0,
        "current_file": "",
        "text": "",
        "elapsed": 0.0,
    }

    def emit_progress(**changes):
        progress_state.update(changes)
        progress_state["percent"] = max(
            0.0, min(1.0, float(progress_state.get("percent", 0.0))))
        progress_state["elapsed"] = round(time.time() - started_at, 1)
        write_status(args.progress, progress_state)

    emit_progress()

    ffmpeg = find_ffmpeg()
    if not ffmpeg:
        emit_progress(
            phase="setup",
            detail="Installing FFmpeg through WinGet",
            text="")
        if install_ffmpeg():
            ffmpeg = find_ffmpeg()
    if not ffmpeg:
        print("[ERROR] FFmpeg not found and automatic installation failed.",
              file=sys.stderr)
        raise RuntimeError(
            "FFmpeg is missing. Automatic WinGet installation failed; "
            "see the transcription log.")
    print(f"[Setup] FFmpeg: {ffmpeg}", file=sys.stderr)
    print(f"[Setup] CPU threads: {CPU_COUNT}", file=sys.stderr)

    with open(args.items, "r", encoding="utf-8") as f:
        items = json.load(f)
    total_duration = sum(max(0.0, float(item.get("duration", 0))) for item in items)
    completed_duration = 0.0
    emit_progress(total_items=len(items), phase="model",
                  detail=f"Preparing Whisper model: {args.model}")

    tmpdir = tempfile.mkdtemp(prefix="reatitles_")
    all_results = []

    model = create_model(args.model, progress=emit_progress)

    for item_number, item in enumerate(items, 1):
        src = item["src"]
        start = item["start"]
        duration = max(0.0, float(item["duration"]))
        idx = item.get("index", 0)
        base_fraction = completed_duration / total_duration if total_duration > 0 else 0.0
        emit_progress(
            percent=base_fraction,
            phase="extracting",
            detail="Extracting audio with FFmpeg",
            item=item_number,
            total_items=len(items),
            current_file=os.path.basename(src),
            text="",
        )
        print(f"\n[Item {idx}] {os.path.basename(src)}", file=sys.stderr)
        if not os.path.isfile(src):
            print(f"[Item {idx}] Source not found!", file=sys.stderr)
            all_results.append([])
            completed_duration += duration
            emit_progress(percent=(completed_duration / total_duration
                                   if total_duration > 0 else item_number / len(items)))
            continue
        wav = os.path.join(tmpdir, f"item_{idx}.wav")
        if not extract_audio(src, start, duration, wav, ffmpeg):
            all_results.append([])
            completed_duration += duration
            emit_progress(percent=(completed_duration / total_duration
                                   if total_duration > 0 else item_number / len(items)))
            continue
        try:
            emit_progress(phase="transcribing", detail="Recognizing speech")

            def on_segment(local_fraction=0.0, text="", **_):
                processed = completed_duration + duration * local_fraction
                overall = processed / total_duration if total_duration > 0 else 0.0
                emit_progress(percent=overall, phase="transcribing",
                              detail="Recognizing speech", text=text)

            all_results.append(transcribe_file(
                model, wav, args.language, duration=duration, progress=on_segment))
        except Exception as e:
            print(f"[Item {idx}] Error: {e}", file=sys.stderr)
            all_results.append([])
        finally:
            if os.path.isfile(wav):
                os.remove(wav)
        completed_duration += duration
        emit_progress(percent=(completed_duration / total_duration
                               if total_duration > 0 else item_number / len(items)),
                      phase="item_done", detail="Audio item completed")

    shutil.rmtree(tmpdir, ignore_errors=True)
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
