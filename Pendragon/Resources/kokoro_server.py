#!/usr/bin/env python3
"""
Kokoro TTS server for Pendragon.
Install deps: pip install kokoro soundfile misaki[en] fastapi uvicorn
"""
import sys
import io
import os

try:
    import numpy as np
    from kokoro import KPipeline
    import soundfile as sf
    from fastapi import FastAPI, Request
    from fastapi.responses import Response
    import uvicorn
except ImportError as e:
    print(f"IMPORT_ERROR: {e}", flush=True)
    sys.exit(1)

app = FastAPI()
pipeline = None

@app.on_event("startup")
async def startup():
    global pipeline
    print("LOADING_MODEL", flush=True)
    try:
        pipeline = KPipeline(lang_code='a')
        print("MODEL_READY", flush=True)
    except Exception as e:
        print(f"LOAD_ERROR: {e}", flush=True)

@app.get("/health")
async def health():
    return {"ready": pipeline is not None}

@app.post("/speak")
async def speak(request: Request):
    global pipeline
    if pipeline is None:
        return Response(status_code=503)

    body = await request.json()
    text  = body.get("text",  "").strip()
    voice = body.get("voice", "af_heart")
    speed = float(body.get("speed", 1.0))

    if not text:
        return Response(status_code=400)

    try:
        chunks = []
        for _, _, audio in pipeline(text, voice=voice, speed=speed):
            if audio is not None and len(audio) > 0:
                chunks.append(audio)

        if not chunks:
            return Response(status_code=204)

        full_audio = np.concatenate(chunks)
        buf = io.BytesIO()
        sf.write(buf, full_audio, 24000, format="WAV", subtype="PCM_16")
        return Response(content=buf.getvalue(), media_type="audio/wav")
    except Exception as e:
        print(f"SPEAK_ERROR: {e}", flush=True)
        return Response(status_code=500)

if __name__ == "__main__":
    port = int(os.environ.get("KOKORO_PORT", "8765"))
    uvicorn.run(app, host="127.0.0.1", port=port, log_level="error")
