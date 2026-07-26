"""FastAPI webhook server Twilio drives during a live call.

Local dev (URL changes every restart - fine for quick iteration):
  uvicorn telephony.server:app --port 8080
  ngrok http 8080  -> copy the https URL into PUBLIC_BASE_URL in .env
  python -m telephony.dial

Persistent deploy (stable URL - see render.yaml / README "Deploying"):
  Render sets RENDER_EXTERNAL_URL automatically, so no PUBLIC_BASE_URL is
  needed on the server itself. After deploying, copy the printed
  https://<service>.onrender.com URL into PUBLIC_BASE_URL in your LOCAL .env
  so `python -m telephony.dial` (run from your machine) knows where to send
  the outbound call.

Twilio flow:
  outbound call --> POST /twiml/start  (agent's opening line + <Gather>)
                --> POST /twiml/turn   (rep's SpeechResult -> next line)  [repeat]
                --> <Hangup/> when the negotiation reaches deal/dead-end.
"""
import os

from fastapi import FastAPI, Request, Response

from telephony.core import NegotiationSession
from telephony.transport import TurnBasedTransport
from telephony import voice

app = FastAPI(title="jaul telephony")

# One session per Twilio CallSid. In-memory is fine for a single always-on
# process (local uvicorn, or one Render instance); it would NOT survive across
# serverless invocations or multiple instances - swap for a shared store if you
# ever scale this out.
_sessions: dict[str, NegotiationSession] = {}
_transport = TurnBasedTransport()


def _turn_url(request: Request) -> str:
    # Explicit PUBLIC_BASE_URL wins (e.g. local ngrok); otherwise Render already
    # tells us our own public URL; otherwise fall back to what the request saw.
    base = (
        os.environ.get("PUBLIC_BASE_URL")
        or os.environ.get("RENDER_EXTERNAL_URL")
        or str(request.base_url).rstrip("/")
    )
    return f"{base.rstrip('/')}/twiml/turn"


def _audio_url(request: Request, clip_id: str) -> str:
    base = os.environ.get("PUBLIC_BASE_URL", str(request.base_url).rstrip("/"))
    return f"{base.rstrip('/')}/audio/{clip_id}"


def _render(request: Request, line: str, status: str) -> tuple[str, str]:
    # ElevenLabs is strictly opt-in: synthesize() returns None (no exception,
    # no stall) if it's unconfigured or the call fails/times out, in which
    # case render() falls back to the built-in Polly voice for this turn.
    clip_id = voice.synthesize(line)
    audio_url = _audio_url(request, clip_id) if clip_id else None
    return _transport.render(line, status, _turn_url(request), audio_url=audio_url)


@app.post("/twiml/start")
async def twiml_start(request: Request) -> Response:
    form = await request.form()
    call_sid = form.get("CallSid", "demo")
    session = NegotiationSession()
    _sessions[call_sid] = session
    line, status = session.start()
    ctype, body = _render(request, line, status)
    return Response(content=body, media_type=ctype)


@app.post("/twiml/turn")
async def twiml_turn(request: Request) -> Response:
    form = await request.form()
    call_sid = form.get("CallSid", "demo")
    speech = (form.get("SpeechResult") or "").strip()
    session = _sessions.get(call_sid)

    if session is None:
        # Unknown call (e.g. server restarted mid-call): start a fresh one.
        session = NegotiationSession()
        _sessions[call_sid] = session
        line, status = session.start()
    elif not speech:
        # Didn't catch anything — reprompt without advancing the graph.
        line, status = "Sorry, I didn't quite catch that — could you repeat it?", "in_progress"
    else:
        line, status = session.advance(speech)

    ctype, body = _render(request, line, status)
    if status != "in_progress":
        _sessions.pop(call_sid, None)
    return Response(content=body, media_type=ctype)


@app.get("/audio/{clip_id}")
def get_audio(clip_id: str) -> Response:
    """Serves ElevenLabs-synthesized audio back to Twilio's <Play> fetch."""
    clip = voice.get_clip(clip_id)
    if clip is None:
        return Response(status_code=404)
    audio_bytes, content_type = clip
    return Response(content=audio_bytes, media_type=content_type)


@app.get("/health")
def health() -> dict:
    return {"ok": True, "active_calls": len(_sessions)}
