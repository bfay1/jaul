"""The negotiation engine: LLM-backed intelligence + the traversing walker.

This module owns the *behavior* - how the agent decides what to say, how it
reads the rep's reply, and how the walker moves across the tactic graph
defined in `graph.jac`. The MockLLM tests live here too, because they swap
this module's `glob llm` and exercise the same functions.
"""

import from byllm.lib { Model, MockLLM }
import from graph {
    Tactic, Opening, CounterOffer, Escalation, DealReached, DeadEnd,
    SoftNo, Stonewalling, NeedsEscalation, Accepted, HardNo,
    CallRecord, get_or_build_call_graph
}

# --- Model config ------------------------------------------------------------
# Auth comes from the ANTHROPIC_API_KEY env var (see .env / .env.example) -
# never hardcode a key here or in jac.toml. The `Model | MockLLM` union lets
# the tests below swap in a deterministic mock without an API key.
#
# Model choice is constrained by byllm 0.6.19: it always sends a `temperature`
# on the call, and claude-sonnet-5 rejects that outright ("`temperature` is
# deprecated for this model"), which 500s every live turn. sonnet-4-6 and
# haiku-4-5 both accept it (verified). Revisit if byllm is ever upgraded.
#
# `llm` powers generation - the function we're optimizing, so it stays fixed
# across A/B arms. `fast` powers classification and the simulated rep: those
# run thousands of times, and a *different model* for the rep matters beyond
# cost. An overly-agreeable simulator inflates apparent success, and a rep
# played by the same model as the agent tends to find its own twin's lines
# persuasive - both make the mined exemplars look better than they are.
glob llm: Model | MockLLM = Model(model_name="claude-sonnet-4-6");
glob fast: Model | MockLLM = Model(model_name="claude-haiku-4-5");

# Exemplar side-channel. `incl_info` re-evaluates this dict on EVERY call, so
# the walker can swap in the current node's exemplars immediately before
# generating. This deliberately keeps exemplars OUT of `generate_line`'s
# signature, which the patient-context workstream owns.
glob exemplar_ctx: dict = {};


# --- LLM-backed intelligence -------------------------------------------------
# Classification, dialogue generation, and the mock vendor-rep are each
# powered by `by llm()`. `sem` strings (not docstrings) tell the LLM what
# each piece means - docstrings inside a `by llm()` body are a parse error
# anyway, since `by llm()` replaces the body entirely.

enum RepIntent {
    SOFT_NO,
    STONEWALLING,
    NEEDS_ESCALATION,
    ACCEPTED,
    HARD_NO
}
sem RepIntent.SOFT_NO = "The rep gave a vague, noncommittal, or deflecting reply - not a refusal, but no real progress either.";
sem RepIntent.STONEWALLING = "The rep won't offer anything more at their level and is not budging, but hasn't issued a firm final no.";
sem RepIntent.NEEDS_ESCALATION = "The rep says they personally can't approve this and a supervisor or specialist must get involved.";
sem RepIntent.ACCEPTED = "The rep agrees to and confirms a concrete financial-assistance arrangement (discount, charity care, or payment plan).";
sem RepIntent.HARD_NO = "The rep firmly and finally states no assistance programs exist or will be offered.";

# Maps each intent to the typed edge it takes. Edge-type filters accept a
# runtime variable, so this table replaces five near-identical if/elif arms in
# each walker - the transition really is a lookup, not a branch.
glob EDGE_FOR: dict = {
    RepIntent.SOFT_NO: SoftNo,
    RepIntent.STONEWALLING: Stonewalling,
    RepIntent.NEEDS_ESCALATION: NeedsEscalation,
    RepIntent.ACCEPTED: Accepted,
    RepIntent.HARD_NO: HardNo
};

def classify_response(response: str) -> RepIntent by fast();
sem classify_response = "Classify a hospital billing rep's most recent spoken line, during a patient's call negotiating financial assistance, into the intent that best matches what the rep just said. Warmth is not agreement: a friendly reply that promises no specific arrangement is SOFT_NO, not ACCEPTED.";
sem classify_response.response = "The rep's most recent spoken line in the call.";


# --- The commitment gate -----------------------------------------------------
# A rep who says "absolutely, I'll make a note of that" sounds like a yes and
# commits to nothing. Sentiment alone must never close a call, so ACCEPTED is
# only honored when concrete terms actually parse out of the rep's line.

obj Commitment {
    has is_firm: bool = False;
    has amount: str = "";
    has term_months: int = 0;
    has interest_rate: str = "";
    has summary: str = "";
}
sem Commitment.is_firm = "True only if the rep committed to a specific, verifiable arrangement the patient could hold them to. Vague goodwill, 'I'll note it', 'we can look into that', or a promise to call back are all False.";
sem Commitment.amount = "The dollar amount or percentage discount agreed, verbatim, or empty if none was stated.";
sem Commitment.term_months = "Length of the payment plan in months, or 0 if not stated.";
sem Commitment.interest_rate = "The stated interest rate or APR, verbatim. Empty if none was stated. Note 'interest-free' or '0%' explicitly if said.";
sem Commitment.summary = "One short sentence stating what was actually agreed, or why it does not count as a commitment.";

def extract_commitment(response: str) -> Commitment by fast();
sem extract_commitment = "Read a hospital billing rep's spoken line and extract any concrete financial arrangement they committed to. Be strict: only report is_firm when specific terms were actually stated.";
sem extract_commitment.response = "The rep's most recent spoken line in the call.";


def generate_line(tactic_label: str, transcript: list[str]) -> str by llm(incl_info=exemplar_ctx);
sem generate_line = "You are a calm, persistent patient advocate on a phone call with a hospital billing department. Your goal is to surface income-based discounts, charity care programs, and interest-free payment plans the patient may qualify for, without being pushy. Given the current negotiation tactic phase and the call transcript so far, draft the agent's single next spoken line - polite, concise, and fitting the phase.";
sem generate_line.tactic_label = "The current negotiation phase: 'opening' (first ask about assistance programs), 'counter_offer' (proposing a specific discount or payment plan), or 'escalation' (asking for a supervisor).";
sem generate_line.transcript = "The call transcript so far, as alternating 'AGENT: ...' and 'REP: ...' lines.";

# NOTE - byllm 0.6.19 bug, verified: a second parameter on THIS function is
# silently dropped from byllm's compile-time param map, so the call then dies
# with `IndexError: list index out of range` inside MTRuntime.factory. It is
# not the parameter name, the sem text, or which model glob is used - and the
# identical file under any other module name registers both params correctly.
# `generate_line` right above takes two parameters and is unaffected.
#
# So the persona rides in as the first transcript entry instead. Before adding
# a parameter to any `by llm()` function in this module, check it registered:
#   python -c "import jaclang; from jaclang.jac0core.runtime import JacRuntime as J; \
#              import agent; print([p.name for p in J.get_mtir_from_map('agent.<fn>').params])"
def rep_reply(transcript: list[str]) -> str by fast();
sem rep_reply = "You are playing a hospital billing department representative on a phone call. The first transcript entry, prefixed 'PERSONA:', describes exactly who you are - your authority to approve things, what you know about the hospital's assistance programs, your disposition, how closely you stick to a script, and how much you want the call to end. Follow it for the entire call. Respond naturally and briefly to the agent's most recent line, staying consistent with everything said earlier. Stay in character even when the agent is persuasive - do not become helpful just because they were polite.";
sem rep_reply.transcript = "The call so far. The first entry is 'PERSONA: ...' describing the rep you are playing; the rest are alternating 'AGENT: ...' and 'REP: ...' lines. Reply as the REP's next line only.";


# --- The walker: the negotiation engine -------------------------------------

walker NegotiationAgent {
    has transcript: list[str] = [];
    has outcome: str = "in_progress";
    has turns: int = 0;
    has max_turns: int = 6;

    # Simulation metadata - what this call was run against, and which A/B arm
    # it belongs to. Empty on a live call.
    has persona: str = "";
    has profile: str = "";
    has arm: str = "";
    has call_id: str = "";

    # Trajectory, captured for mining. `agent_lines` and `edge_path` are index-
    # aligned: line i was spoken, and edge_path[i] is what the rep's reply to
    # it classified as. That alignment is what makes per-line credit possible.
    has agent_lines: list[str] = [];
    has tactic_path: list[str] = [];
    has edge_path: list[str] = [];
    has deal_terms: str = "";
    has record_call: bool = True;

    can negotiate with Opening | CounterOffer | Escalation entry {
        self.turns += 1;
        if self.turns > self.max_turns {
            # `disengage` inside finish() stops the traversal but does NOT
            # unwind this ability, so return explicitly or we fall through and
            # burn another generation turn.
            self.finish(here, "dead_end", "hit max_turns without a resolution");
            return;
        }

        here.visit_count += 1;
        self.tactic_path.append(here.label);

        # Hand this node's learned exemplars to the generator. `incl_info`
        # re-reads this dict per call, so the walker's position decides which
        # examples the model sees - the traversal IS the retrieval.
        exemplar_ctx["exemplars"] = here.exemplars;
        line = generate_line(here.label, self.transcript);
        self.transcript.append("AGENT: " + line);
        self.agent_lines.append(line);

        # Persona leads the transcript we hand the simulator, but is kept out
        # of `self.transcript` - that's the real call record.
        response = rep_reply(["PERSONA: " + self.persona] + self.transcript);
        self.transcript.append("REP: " + response);

        intent = self.read_intent(response);
        self.edge_path.append(intent.name);

        edge_type = EDGE_FOR[intent];
        visit [here ->:edge_type:->] else {
            self.finish(here, "dead_end", "no " + intent.name + " edge out of " + here.label);
        }
    }

    """Classify the rep's line, then gate ACCEPTED behind real terms.

    Warmth is not agreement. A rep who says "of course, I'll make a note of
    that" reads as ACCEPTED to a classifier and commits to nothing, which
    would walk us to DealReached and report a deal that never happened.
    """
    def read_intent(response: str) -> RepIntent {
        intent = classify_response(response);
        if intent != RepIntent.ACCEPTED {
            return intent;
        }
        commitment = extract_commitment(response);
        if not commitment.is_firm {
            return RepIntent.SOFT_NO;
        }
        self.deal_terms = commitment.summary;
        return intent;
    }

    can reach_deal with DealReached entry {
        here.visit_count += 1;
        self.tactic_path.append(here.label);
        here.terms = self.deal_terms;
        self.transcript.append("OUTCOME: deal reached - " + self.deal_terms);
        self.finish(here, "deal_reached", self.deal_terms);
    }

    can reach_dead_end with DeadEnd entry {
        here.visit_count += 1;
        self.tactic_path.append(here.label);
        self.transcript.append("OUTCOME: no assistance available");
        self.finish(here, "dead_end", "rep refused outright");
    }

    """Persist the call, then stop.

    Called from every terminal path rather than a `with Root exit` ability:
    this walker is spawned directly on the opening node and never visits Root,
    so a Root exit ability would never fire.
    """
    def finish(final: Tactic, outcome: str, note: str) {
        self.outcome = outcome;
        if self.record_call {
            root ++> CallRecord(
                call_id=self.call_id,
                persona=self.persona,
                profile=self.profile,
                arm=self.arm,
                transcript=self.transcript,
                agent_lines=self.agent_lines,
                tactic_path=self.tactic_path,
                edge_path=self.edge_path,
                outcome=outcome,
                deal_terms=self.deal_terms,
                note=note
            );
        }
        disengage;
    }
}


# --- Single-turn walker (telephony transport) -------------------------------
# NegotiationAgent above runs a whole call in one blocking loop (great for the
# mock demo and tests). A live phone call is different: each turn arrives as a
# separate Twilio webhook, so the walker must advance ONE hop per spawn and
# hand control back. NegotiationTurn does exactly that - the transport layer
# (telephony/) spawns a fresh one each webhook, on the node the last turn ended
# on, passing in what the rep just said. The traversal logic is identical; only
# who supplies the rep's line differs (a real human, not `rep_reply`).

walker NegotiationTurn {
    has rep_utterance: str = "";           # empty on the opening turn
    has transcript: list[str] = [];        # carried across turns by the caller
    has agent_line: str = "";              # OUT: what to speak this turn
    has status: str = "in_progress";       # OUT: in_progress | deal_reached | dead_end
    has end_node: Tactic | None = None;    # OUT: node to resume from next turn

    # Trajectory, carried across webhook spawns by the caller (see
    # telephony/core.py) and written to a CallRecord on the terminal turn.
    has agent_lines: list[str] = [];
    has tactic_path: list[str] = [];
    has edge_path: list[str] = [];
    has deal_terms: str = "";
    has call_id: str = "";

    can step with Opening | CounterOffer | Escalation entry {
        # No rep utterance yet => we just arrived at this tactic (either the
        # call's opening, or a hop taken this same spawn). Speak its line and
        # stop, leaving `end_node` here for the next webhook to resume from.
        if self.rep_utterance == "" {
            here.visit_count += 1;
            self.tactic_path.append(here.label);
            exemplar_ctx["exemplars"] = here.exemplars;
            self.agent_line = generate_line(here.label, self.transcript);
            self.transcript.append("AGENT: " + self.agent_line);
            self.agent_lines.append(self.agent_line);
            self.end_node = here;
            disengage;
        }

        # We have the rep's reply to the line we spoke last turn: classify it,
        # then traverse exactly one typed edge. Clearing rep_utterance means the
        # node we land on takes the branch above and generates the next line.
        self.transcript.append("REP: " + self.rep_utterance);
        intent = classify_response(self.rep_utterance);

        # Same commitment gate as NegotiationAgent: a warm non-answer must not
        # be allowed to close a live call.
        if intent == RepIntent.ACCEPTED {
            commitment = extract_commitment(self.rep_utterance);
            if commitment.is_firm {
                self.deal_terms = commitment.summary;
            } else {
                intent = RepIntent.SOFT_NO;
            }
        }
        self.edge_path.append(intent.name);
        self.rep_utterance = "";

        edge_type = EDGE_FOR[intent];
        visit [here ->:edge_type:->] else { self.dead_end(here); }
    }

    can arrive_deal with DealReached entry {
        here.visit_count += 1;
        self.tactic_path.append(here.label);
        here.terms = self.deal_terms;
        self.agent_line = "Wonderful - thank you so much, that's a real help. Have a great day.";
        self.transcript.append("AGENT: " + self.agent_line);
        self.end_node = here;
        self.finish("deal_reached", self.deal_terms);
    }

    can arrive_dead_end with DeadEnd entry {
        here.visit_count += 1;
        self.tactic_path.append(here.label);
        self.agent_line = "I understand - thank you for taking the time to look into it for me.";
        self.transcript.append("AGENT: " + self.agent_line);
        self.end_node = here;
        self.finish("dead_end", "rep refused outright");
    }

    def dead_end(stuck: Tactic) {
        # No typed edge out for this classification: end the call gracefully
        # rather than crash. Stays on the current node.
        self.agent_line = "I understand - thank you for taking the time to look into it for me.";
        self.transcript.append("AGENT: " + self.agent_line);
        self.end_node = stuck;
        self.finish("dead_end", "no edge out of " + stuck.label);
    }

    """Persist the completed live call, then stop."""
    def finish(outcome: str, note: str) {
        self.status = outcome;
        root ++> CallRecord(
            call_id=self.call_id,
            persona="live",
            arm="live",
            transcript=self.transcript,
            agent_lines=self.agent_lines,
            tactic_path=self.tactic_path,
            edge_path=self.edge_path,
            outcome=outcome,
            deal_terms=self.deal_terms,
            note=note
        );
        disengage;
    }
}


# --- Tests (MockLLM - no API key or network needed) --------------------------
# Two mock queues, because generation and classification now run on different
# models. Consumption order per turn is: generate_line (llm), then rep_reply,
# classify_response, and - only when ACCEPTED - extract_commitment (all fast).
#
# The tactic graph is canonical and persisted, so these tests share nodes and
# accumulate CallRecords. Assert on a unique call_id, never on totals.

glob OPENER: str = "Hi, I'm calling about my account - are there any financial assistance programs I might qualify for?";

test "the tactic graph is canonical across calls" {
    # If this fails, exemplar banks are inert: a line written onto a node in
    # one call would be invisible to the next.
    first = get_or_build_call_graph();
    second = get_or_build_call_graph();
    assert first == second;
    assert len([root -->[?:Opening]]) == 1;
}

test "every tactic node wires all five rep intents" {
    # A tactic missing an edge does not error - the walker's `visit ... else`
    # fallback quietly reports dead_end, so the call just stops. This guard
    # makes that failure loud instead of invisible.
    opening = get_or_build_call_graph();
    counter = [opening ->:SoftNo:->][0];
    escalation = [opening ->:NeedsEscalation:->][0];

    for tactic in [opening, counter, escalation] {
        assert len([tactic ->:SoftNo:->]) > 0;
        assert len([tactic ->:Stonewalling:->]) > 0;
        assert len([tactic ->:NeedsEscalation:->]) > 0;
        assert len([tactic ->:Accepted:->]) > 0;
        assert len([tactic ->:HardNo:->]) > 0;
    }
}

test "rep agrees with concrete terms and the call reaches a deal" {
    global llm;
    global fast;
    llm = MockLLM(model_name="mockllm", config={"outputs": [OPENER]});
    fast = MockLLM(model_name="mockllm", config={"outputs": [
        "Sure - I can do 40% off, spread over 12 months, no interest.",
        RepIntent.ACCEPTED,
        Commitment(is_firm=True, amount="40%", term_months=12,
                   interest_rate="0%", summary="40% discount over 12 months, interest-free")
    ]});

    opening = get_or_build_call_graph();
    result = opening spawn NegotiationAgent(record_call=False);

    assert result.outcome == "deal_reached";
    assert result.deal_terms == "40% discount over 12 months, interest-free";
    assert result.edge_path == ["ACCEPTED"];
}

test "a warm non-commitment does NOT close the call" {
    # The False Yes failure mode: the rep sounds like a yes and commits to
    # nothing. Sentiment alone must never walk us to DealReached.
    global llm;
    global fast;
    llm = MockLLM(model_name="mockllm", config={"outputs": [OPENER]});
    fast = MockLLM(model_name="mockllm", config={"outputs": [
        "Of course, I'll make a note of that on your account.",
        RepIntent.ACCEPTED,
        Commitment(is_firm=False, summary="Only promised to note it; no terms stated")
    ]});

    opening = get_or_build_call_graph();
    result = opening spawn NegotiationAgent(max_turns=1, record_call=False);

    # Classified ACCEPTED, downgraded to SOFT_NO by the commitment gate.
    assert result.edge_path == ["SOFT_NO"];
    assert result.outcome == "dead_end";
    assert result.deal_terms == "";
}

test "a firm hard no from the rep leads to a dead end" {
    global llm;
    global fast;
    llm = MockLLM(model_name="mockllm", config={"outputs": [OPENER]});
    fast = MockLLM(model_name="mockllm", config={"outputs": [
        "No, we don't offer anything like that, sorry.",
        RepIntent.HARD_NO
    ]});

    opening = get_or_build_call_graph();
    result = opening spawn NegotiationAgent(record_call=False);

    assert result.outcome == "dead_end";
    assert result.transcript[-1] == "OUTCOME: no assistance available";
}

test "escalation followed by acceptance still reaches a deal" {
    global llm;
    global fast;
    llm = MockLLM(model_name="mockllm", config={"outputs": [
        OPENER,
        "Could I speak with a supervisor about a hardship adjustment?"
    ]});
    fast = MockLLM(model_name="mockllm", config={"outputs": [
        "I can't approve that myself, you'd need to talk to my supervisor.",
        RepIntent.NEEDS_ESCALATION,
        "Okay, my supervisor approved an interest-free payment plan.",
        RepIntent.ACCEPTED,
        Commitment(is_firm=True, term_months=24, interest_rate="0%",
                   summary="Interest-free payment plan over 24 months")
    ]});

    opening = get_or_build_call_graph();
    result = opening spawn NegotiationAgent(record_call=False);

    assert result.outcome == "deal_reached";
    assert result.tactic_path == ["opening", "escalation", "deal_reached"];
    assert result.edge_path == ["NEEDS_ESCALATION", "ACCEPTED"];
}

test "a completed call is persisted as a queryable CallRecord" {
    global llm;
    global fast;
    llm = MockLLM(model_name="mockllm", config={"outputs": [OPENER]});
    fast = MockLLM(model_name="mockllm", config={"outputs": [
        "No, we don't offer anything like that.",
        RepIntent.HARD_NO
    ]});

    opening = get_or_build_call_graph();
    opening spawn NegotiationAgent(
        call_id="test-persist-001", persona="gatekeeper", profile="p1", arm="base"
    );

    # Filter by unique id - tests share a persisted root, so totals are unsafe.
    saved = [root -->[?:CallRecord, call_id == "test-persist-001"]];
    assert len(saved) == 1;
    assert saved[0].outcome == "dead_end";
    assert saved[0].persona == "gatekeeper";
    assert saved[0].arm == "base";
    assert saved[0].edge_path == ["HARD_NO"];
    assert len(saved[0].agent_lines) == 1;
}

test "exemplars on a node reach the generator via incl_info" {
    # The retrieval path: walker lands on a node, that node's exemplars go
    # into exemplar_ctx, and the next generate_line call sees them.
    opening = get_or_build_call_graph();
    opening.exemplars = ["EXEMPLAR-ALPHA"];

    global llm;
    global fast;
    llm = MockLLM(model_name="mockllm", config={"outputs": [OPENER]});
    fast = MockLLM(model_name="mockllm", config={"outputs": [
        "No.", RepIntent.HARD_NO
    ]});

    opening spawn NegotiationAgent(record_call=False);

    assert exemplar_ctx["exemplars"] == ["EXEMPLAR-ALPHA"];
    opening.exemplars = [];
}
