#!/usr/bin/env python3
"""Persistent local host for pyannote/speaker-diarization-community-1."""
import os
import tempfile
from flask import Flask, jsonify, request

app = Flask(__name__)
pipeline = None

MODEL = os.getenv("CONTORA_PYANNOTE_MODEL", "pyannote/speaker-diarization-community-1")


def load_pipeline():
    global pipeline
    from pyannote.audio import Pipeline

    token = os.getenv("HF_TOKEN") or os.getenv("HUGGINGFACE_HUB_TOKEN")
    pipeline = Pipeline.from_pretrained(MODEL, token=token)
    requested_device = os.getenv("CONTORA_PYANNOTE_DEVICE", "auto")
    if requested_device != "cpu":
        import torch
        if torch.cuda.is_available():
            pipeline.to(torch.device("cuda"))


def load_audio_waveform(path):
    """Load Contora's WAV into memory and avoid torchcodec/FFmpeg entirely."""
    import soundfile as sf
    import torch

    samples, sample_rate = sf.read(path, dtype="float32", always_2d=True)
    # soundfile yields [frames, channels]; pyannote expects [channels, frames].
    waveform = torch.from_numpy(samples.T.copy())
    return {"waveform": waveform, "sample_rate": sample_rate}


@app.route("/health", methods=["GET"])
def health():
    return jsonify({"status": "ok", "model": MODEL, "backend": "pyannote-community-1"})


@app.route("/diarize", methods=["POST"])
def diarize():
    if "file" not in request.files:
        return jsonify({"error": "No audio file provided"}), 400

    source = request.files["file"]
    handle = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
    path = handle.name
    handle.close()
    source.save(path)

    try:
        kwargs = {}
        constraint = request.form.get("constraint", "auto")
        count = request.form.get("count", type=int)
        if count and count > 0:
            if constraint == "exact":
                kwargs["num_speakers"] = count
            elif constraint == "minimum":
                kwargs["min_speakers"] = count
            elif constraint == "maximum":
                kwargs["max_speakers"] = count

        # Passing a file path makes pyannote.audio 4 delegate decoding to
        # torchcodec, which on Windows requires a separately compatible FFmpeg
        # DLL build. Contora sends WAV, so an in-memory waveform is reliable and
        # avoids that optional native dependency completely.
        output = pipeline(load_audio_waveform(path), **kwargs)
        annotation = getattr(output, "exclusive_speaker_diarization", None)
        if annotation is None:
            annotation = output.speaker_diarization
        segments = [
            {"start": turn.start, "end": turn.end, "speaker": speaker}
            for turn, speaker in annotation
        ]
        return jsonify({"segments": segments})
    except Exception as exc:
        return jsonify({"error": str(exc)}), 500
    finally:
        try:
            os.remove(path)
        except OSError:
            pass


if __name__ == "__main__":
    try:
        load_pipeline()
    except Exception as exc:
        raise SystemExit(f"Could not load pyannote Community-1: {exc}")
    app.run(host="127.0.0.1", port=int(os.getenv("CONTORA_PYANNOTE_PORT", "5003")), debug=False, threaded=True)
