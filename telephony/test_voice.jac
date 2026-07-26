"""Offline tests for telephony/voice.jac - the ElevenLabs opt-in TTS path.

No real network calls, no API key: `requests.post` is monkeypatched directly
on the module. Covers the opt-in gate, success, failure/timeout fallback, and
the in-memory cache's eviction cap - the guarantees telephony/server.jac
relies on to never crash or stall a live call.

Context managers are plain `obj`s with `__enter__`/`__exit__`, NOT
`@contextlib.contextmanager`-decorated generators - verified that decorator
makes `jac check` misread the function's own parameter list, false-flagging
every call site as "too many positional arguments" even though the same code
runs correctly. Filed as a known checker gap, not a real bug; the obj form
sidesteps it entirely and checks clean.

    jac test telephony/test_voice.jac
"""
import os;

import from telephony.voice { enabled, synthesize, get_clip, requests }
import from telephony { voice }


obj _FakeResponse {
    has status_code: int;
    has content: bytes = b"";
}


"""Set env vars for the block; restore (or unset) prior values after.

A value of None means "ensure this var is unset for the duration".
"""
obj _TempEnv {
    has env: dict[str, str | None];
    has _prev: dict[str, str | None] = {};
    has _missing: list[str] = [];

    def __enter__ {
        for (k, v) in self.env.items() {
            if k in os.environ {
                self._prev[k] = os.environ[k];
            } else {
                self._missing.append(k);
            }
            if v is None {
                os.environ.pop(k, None);
            } else {
                os.environ[k] = v;
            }
        }
    }

    def __exit__(exc_type: any, exc_val: any, exc_tb: any) {
        for (k, old) in self._prev.items() {
            os.environ[k] = old as str;
        }
        for k in self._missing {
            os.environ.pop(k, None);
        }
    }
}


"""Temporarily replace voice.requests.post."""
obj _MockPost {
    has fn: any;
    has _original: any = None;

    def __enter__ {
        self._original = requests.post;
        setattr(voice.requests, "post", self.fn);
    }

    def __exit__(exc_type: any, exc_val: any, exc_tb: any) {
        setattr(voice.requests, "post", self._original);
    }
}


def _ok(*a: any, **k: any) -> _FakeResponse {
    return _FakeResponse(status_code=200, content=b"fake-mp3-bytes");
}

def _bad_status(*a: any, **k: any) -> _FakeResponse {
    return _FakeResponse(status_code=500);
}

def _timeout(*a: any, **k: any) {
    raise requests.Timeout("simulated timeout");
}


test "disabled without key" {
    with _TempEnv(env={"ELEVENLABS_API_KEY": None}) {
        assert not enabled();
        assert synthesize("hello") is None;
    }
}

test "disabled without voice id" {
    with _TempEnv(env={"ELEVENLABS_API_KEY": "fake-key", "ELEVENLABS_VOICE_ID": None}) {
        assert enabled();  # key alone gates enabled()
        assert synthesize("hello") is None;  # but synthesize needs a voice id too
    }
}

test "synthesize success caches and returns clip" {
    with _TempEnv(env={"ELEVENLABS_API_KEY": "fake-key", "ELEVENLABS_VOICE_ID": "voice-123"}) {
        with _MockPost(fn=_ok) {
            clip_id = synthesize("Hi there");
            assert clip_id is not None;
            assert get_clip(clip_id as str) == (b"fake-mp3-bytes", "audio/mpeg");
        }
    }
}

test "synthesize requests the plain default format" {
    # Two telephony-optimized formats (ulaw_8000, then wav_8000) both proved
    # defective for <Play> - see voice.jac's comment. mp3_44100_128 is
    # ElevenLabs' own plain default, letting Twilio's mature transcoding do
    # the telephony conversion instead of us guessing at low-level formats.
    captured: dict = {};

    def _capture(*a: any, **k: any) -> _FakeResponse {
        captured.update(k);
        return _FakeResponse(status_code=200, content=b"fake-mp3-bytes");
    }

    with _TempEnv(env={"ELEVENLABS_API_KEY": "fake-key", "ELEVENLABS_VOICE_ID": "voice-123"}) {
        with _MockPost(fn=_capture) {
            synthesize("Hi there");
        }
    }

    assert captured["params"]["output_format"] == "mp3_44100_128";
}

test "synthesize falls back on bad status" {
    with _TempEnv(env={"ELEVENLABS_API_KEY": "fake-key", "ELEVENLABS_VOICE_ID": "voice-123"}) {
        with _MockPost(fn=_bad_status) {
            assert synthesize("Hi there") is None;
        }
    }
}

test "synthesize falls back on timeout" {
    with _TempEnv(env={"ELEVENLABS_API_KEY": "fake-key", "ELEVENLABS_VOICE_ID": "voice-123"}) {
        with _MockPost(fn=_timeout) {
            assert synthesize("Hi there") is None;
        }
    }
}

test "cache evicts oldest over capacity" {
    original_cap = voice._MAX_CACHED_CLIPS;
    voice._clips.clear();
    voice._MAX_CACHED_CLIPS = 3;
    try {
        with _TempEnv(env={"ELEVENLABS_API_KEY": "fake-key", "ELEVENLABS_VOICE_ID": "voice-123"}) {
            def _small(*a: any, **k: any) -> _FakeResponse {
                return _FakeResponse(status_code=200, content=b"x");
            }
            with _MockPost(fn=_small) {
                ids = [synthesize(f"line {i}") for i in range(5)];
            }
        }
        assert len(voice._clips) == 3;
        assert get_clip(ids[0] as str) is None;
        assert get_clip(ids[1] as str) is None;
        assert get_clip(ids[-1] as str) is not None;
    } finally {
        voice._MAX_CACHED_CLIPS = original_cap;
        voice._clips.clear();
    }
}

test "get clip unknown id returns none" {
    assert get_clip("no-such-clip") is None;
}
