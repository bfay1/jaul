"""FastAPI webhook server Twilio drives during a live call.

Run locally:  uvicorn telephony.server:app --port 8080
Expose it (Twilio must reach it):  ngrok http 8080  -> set PUBLIC_BASE_URL
Then place the call:  python -m telephony.dial

Twilio flow:
  outbound call --> POST /twiml/start  (agent's opening line + <Gather>)
                --> POST /twiml/turn   (rep's SpeechResult -> next line)  [repeat]
                --> <Hangup/> when the negotiation reaches deal/dead-end.
"""
import os

from fastapi import FastAPI, Request, Response

from telephony.core import NegotiationSession
from telephony.transport import TurnBasedTransport

app = FastAPI(title="jaul telephony")

# One session per Twilio CallSid. In-memory is fine for a single-process demo;
# swap for a shared store if you scale the server out.
_sessions: dict[str, NegotiationSession] = {}
_transport = TurnBasedTransport()


def _turn_url(request: Request) -> str:
    base = os.environ.get("PUBLIC_BASE_URL", str(request.base_url).rstrip("/"))
    return f"{base.rstrip('/')}/twiml/turn"


@app.post("/twiml/start")
async def twiml_start(request: Request) -> Response:
    form = await request.form()
    call_sid = form.get("CallSid", "demo")
    session = NegotiationSession()
    _sessions[call_sid] = session
    line, status = session.start()
    ctype, body = _transport.render(line, status, _turn_url(request))
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

    ctype, body = _transport.render(line, status, _turn_url(request))
    if status != "in_progress":
        _sessions.pop(call_sid, None)
    return Response(content=body, media_type=ctype)


@app.get("/health")
def health() -> dict:
    return {"ok": True, "active_calls": len(_sessions)}
