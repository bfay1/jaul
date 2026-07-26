"""ElevenLabs text-to-speech - strictly opt-in, never on the critical path.

Synthesizes the agent's spoken line into audio for Twilio's <Play> verb, in
place of Twilio's built-in Polly voice. Owns the ElevenLabs REST call directly
(no `elevenlabs` SDK) so it stays a small, dependency-light, offline-testable
module - the same reasoning transport.jac gives for avoiding the `twilio` SDK
on its hot path.

Opt-in contract callers rely on: if ELEVENLABS_API_KEY is unset, or the call
fails or times out for any reason, `synthesize()` returns None rather than
raising. server.jac treats None as "fall back to the Polly <Say> voice for
this turn" - a live call must never crash or stall because ElevenLabs is
unreachable, slow, or out of quota.
"""
import os;
import uuid;
import requests;

glob _ELEVENLABS_TTS_URL: str = "https://api.elevenlabs.io/v1/text-to-speech/{voice_id}";
glob _DEFAULT_MODEL_ID: str = "eleven_flash_v2_5";

# Twilio hard-caps a webhook response at 15s total. Each /twiml/turn request
# already makes two sequential LLM calls (classify_response, generate_line)
# before it can even attempt this one - so a generous timeout here risks
# eating most of that 15s budget by itself if ElevenLabs is ever slow,
# tripping Twilio's own timeout (error 11200) and ending the call with
# "application error". A tight timeout means we fail fast and fall back to
# the Polly <Say> voice for that turn instead of running out the clock.
glob _TIMEOUT_SECONDS: int = 4;

# Two telephony-optimized formats were tried here and both proved wrong:
# - ulaw_8000: headerless raw PCM, the wrong shape for <Play> (a file fetch);
#   that format is meant for Twilio Media Streams (a WebSocket), not <Play>.
# - wav_8000: fetching a live clip and inspecting it with Python's `wave`
#   module showed ~40-46 SECONDS of audio for a single short sentence, at
#   every clip checked - a real defect in that specific format combination,
#   not just lower quality.
# mp3_44100_128 is ElevenLabs' own plain default and the format essentially
# every "ElevenLabs + Twilio <Play>" integration guide actually uses - Twilio
# transcodes it down to telephony quality itself, which is mature and
# well-tested, unlike our two attempts at doing that step ourselves.
glob _OUTPUT_FORMAT: str = "mp3_44100_128";
glob _CONTENT_TYPE: str = "audio/mpeg";

# clip_id -> (audio_bytes, content_type). In-memory only: fine for a
# single-process demo server (same assumption server.jac's `_sessions` dict
# already makes) since uvicorn's default single-worker event loop means no
# concurrent-write races. Would need a shared store (Redis, etc.) if this
# server ever ran with multiple workers/processes.
glob _clips: dict[str, tuple[bytes, str]] = {};
glob _MAX_CACHED_CLIPS: int = 50;


"""Whether ElevenLabs should be attempted at all."""
def enabled() -> bool {
    return bool(os.environ.get("ELEVENLABS_API_KEY"));
}


"""Synthesize `text`, cache the audio, and return its clip id.

Returns None (never raises) if ElevenLabs is not configured, or if the call
fails, times out, or comes back with a non-200 status.
"""
def synthesize(text: str) -> str | None {
    if not enabled() {
        return None;
    }

    voice_id = os.environ.get("ELEVENLABS_VOICE_ID");
    if not voice_id {
        return None;
    }

    api_key = os.environ["ELEVENLABS_API_KEY"];
    model_id = os.environ.get("ELEVENLABS_MODEL_ID") or _DEFAULT_MODEL_ID;

    try {
        resp = requests.post(
            _ELEVENLABS_TTS_URL.format(voice_id=voice_id),
            params={"output_format": _OUTPUT_FORMAT},
            headers={
                "xi-api-key": api_key,
                "Content-Type": "application/json"
            },
            json={"text": text, "model_id": model_id},
            timeout=_TIMEOUT_SECONDS
        );
    } except requests.RequestException {
        return None;
    }

    if resp.status_code != 200 {
        return None;
    }

    clip_id = uuid.uuid4().hex;
    _clips[clip_id] = (resp.content, _CONTENT_TYPE);
    _evict_if_over_capacity();
    return clip_id;
}


"""Look up previously synthesized audio by clip id, or None if unknown."""
def get_clip(clip_id: str) -> tuple[bytes, str] | None {
    return _clips.get(clip_id);
}


def _evict_if_over_capacity() {
    # Dicts preserve insertion order, so the oldest key is always the first
    # one - a plain FIFO cap is enough to bound memory across a long demo
    # session without coupling this module to call/session lifecycle.
    while len(_clips) > _MAX_CACHED_CLIPS {
        oldest = next(iter(_clips));
        del _clips[oldest];
    }
}
