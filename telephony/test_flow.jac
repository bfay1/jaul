"""Offline test of the turn-based telephony flow.

No Twilio account, no network, no API key: the negotiation model is swapped for
a deterministic MockLLM, and the TwiML is inspected as plain XML. Runs the whole
call-over-webhooks path through the same Jac walker the live call uses.

    jac test telephony/test_flow.jac
"""
import from telephony.core { NegotiationSession, use_mock_llm }
import from telephony.transport { TurnBasedTransport }
import agent;


def _run(outputs: list, rep_lines: list[str]) -> NegotiationSession {
    use_mock_llm(outputs);
    session = NegotiationSession();
    (line, status) = session.start();
    for rep in rep_lines {
        if status != "in_progress" {
            break;
        }
        (line, status) = session.advance(rep);
    }
    return session;
}


test "deal via escalation" {
    session = _run(
        outputs=[
            "Hi, are there any financial assistance programs I might qualify for?",
            agent.RepIntent.NEEDS_ESCALATION,
            agent.TacticMove.ESCALATE,
            "Could I speak with a supervisor about a hardship adjustment?",
            agent.RepIntent.ACCEPTED
        ],
        rep_lines=[
            "You'd have to talk to my supervisor for that.",
            "Okay, my supervisor approved an interest-free plan."
        ]
    );
    assert session.status == "deal_reached";
    assert any("supervisor" in ln.lower() for ln in session.transcript);
    # ACCEPTED is terminal - no tactic move is chosen once the call is over.
    assert session.last_intent == "ACCEPTED";
    assert session.last_move == "";
}

test "last intent and move populate for a continuing turn" {
    # Exposed for the /live status page: after a continuing (non-terminal)
    # reply, both the classification and the chosen next tactic should be
    # readable off the session.
    session = _run(
        outputs=[
            "Hi, are there any financial assistance programs I might qualify for?",
            agent.RepIntent.STONEWALLING,
            agent.TacticMove.CITE_501R,
            "As a nonprofit, IRS 501(r) requires you to check assistance eligibility first."
        ],
        rep_lines=["I really can't offer more than that."]
    );
    assert session.status == "in_progress";
    assert session.last_intent == "STONEWALLING";
    assert session.last_move == "CITE_501R";
}

test "repeated soft no climbs to escalation" {
    # A deflecting rep must not end the call. The agent keeps building new
    # tactic steps and climbing rather than hanging up - dynamic graph
    # construction means there's no pre-wired edge to be missing anymore.
    session = _run(
        outputs=[
            "Hi, are there any financial assistance programs I might qualify for?",
            agent.RepIntent.SOFT_NO,
            agent.TacticMove.OFFER_INCOME_DISCOUNT,
            "Could we set up an interest-free payment plan instead?",
            agent.RepIntent.SOFT_NO,
            agent.TacticMove.ESCALATE,
            "Could I speak with a supervisor about a hardship adjustment?"
        ],
        rep_lines=["Maybe, I'm not sure.", "Hmm, I really can't say."]
    );
    assert session.status == "in_progress";
    assert any("supervisor" in ln.lower() for ln in session.transcript);
}

test "hard no still ends the call" {
    # The graceful exit must still fire when the rep genuinely refuses.
    session = _run(
        outputs=[
            "Hi, are there any financial assistance programs I might qualify for?",
            agent.RepIntent.HARD_NO
        ],
        rep_lines=["No, we don't offer anything like that."]
    );
    assert session.status == "dead_end";
}

test "transport gather then hangup" {
    t = TurnBasedTransport();
    (ctype, body) = t.render("Hello there.", "in_progress", "https://x.test/twiml/turn");
    assert ctype == "application/xml";
    assert "<Gather" in body and "Hello there." in body and "<Hangup" not in body;

    (_ctype2, body2) = t.render("Goodbye now.", "deal_reached", "https://x.test/twiml/turn");
    assert "<Hangup/>" in body2 and "<Gather" not in body2;
}

test "transport escapes xml" {
    t = TurnBasedTransport();
    (_ctype, body) = t.render("Tom & Jerry said <hi>", "in_progress", "https://x.test/t?a=1&b=2");
    assert "&amp;" in body and "&lt;hi&gt;" in body;
    assert "<hi>" not in body;  # the literal line must not leak raw angle brackets
}

test "transport plays audio url when given" {
    t = TurnBasedTransport();
    (_ctype, body) = t.render(
        "Hello there.", "in_progress", "https://x.test/twiml/turn",
        audio_url="https://x.test/audio/abc123"
    );
    assert "<Play>https://x.test/audio/abc123</Play>" in body;
    assert "<Say" not in body;
}

test "transport says when no audio url" {
    t = TurnBasedTransport();
    (_ctype, body) = t.render("Hello there.", "in_progress", "https://x.test/twiml/turn");
    assert "<Say" in body;
    assert "<Play>" not in body;
}
