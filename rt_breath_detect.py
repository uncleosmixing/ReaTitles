#!/usr/bin/env python3
"""
rt_breath_detect.py - Detect breaths in audio using YAMNet ONNX model
Called by REAPER Lua script for breath volume automation
"""

import argparse
import csv
import json
import sys
import os
import struct
import time
import numpy as np


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
    try:
        if os.path.isfile(tmp_path):
            os.remove(tmp_path)
    except OSError:
        pass
    print(f"[Status] Could not update {path}: {last_error}", file=sys.stderr)
    return False


def read_wav(path):
    with open(path, "rb") as f:
        riff = f.read(4)
        if riff != b"RIFF":
            raise ValueError("Not a WAV file")
        f.read(4)
        wave = f.read(4)
        if wave != b"WAVE":
            raise ValueError("Not a WAV file")

        num_channels = 0
        sample_rate = 0
        bits_per_sample = 0
        data = None

        while True:
            chunk_id = f.read(4)
            if len(chunk_id) < 4:
                break
            chunk_size = struct.unpack("<I", f.read(4))[0]
            if chunk_id == b"fmt ":
                fmt_data = f.read(chunk_size)
                num_channels = struct.unpack("<H", fmt_data[2:4])[0]
                sample_rate = struct.unpack("<I", fmt_data[4:8])[0]
                bits_per_sample = struct.unpack("<H", fmt_data[14:16])[0]
            elif chunk_id == b"data":
                data = f.read(chunk_size)
                break
            else:
                f.seek(chunk_size, 1)

        if data is None:
            raise ValueError("No data chunk in WAV")

        if bits_per_sample == 16:
            samples = np.frombuffer(data, dtype=np.int16).astype(np.float32) / 32768.0
        elif bits_per_sample == 32:
            samples = np.frombuffer(data, dtype=np.int32).astype(np.float32) / 2147483648.0
        else:
            raise ValueError(f"Unsupported bit depth: {bits_per_sample}")

        if num_channels > 1:
            samples = samples.reshape(-1, num_channels)[:, 0]

        return samples, sample_rate


def resample_to_16k(samples, original_sr):
    if original_sr == 16000:
        return samples
    import scipy.signal
    num_samples = int(len(samples) * 16000 / original_sr)
    resampled = scipy.signal.resample_poly(samples, 16000, original_sr)
    return resampled.astype(np.float32)


def load_class_map(csv_path):
    class_map = {}
    try:
        with open(csv_path, newline="", encoding="utf-8") as csvfile:
            reader = csv.reader(csvfile)
            next(reader)
            for row in reader:
                class_id = int(row[0])
                class_name = row[2]
                class_map[class_id] = class_name
    except Exception as e:
        print(f"[Warning] Could not load class map: {e}", file=sys.stderr)
    return class_map


def detect_breaths_from_scores(scores, class_map, threshold, min_duration_ms, merge_gap_ms):
    breath_classes = []
    for cid, name in class_map.items():
        if "breathing" in name.lower() or "breath" in name.lower():
            breath_classes.append(cid)

    if not breath_classes:
        breath_classes = [36]

    print(f"[Detect] Breath classes: {breath_classes}", file=sys.stderr)

    if scores.ndim == 3:
        scores = scores[0]

    frame_scores = np.max(scores[:, breath_classes], axis=1)

    binary = (frame_scores >= threshold).astype(np.int32)

    regions = []
    in_region = False
    start_frame = 0

    for i in range(len(binary)):
        if binary[i] == 1 and not in_region:
            in_region = True
            start_frame = i
        elif binary[i] == 0 and in_region:
            in_region = False
            regions.append((start_frame, i - 1))

    if in_region:
        regions.append((start_frame, len(binary) - 1))

    merged = []
    for start_f, end_f in regions:
        start_time = start_f * 0.01
        end_time = (end_f + 1) * 0.01
        avg_confidence = float(np.mean(frame_scores[start_f:end_f + 1]))

        if merged and (start_time - merged[-1]["end"]) < merge_gap_ms / 1000.0:
            merged[-1]["end"] = end_time
            merged[-1]["confidence"] = max(merged[-1]["confidence"], avg_confidence)
        else:
            merged.append({
                "start": round(start_time, 4),
                "end": round(end_time, 4),
                "confidence": round(avg_confidence, 4),
            })

    filtered = [b for b in merged if (b["end"] - b["start"]) * 1000 >= min_duration_ms]
    return filtered


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--items", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--class-map", default="")
    parser.add_argument("--threshold", type=float, default=0.3)
    parser.add_argument("--min-duration", type=float, default=100)
    parser.add_argument("--merge-gap", type=float, default=300)
    parser.add_argument("--status", required=True)
    parser.add_argument("--progress", required=True)
    args = parser.parse_args()

    started_at = time.time()
    progress_state = {
        "percent": 0.0,
        "phase": "starting",
        "detail": "Starting breath detection",
        "item": 0,
        "total_items": 0,
        "elapsed": 0.0,
    }

    def emit_progress(**changes):
        progress_state.update(changes)
        progress_state["percent"] = max(
            0.0, min(1.0, float(progress_state.get("percent", 0.0))))
        progress_state["elapsed"] = round(time.time() - started_at, 1)
        write_status(args.progress, progress_state)

    emit_progress()

    try:
        import onnxruntime as ort
    except ImportError:
        print("[Setup] Installing onnxruntime...", file=sys.stderr)
        import subprocess
        subprocess.run([sys.executable, "-m", "pip", "install", "onnxruntime"],
                       capture_output=True)
        import onnxruntime as ort

    try:
        import scipy.signal
    except ImportError:
        print("[Setup] Installing scipy...", file=sys.stderr)
        import subprocess
        subprocess.run([sys.executable, "-m", "pip", "install", "scipy"],
                       capture_output=True)

    class_map = {}
    if args.class_map and os.path.isfile(args.class_map):
        class_map = load_class_map(args.class_map)
        print(f"[Model] Loaded {len(class_map)} classes from {args.class_map}", file=sys.stderr)

    print(f"[Model] Loading {args.model}", file=sys.stderr)
    emit_progress(phase="model", detail="Loading YAMNet ONNX model")
    session = ort.InferenceSession(args.model, providers=["CPUExecutionProvider"])
    input_name = session.get_inputs()[0].name
    input_shape = session.get_inputs()[0].shape
    print(f"[Model] Input: {input_name}, shape: {input_shape}", file=sys.stderr)
    print(f"[Model] Loaded in {time.time()-started_at:.1f}s", file=sys.stderr)
    emit_progress(phase="model_ready", detail="Model loaded")

    with open(args.items, "r", encoding="utf-8") as f:
        items = json.load(f)
    total_duration = sum(max(0.0, float(item.get("duration", 0))) for item in items)
    completed_duration = 0.0

    all_results = []

    for item_number, item in enumerate(items, 1):
        wav_path = item["wav"]
        idx = item.get("index", 0)
        base_fraction = completed_duration / total_duration if total_duration > 0 else 0.0

        emit_progress(
            percent=base_fraction,
            phase="detecting",
            detail="Analyzing audio for breaths",
            item=item_number,
            total_items=len(items),
        )
        print(f"\n[Item {idx}] Processing {os.path.basename(wav_path)}", file=sys.stderr)

        if not os.path.isfile(wav_path):
            print(f"[Item {idx}] WAV not found: {wav_path}", file=sys.stderr)
            all_results.append({"breaths": [], "sample_rate": 16000, "duration": 0})
            completed_duration += float(item.get("duration", 0))
            continue

        try:
            samples, sample_rate = read_wav(wav_path)
            duration = len(samples) / sample_rate
            print(f"[Item {idx}] Audio: {duration:.1f}s, {sample_rate}Hz", file=sys.stderr)

            samples_16k = resample_to_16k(samples, sample_rate)

            max_val = np.max(np.abs(samples_16k))
            if max_val > 0:
                samples_16k = samples_16k / max_val

            chunk_size = 48000
            all_scores = []
            num_chunks = max(1, (len(samples_16k) + chunk_size - 1) // chunk_size)

            for ci in range(num_chunks):
                start = ci * chunk_size
                end = min(start + chunk_size, len(samples_16k))
                chunk = samples_16k[start:end]

                if len(chunk) < chunk_size:
                    chunk = np.pad(chunk, (0, chunk_size - len(chunk)))

                audio_input = chunk.astype(np.float32)

                emit_progress(
                    percent=base_fraction + (ci / num_chunks) * 0.1,
                    phase="inferring",
                    detail=f"Running neural network ({ci+1}/{num_chunks})")

                result = session.run(None, {input_name: audio_input})
                scores = result[0]
                all_scores.append(scores)

            if all_scores:
                combined_scores = np.concatenate(all_scores, axis=0)
                breaths = detect_breaths_from_scores(
                    combined_scores, class_map,
                    args.threshold, args.min_duration, args.merge_gap)
            else:
                breaths = []

            print(f"[Item {idx}] Found {len(breaths)} breaths", file=sys.stderr)
            for b in breaths:
                print(f"  {b['start']:.2f}-{b['end']:.2f} (conf: {b['confidence']:.2f})",
                      file=sys.stderr)

            all_results.append({
                "breaths": breaths,
                "sample_rate": 16000,
                "duration": round(duration, 4),
            })

        except Exception as e:
            print(f"[Item {idx}] Error: {e}", file=sys.stderr)
            import traceback
            traceback.print_exc(file=sys.stderr)
            all_results.append({"breaths": [], "sample_rate": 16000, "duration": 0})

        completed_duration += float(item.get("duration", 0))
        emit_progress(
            percent=(completed_duration / total_duration if total_duration > 0
                     else item_number / len(items)),
            phase="item_done", detail="Item completed")

    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(all_results, f, ensure_ascii=False, indent=2)

    emit_progress(percent=1.0, phase="done", detail="Breath detection completed")
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
