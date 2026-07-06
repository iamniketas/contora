#!/usr/bin/env python3
"""
Sortformer Diarization HTTP Server - persistent process, model loaded once.

Uses NVIDIA NeMo's streaming Sortformer model (nvidia/diar_streaming_sortformer_4spk-v2)
for offline speaker diarization of arbitrarily long audio (handles chunking internally).
Max 4 speakers per session (model limitation).

Runs inside Dictator's shared python-asr venv (already has nemo_toolkit[asr] installed
for Parakeet ASR support) - no separate Python environment needed.
"""
import os
import sys
import tempfile
import logging
from pathlib import Path
from flask import Flask, request, jsonify

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = Flask(__name__)
app.config["JSON_AS_ASCII"] = False

model = None
model_info = {}

DEFAULT_MODEL_ID = "nvidia/diar_streaming_sortformer_4spk-v2"

# Streaming config per model card (units: 80ms frames)
STREAMING_CONFIG = {
    "chunk_len": 340,
    "chunk_right_context": 40,
    "fifo_len": 40,
    "spkcache_update_period": 300,
    "spkcache_len": 188,
}


def load_model(model_ref: str):
    global model, model_info

    from nemo.collections.asr.models import SortformerEncLabelModel

    logger.info("Loading Sortformer model '%s'...", model_ref)

    path_obj = Path(model_ref).expanduser()
    if path_obj.suffix.lower() == ".nemo" and path_obj.exists():
        diar_model = SortformerEncLabelModel.restore_from(restore_path=str(path_obj))
    else:
        diar_model = SortformerEncLabelModel.from_pretrained(model_ref)

    diar_model.eval()

    for key, value in STREAMING_CONFIG.items():
        setattr(diar_model.sortformer_modules, key, value)

    model = diar_model
    model_info = {"model": model_ref, "status": "loaded", "max_speakers": 4}
    logger.info("Sortformer model loaded successfully")


@app.route("/health", methods=["GET"])
def health():
    return jsonify({"status": "ok", "model": model_info})


@app.route("/diarize", methods=["POST"])
def diarize():
    if model is None:
        return jsonify({"error": "Model not loaded"}), 500

    if "file" not in request.files:
        return jsonify({"error": "No file provided"}), 400

    audio_file = request.files["file"]
    temp_file = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
    temp_path = temp_file.name
    temp_file.close()
    audio_file.save(temp_path)

    try:
        logger.info("Diarizing %s...", temp_path)
        # verbose=False disables NeMo's tqdm progress bars. On Windows those bars write ANSI/CR
        # sequences to stdout/stderr, and when the stream is a redirected pipe (as when C# hosts
        # this server) that write intermittently raises OSError [Errno 22] Invalid argument.
        # num_workers=0 keeps the DataLoader in-thread (no Windows spawn from a Flask worker thread).
        predicted_segments = model.diarize(
            audio=[temp_path], batch_size=1, num_workers=0, verbose=False)

        segments = []
        for seg in predicted_segments[0]:
            # Each seg is a string "start end speaker_N" (space-separated).
            parts = str(seg).split()
            if len(parts) != 3:
                continue
            start_s, end_s, speaker = parts
            segments.append({
                "start": float(start_s),
                "end": float(end_s),
                "speaker": speaker,
            })

        logger.info("Diarization complete: %d segments", len(segments))
        return jsonify({"segments": segments})

    except Exception as e:
        import traceback
        logger.error("Diarization failed: %s\n%s", e, traceback.format_exc())
        return jsonify({"error": str(e)}), 500

    finally:
        if os.path.exists(temp_path):
            os.remove(temp_path)


if __name__ == "__main__":
    model_ref = sys.argv[1] if len(sys.argv) > 1 else os.getenv("SORTFORMER_MODEL", DEFAULT_MODEL_ID)
    load_model(model_ref)

    port = int(os.getenv("SORTFORMER_PORT", "5002"))
    logger.info("Starting Sortformer diarization server on port %s...", port)
    app.run(host="127.0.0.1", port=port, debug=False, threaded=True)
