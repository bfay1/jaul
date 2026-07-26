"""ElevenLabs text-to-speech — strictly opt-in, never on the critical path.

Synthesizes the agent's spoken line into audio for Twilio's <Play> verb, in
place of Twilio's built-in Polly voice. Owns the ElevenLabs REST call directly
(no `elevenlabs` SDK) so it stays a small, dependency-light, offline-testable
module — the same reasoning transport.py gives for avoiding the `twilio` SDK
on its hot path.

Opt-in contract callers rely on: if ELEVENLABS_API_KEY is unset, or the call
fails or times out for any reason, `synthesize()` returns None rather than
raising. server.py treats None as "fall back to the Polly <Say> voice for
this turn" — a live call must never crash or stall because ElevenLabs is
unreachable, slow, or out of quota.
"""
import os
import uuid

import requests

_ELEVENLABS_TTS_URL = "https://api.elevenlabs.io/v1/text-to-speech/{voice_id}"
_DEFAULT_MODEL_ID = "eleven_flash_v2_5"
_TIMEOUT_SECONDS = 10

# Twilio phone calls are 8kHz mu-law under the hood. ElevenLabs defaults to a
# 44.1kHz MP3, which Twilio then has to transcode for every turn - exactly the
# choppy, cutting-in-and-out artifacts a mismatched-format transcode produces.
# Asking ElevenLabs for ulaw_8000 directly means Twilio's <Play> gets audio
# already in its native telephony format, with no transcoding step at all.
_OUTPUT_FORMAT = "ulaw_8000"
_CONTENT_TYPE = "audio/ulaw"

# clip_id -> (audio_bytes, content_type). In-memory only: fine for a
# single-process demo server (same assumption server.py's `_sessions` dict
# already makes) since uvicorn's default single-worker event loop means no
# concurrent-write races. Would need a shared store (Redis, etc.) if this
# server ever ran with multiple workers/processes.
_clips: dict[str, tuple[bytes, str]] = {}
_MAX_CACHED_CLIPS = 50


def enabled() -> bool:
    """Whether ElevenLabs should be attempted at all."""
    return bool(os.environ.get("ELEVENLABS_API_KEY"))


def synthesize(text: str) -> str | None:
    """Synthesize `text`, cache the audio, and return its clip id.

    Returns None (never raises) if ElevenLabs is not configured, or if the
    call fails, times out, or comes back with a non-200 status.
    """
    if not enabled():
        return None

    voice_id = os.environ.get("ELEVENLABS_VOICE_ID")
    if not voice_id:
        return None

    api_key = os.environ["ELEVENLABS_API_KEY"]
    model_id = os.environ.get("ELEVENLABS_MODEL_ID") or _DEFAULT_MODEL_ID

    try:
        resp = requests.post(
            _ELEVENLABS_TTS_URL.format(voice_id=voice_id),
            params={"output_format": _OUTPUT_FORMAT},
            headers={
                "xi-api-key": api_key,
                "Content-Type": "application/json",
            },
            json={"text": text, "model_id": model_id},
            timeout=_TIMEOUT_SECONDS,
        )
    except requests.RequestException:
        return None

    if resp.status_code != 200:
        return None

    clip_id = uuid.uuid4().hex
    _clips[clip_id] = (resp.content, _CONTENT_TYPE)
    _evict_if_over_capacity()
    return clip_id


def get_clip(clip_id: str) -> tuple[bytes, str] | None:
    """Look up previously synthesized audio by clip id, or None if unknown."""
    return _clips.get(clip_id)


def _evict_if_over_capacity() -> None:
    # Dicts preserve insertion order, so the oldest key is always the first
    # one — a plain FIFO cap is enough to bound memory across a long demo
    # session without coupling this module to call/session lifecycle.
    while len(_clips) > _MAX_CACHED_CLIPS:
        oldest = next(iter(_clips))
        del _clips[oldest]
