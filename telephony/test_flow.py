"""Offline test of the turn-based telephony flow.

No Twilio account, no network, no API key: the negotiation model is swapped for
a deterministic MockLLM, and the TwiML is inspected as plain XML. Runs the whole
call-over-webhooks path through the same Jac walker the live call uses.

    python -m telephony.test_flow
"""
import telephony.core as core
from telephony.transport import TurnBasedTransport
import agent


def _run(gen_outputs, fast_outputs, rep_lines, call_id=""):
    # On a live call the rep is a real human, so `fast` only serves
    # classify_response and (when ACCEPTED) extract_commitment.
    core.use_mock_llm(gen_outputs, fast_outputs)
    session = core.NegotiationSession(call_id=call_id)
    line, status = session.start()
    for rep in rep_lines:
        if status != "in_progress":
            break
        line, status = session.advance(rep)
    return session


def test_deal_via_escalation():
    session = _run(
        gen_outputs=[
            "Hi, are there any financial assistance programs I might qualify for?",
            "Could I speak with a supervisor about a hardship adjustment?",
        ],
        fast_outputs=[
            agent.RepIntent.NEEDS_ESCALATION,
            agent.RepIntent.ACCEPTED,
            agent.Commitment(
                is_firm=True, term_months=24, interest_rate="0%",
                summary="Interest-free payment plan over 24 months",
            ),
        ],
        rep_lines=[
            "You'd have to talk to my supervisor for that.",
            "Okay, my supervisor approved an interest-free plan over 24 months.",
        ],
    )
    assert session.status == "deal_reached", session.status
    assert any("supervisor" in ln.lower() for ln in session.transcript)
    assert session.deal_terms == "Interest-free payment plan over 24 months"


def test_warm_non_commitment_does_not_close_the_call():
    # The False Yes failure mode over the live-call path: the rep sounds like
    # a yes and commits to nothing, so the gate must downgrade it to SOFT_NO
    # rather than let the walker report a deal that never happened.
    session = _run(
        gen_outputs=[
            "Hi, are there any financial assistance programs I might qualify for?",
            "Could we set up an interest-free payment plan?",
        ],
        fast_outputs=[
            agent.RepIntent.ACCEPTED,
            agent.Commitment(is_firm=False, summary="Only promised to note it; no terms stated"),
        ],
        rep_lines=["Of course, I'll make a note of that on your account."],
    )
    assert session.status == "in_progress", session.status
    assert session.edge_path == ["SOFT_NO"], session.edge_path
    assert session.deal_terms == ""


def test_repeated_soft_no_climbs_to_escalation():
    # A deflecting rep must not end the call. Opening -SoftNo-> CounterOffer
    # -SoftNo-> Escalation: the agent climbs the tactic ladder instead of
    # hanging up. CounterOffer used to have no SoftNo edge, so this exact
    # exchange -- the single most likely one on a real call -- dead-ended after
    # two turns via the walker's graceful-exit fallback.
    session = _run(
        gen_outputs=[
            "Hi, are there any financial assistance programs I might qualify for?",
            "Could we set up an interest-free payment plan instead?",
            "Could I speak with a supervisor about a hardship adjustment?",
        ],
        fast_outputs=[
            agent.RepIntent.SOFT_NO,       # opening -> CounterOffer
            agent.RepIntent.SOFT_NO,       # CounterOffer -> Escalation
        ],
        rep_lines=["Maybe, I'm not sure.", "Hmm, I really can't say."],
    )
    assert session.status == "in_progress", session.status
    assert any("supervisor" in ln.lower() for ln in session.transcript)
    assert session.tactic_path == ["opening", "counter_offer", "escalation"], session.tactic_path


def test_hard_no_still_ends_the_call():
    # The graceful exit must still fire when the rep genuinely refuses.
    session = _run(
        gen_outputs=["Hi, are there any financial assistance programs I might qualify for?"],
        fast_outputs=[agent.RepIntent.HARD_NO],
        rep_lines=["No, we don't offer anything like that."],
    )
    assert session.status == "dead_end", session.status


def test_learned_exemplars_reach_a_live_call():
    # The bridge that makes a live call benefit from the learning loop: the
    # loop exports banks under `jac run`, this process imports them, and the
    # walker hands the current node's bank to the generator via incl_info.
    import json, os, tempfile

    path = os.path.join(tempfile.mkdtemp(), "exemplars.json")
    with open(path, "w") as f:
        json.dump({"opening": {"exemplars": [], "playbook": ["LEARNED-OPENING-RULE"]},
                   "counter_offer": {"exemplars": [], "playbook": []},
                   "escalation": {"exemplars": [], "playbook": []}}, f)

    assert core.load_learned_exemplars(path) == 1
    _run(
        gen_outputs=["Hi, are there any financial assistance programs?"],
        fast_outputs=[agent.RepIntent.HARD_NO],
        rep_lines=["No."],
    )
    assert agent.exemplar_ctx["playbook"] == ["LEARNED-OPENING-RULE"]

    core.load_learned_exemplars(os.path.join(tempfile.mkdtemp(), "absent.json"))


def test_completed_live_call_is_persisted():
    # A finished live call must leave a queryable CallRecord, same as a
    # simulated one - that record is the training data.
    from jaclang.lib import root, refs
    session = _run(
        gen_outputs=["Hi, are there any financial assistance programs I might qualify for?"],
        fast_outputs=[agent.RepIntent.HARD_NO],
        rep_lines=["No, we don't offer anything like that."],
        call_id="telephony-persist-001",
    )
    assert session.status == "dead_end"
    saved = [n for n in refs(root())
             if type(n).__name__ == "CallRecord"
             and getattr(n, "call_id", "") == "telephony-persist-001"]
    assert len(saved) == 1, f"expected 1 CallRecord, got {len(saved)}"
    assert saved[0].edge_path == ["HARD_NO"]
    assert saved[0].outcome == "dead_end"


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
