"""Offline test of the turn-based telephony flow.

No Twilio account, no network, no API key: the negotiation model is swapped for
a deterministic MockLLM, and the TwiML is inspected as plain XML. Runs the whole
call-over-webhooks path through the same Jac walker the live call uses.

    python -m telephony.test_flow
"""
import telephony.core as core
from telephony.transport import TurnBasedTransport
import agent


def _run(outputs, rep_lines):
    core.use_mock_llm(outputs)
    session = core.NegotiationSession()
    line, status = session.start()
    for rep in rep_lines:
        if status != "in_progress":
            break
        line, status = session.advance(rep)
    return session


def test_deal_via_escalation():
    session = _run(
        outputs=[
            "Hi, are there any financial assistance programs I might qualify for?",
            agent.RepIntent.NEEDS_ESCALATION,
            "Could I speak with a supervisor about a hardship adjustment?",
            agent.RepIntent.ACCEPTED,
        ],
        rep_lines=[
            "You'd have to talk to my supervisor for that.",
            "Okay, my supervisor approved an interest-free plan.",
        ],
    )
    assert session.status == "deal_reached", session.status
    assert any("supervisor" in ln.lower() for ln in session.transcript)


def test_repeated_soft_no_climbs_to_escalation():
    # A deflecting rep must not end the call. Opening -SoftNo-> CounterOffer
    # -SoftNo-> Escalation: the agent climbs the tactic ladder instead of
    # hanging up. CounterOffer used to have no SoftNo edge, so this exact
    # exchange -- the single most likely one on a real call -- dead-ended after
    # two turns via the walker's graceful-exit fallback.
    session = _run(
        outputs=[
            "Hi, are there any financial assistance programs I might qualify for?",
            agent.RepIntent.SOFT_NO,       # opening -> CounterOffer
            "Could we set up an interest-free payment plan instead?",
            agent.RepIntent.SOFT_NO,       # CounterOffer -> Escalation
            "Could I speak with a supervisor about a hardship adjustment?",
        ],
        rep_lines=["Maybe, I'm not sure.", "Hmm, I really can't say."],
    )
    assert session.status == "in_progress", session.status
    assert any("supervisor" in ln.lower() for ln in session.transcript)


def test_hard_no_still_ends_the_call():
    # The graceful exit must still fire when the rep genuinely refuses.
    session = _run(
        outputs=[
            "Hi, are there any financial assistance programs I might qualify for?",
            agent.RepIntent.HARD_NO,
        ],
        rep_lines=["No, we don't offer anything like that."],
    )
    assert session.status == "dead_end", session.status


def test_transport_gather_then_hangup():
    t = TurnBasedTransport()
    ctype, body = t.render("Hello there.", "in_progress", "https://x.test/twiml/turn")
    assert ctype == "application/xml"
    assert "<Gather" in body and "Hello there." in body and "<Hangup" not in body

    _, body = t.render("Goodbye now.", "deal_reached", "https://x.test/twiml/turn")
    assert "<Hangup/>" in body and "<Gather" not in body


def test_transport_escapes_xml():
    t = TurnBasedTransport()
    _, body = t.render("Tom & Jerry said <hi>", "in_progress", "https://x.test/t?a=1&b=2")
    assert "&amp;" in body and "&lt;hi&gt;" in body
    assert "<hi>" not in body  # the literal line must not leak raw angle brackets


if __name__ == "__main__":
    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for fn in fns:
        fn()
        print(f"ok  {fn.__name__}")
    print(f"\n{len(fns)} passed")
