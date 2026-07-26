"""
Whisper Transcription Server
Accepts audio uploads, transcribes Swiss German dialect to Standard German.
Uses faster-whisper for efficient CPU/GPU inference.
Supports chunked transcription for long recordings (up to 3h).
"""

import os
import json
import tempfile
import logging
import subprocess
import math
from pathlib import Path

from fastapi import FastAPI, UploadFile, File, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse
from faster_whisper import WhisperModel

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# ── Configuration ──────────────────────────────────────────────────────────
MODEL_SIZE = os.getenv("WHISPER_MODEL", "large-v3")
DEVICE = os.getenv("WHISPER_DEVICE", "cpu")          # "cpu" or "cuda"
COMPUTE_TYPE = os.getenv("WHISPER_COMPUTE_TYPE", "int8")  # "int8" for CPU, "float16" for GPU
MODEL_DIR = os.getenv("WHISPER_MODEL_DIR", "/app/models")
CHUNK_MINUTES = int(os.getenv("WHISPER_CHUNK_MINUTES", "10"))

# Swiss German transcription prompt – steers Whisper towards Standard German output
SWISS_GERMAN_PROMPT = (
    "Dies ist das Protokoll einer Vereinssitzung. "
    "Die Teilnehmer sprechen Schweizerdeutsch (Zürichdeutsch/Thurgauerdeutsch). "
    "Bitte transkribiere direkt in sauberes, formelles Hochdeutsch."
)

# ── Model loading (at startup) ──────────────────────────────────────────────
logger.info(f"Loading Whisper model '{MODEL_SIZE}' on device='{DEVICE}' compute_type='{COMPUTE_TYPE}' ...")
logger.info(f"Model cache directory: {MODEL_DIR}")

model = WhisperModel(
    MODEL_SIZE,
    device=DEVICE,
    compute_type=COMPUTE_TYPE,
    download_root=MODEL_DIR,
)
logger.info("Model loaded successfully.")

# ── FastAPI App ─────────────────────────────────────────────────────────────
app = FastAPI(title="Whisper Transcription API", version="2.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


def get_audio_duration(file_path: str) -> float:
    """Get duration of audio file in seconds using ffprobe."""
    try:
        result = subprocess.run(
            ["ffprobe", "-v", "quiet", "-show_entries", "format=duration",
             "-of", "csv=p=0", file_path],
            capture_output=True, text=True, timeout=30
        )
        return float(result.stdout.strip())
    except Exception:
        return 0.0


def split_audio(file_path: str, chunk_seconds: int, output_dir: str) -> list[str]:
    """Split audio file into chunks using ffmpeg. Returns list of chunk paths."""
    duration = get_audio_duration(file_path)
    if duration <= 0:
        return [file_path]

    num_chunks = math.ceil(duration / chunk_seconds)
    if num_chunks <= 1:
        return [file_path]

    chunk_paths = []
    for i in range(num_chunks):
        start = i * chunk_seconds
        chunk_path = os.path.join(output_dir, f"chunk_{i:04d}.wav")
        subprocess.run(
            ["ffmpeg", "-y", "-i", file_path,
             "-ss", str(start), "-t", str(chunk_seconds),
             "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le",
             chunk_path],
            capture_output=True, timeout=120
        )
        if os.path.exists(chunk_path) and os.path.getsize(chunk_path) > 0:
            chunk_paths.append(chunk_path)

    return chunk_paths if chunk_paths else [file_path]


def transcribe_file(file_path: str) -> tuple[str, float]:
    """Transcribe a single audio file. Returns (text, duration_seconds)."""
    segments, info = model.transcribe(
        file_path,
        language="de",
        initial_prompt=SWISS_GERMAN_PROMPT,
        beam_size=5,
        best_of=5,
        temperature=0.0,
        vad_filter=True,
        vad_parameters={"min_silence_duration_ms": 500},
    )
    text = " ".join(segment.text.strip() for segment in segments)
    return text, info.duration


@app.get("/health")
def health():
    return {"status": "ok", "model": MODEL_SIZE, "device": DEVICE}


@app.post("/transcribe")
async def transcribe(audio: UploadFile = File(...)):
    """
    Accepts an audio file (webm, wav, mp3, ogg, mp4, …) and returns the
    transcription in Standard German. For short files (< chunk threshold).
    """
    suffix = Path(audio.filename or "audio.webm").suffix or ".webm"
    with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as tmp:
        content = await audio.read()
        tmp.write(content)
        tmp_path = tmp.name

    try:
        logger.info(f"Transcribing {audio.filename} ({len(content)} bytes) …")
        text, duration = transcribe_file(tmp_path)
        duration_min = round(duration / 60, 1)
        logger.info(f"Transcription complete. Duration: {duration_min} min, chars: {len(text)}")

        return {
            "text": text,
            "language": "de",
            "duration_seconds": round(duration, 1),
        }

    except Exception as e:
        logger.error(f"Transcription failed: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail=f"Transkription fehlgeschlagen: {str(e)}")

    finally:
        os.unlink(tmp_path)


@app.post("/transcribe-chunked")
async def transcribe_chunked(
    audio: UploadFile = File(...),
    chunk_minutes: int = Query(default=CHUNK_MINUTES, ge=1, le=30),
):
    """
    Transcribes long audio files by splitting into chunks.
    Returns Server-Sent Events (SSE) with progress updates.

    Each SSE event is a JSON object:
      - {"type": "progress", "chunk": 1, "total": 18, "percent": 5}
      - {"type": "chunk_text", "chunk": 1, "text": "..."}
      - {"type": "complete", "text": "...", "duration_seconds": 10800}
      - {"type": "error", "detail": "..."}
    """
    suffix = Path(audio.filename or "audio.webm").suffix or ".webm"
    with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as tmp:
        content = await audio.read()
        tmp.write(content)
        tmp_path = tmp.name

    async def generate():
        chunk_dir = tempfile.mkdtemp()
        try:
            # Split audio into chunks
            chunk_seconds = chunk_minutes * 60
            logger.info(f"Splitting {audio.filename} ({len(content)} bytes) into {chunk_minutes}-min chunks …")
            chunks = split_audio(tmp_path, chunk_seconds, chunk_dir)
            total = len(chunks)
            logger.info(f"Created {total} chunks")

            all_texts = []
            total_duration = 0.0

            for i, chunk_path in enumerate(chunks):
                try:
                    text, duration = transcribe_file(chunk_path)
                    all_texts.append(text)
                    total_duration += duration
                    pct = round(((i + 1) / total) * 100)

                    yield f"data: {json.dumps({'type': 'progress', 'chunk': i+1, 'total': total, 'percent': pct})}\n\n"
                    yield f"data: {json.dumps({'type': 'chunk_text', 'chunk': i+1, 'text': text})}\n\n"

                    logger.info(f"Chunk {i+1}/{total} done ({pct}%)")
                except Exception as e:
                    logger.error(f"Chunk {i+1} failed: {e}", exc_info=True)
                    yield f"data: {json.dumps({'type': 'error', 'detail': f'Chunk {i+1} fehlgeschlagen: {str(e)}'})}\n\n"

            full_text = " ".join(all_texts)
            yield f"data: {json.dumps({'type': 'complete', 'text': full_text, 'duration_seconds': round(total_duration, 1)})}\n\n"

        except Exception as e:
            logger.error(f"Chunked transcription failed: {e}", exc_info=True)
            yield f"data: {json.dumps({'type': 'error', 'detail': str(e)})}\n\n"

        finally:
            # Cleanup
            os.unlink(tmp_path)
            for f in Path(chunk_dir).glob("*"):
                f.unlink()
            os.rmdir(chunk_dir)

    return StreamingResponse(generate(), media_type="text/event-stream")
