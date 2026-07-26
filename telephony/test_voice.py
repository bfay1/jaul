"""Offline tests for telephony/voice.py — the ElevenLabs opt-in TTS path.

No real network calls, no API key: `requests.post` is monkeypatched directly
on the module. Covers the opt-in gate, success, failure/timeout fallback, and
the in-memory cache's eviction cap — the guarantees telephony/server.py
relies on to never crash or stall a live call.

    python -m telephony.test_voice
"""
import contextlib
import os

import telephony.voice as voice


class _FakeResponse:
    def __init__(self, status_code: int, content: bytes = b""):
        self.status_code = status_code
        self.content = content


@contextlib.contextmanager
def _temp_env(**kwargs):
    """Set env vars for the block; restore (or unset) prior values after.

    A value of None means "ensure this var is unset for the duration".
    """
    missing = object()
    prev = {k: os.environ.get(k, missing) for k in kwargs}
    for k, v in kwargs.items():
        if v is None:
            os.environ.pop(k, None)
        else:
            os.environ[k] = v
    try:
        yield
    finally:
        for k, old in prev.items():
            if old is missing:
                os.environ.pop(k, None)
            else:
                os.environ[k] = old


@contextlib.contextmanager
def _mock_post(fn):
    """Temporarily replace voice.requests.post."""
    original = voice.requests.post
    voice.requests.post = fn
    try:
        yield
    finally:
        voice.requests.post = original


def test_disabled_without_key():
    with _temp_env(ELEVENLABS_API_KEY=None):
        assert voice.enabled() is False
        assert voice.synthesize("hello") is None


def test_disabled_without_voice_id():
    with _temp_env(ELEVENLABS_API_KEY="fake-key", ELEVENLABS_VOICE_ID=None):
        assert voice.enabled() is True  # key alone gates `enabled()`
        assert voice.synthesize("hello") is None  # but synthesize needs a voice id too


def test_synthesize_success_caches_and_returns_clip():
    with _temp_env(ELEVENLABS_API_KEY="fake-key", ELEVENLABS_VOICE_ID="voice-123"):
        with _mock_post(lambda *a, **k: _FakeResponse(200, b"fake-wav-bytes")):
            clip_id = voice.synthesize("Hi there")
            assert clip_id is not None
            assert voice.get_clip(clip_id) == (b"fake-wav-bytes", "audio/wav")


def test_synthesize_requests_telephony_sample_rate_as_a_real_file():
    # <Play> fetches a self-contained FILE, unlike Media Streams (which
    # expects raw ulaw_8000 frames with no per-chunk header). wav_8000 is a
    # real RIFF/WAVE container at Twilio's native sample rate: a proper file
    # <Play> can parse, with minimal transcoding.
    captured = {}

    def _capture(*a, **k):
        captured.update(k)
        return _FakeResponse(200, b"fake-wav-bytes")

    with _temp_env(ELEVENLABS_API_KEY="fake-key", ELEVENLABS_VOICE_ID="voice-123"):
        with _mock_post(_capture):
            voice.synthesize("Hi there")

    assert captured["params"]["output_format"] == "wav_8000"


def test_synthesize_falls_back_on_bad_status():
    with _temp_env(ELEVENLABS_API_KEY="fake-key", ELEVENLABS_VOICE_ID="voice-123"):
        with _mock_post(lambda *a, **k: _FakeResponse(500)):
            assert voice.synthesize("Hi there") is None


def test_synthesize_falls_back_on_timeout():
    def _raise_timeout(*a, **k):
        raise voice.requests.Timeout("simulated timeout")

    with _temp_env(ELEVENLABS_API_KEY="fake-key", ELEVENLABS_VOICE_ID="voice-123"):
        with _mock_post(_raise_timeout):
            assert voice.synthesize("Hi there") is None


def test_cache_evicts_oldest_over_capacity():
    original_cap = voice._MAX_CACHED_CLIPS
    voice._clips.clear()
    voice._MAX_CACHED_CLIPS = 3
    try:
        with _temp_env(ELEVENLABS_API_KEY="fake-key", ELEVENLABS_VOICE_ID="voice-123"):
            with _mock_post(lambda *a, **k: _FakeResponse(200, b"x")):
                ids = [voice.synthesize(f"line {i}") for i in range(5)]
        assert len(voice._clips) == 3
        assert voice.get_clip(ids[0]) is None
        assert voice.get_clip(ids[1]) is None
        assert voice.get_clip(ids[-1]) is not None
    finally:
        voice._MAX_CACHED_CLIPS = original_cap
        voice._clips.clear()


def test_get_clip_unknown_id_returns_none():
    assert voice.get_clip("no-such-clip") is None


if __name__ == "__main__":
    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for fn in fns:
        fn()
        print(f"ok  {fn.__name__}")
    print(f"\n{len(fns)} passed")
