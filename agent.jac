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
    build_call_graph
}

# --- Model config ------------------------------------------------------------
# Auth comes from the ANTHROPIC_API_KEY env var (see .env / .env.example) -
# never hardcode a key here or in jac.toml. The `Model | MockLLM` union lets
# the tests below swap in a deterministic mock without an API key.
glob llm: Model | MockLLM = Model(model_name="claude-sonnet-5");


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

def classify_response(response: str) -> RepIntent by llm();
sem classify_response = "Classify a hospital billing rep's most recent spoken line, during a patient's call negotiating financial assistance, into the intent that best matches what the rep just said.";
sem classify_response.response = "The rep's most recent spoken line in the call.";

def generate_line(tactic_label: str, transcript: list[str]) -> str by llm();
sem generate_line = "You are a calm, persistent patient advocate on a phone call with a hospital billing department. Your goal is to surface income-based discounts, charity care programs, and interest-free payment plans the patient may qualify for, without being pushy. Given the current negotiation tactic phase and the call transcript so far, draft the agent's single next spoken line - polite, concise, and fitting the phase.";
sem generate_line.tactic_label = "The current negotiation phase: 'opening' (first ask about assistance programs), 'counter_offer' (proposing a specific discount or payment plan), or 'escalation' (asking for a supervisor).";
sem generate_line.transcript = "The call transcript so far, as alternating 'AGENT: ...' and 'REP: ...' lines.";

def rep_reply(transcript: list[str]) -> str by llm();
sem rep_reply = "You are playing a realistic, moderately resistant hospital billing department representative on a phone call. Respond naturally and briefly to the agent's most recent line, staying consistent with everything said earlier in the call. Be a believable mix of vague deflection, protectiveness about what you're allowed to approve, occasional willingness to loop in a supervisor, and only rarely an immediate yes.";
sem rep_reply.transcript = "The call transcript so far, as alternating 'AGENT: ...' and 'REP: ...' lines. Reply as the REP's next line only.";


# --- The walker: the negotiation engine -------------------------------------

walker NegotiationAgent {
    has transcript: list[str] = [];
    has outcome: str = "in_progress";
    has turns: int = 0;
    has max_turns: int = 6;

    can negotiate with Opening | CounterOffer | Escalation entry {
        self.turns += 1;
        if self.turns > self.max_turns {
            self.outcome = "dead_end";
            disengage;
        }

        line = generate_line(here.label, self.transcript);
        self.transcript.append("AGENT: " + line);

        response = rep_reply(self.transcript);
        self.transcript.append("REP: " + response);

        intent = classify_response(response);

        if intent == RepIntent.SOFT_NO {
            visit [here ->:SoftNo:->] else {
                self.outcome = "dead_end";
                disengage;
            }
        } elif intent == RepIntent.STONEWALLING {
            visit [here ->:Stonewalling:->] else {
                self.outcome = "dead_end";
                disengage;
            }
        } elif intent == RepIntent.NEEDS_ESCALATION {
            visit [here ->:NeedsEscalation:->] else {
                self.outcome = "dead_end";
                disengage;
            }
        } elif intent == RepIntent.ACCEPTED {
            visit [here ->:Accepted:->] else {
                self.outcome = "dead_end";
                disengage;
            }
        } else {
            visit [here ->:HardNo:->] else {
                self.outcome = "dead_end";
                disengage;
            }
        }
    }

    can reach_deal with DealReached entry {
        self.outcome = "deal_reached";
        self.transcript.append("OUTCOME: deal reached - " + here.label);
        disengage;
    }

    can reach_dead_end with DeadEnd entry {
        self.outcome = "dead_end";
        self.transcript.append("OUTCOME: no assistance available");
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

    can step with Opening | CounterOffer | Escalation entry {
        # No rep utterance yet => we just arrived at this tactic (either the
        # call's opening, or a hop taken this same spawn). Speak its line and
        # stop, leaving `end_node` here for the next webhook to resume from.
        if self.rep_utterance == "" {
            self.agent_line = generate_line(here.label, self.transcript);
            self.transcript.append("AGENT: " + self.agent_line);
            self.end_node = here;
            disengage;
        }

        # We have the rep's reply to the line we spoke last turn: classify it,
        # then traverse exactly one typed edge. Clearing rep_utterance means the
        # node we land on takes the branch above and generates the next line.
        self.transcript.append("REP: " + self.rep_utterance);
        intent = classify_response(self.rep_utterance);
        self.rep_utterance = "";

        if intent == RepIntent.SOFT_NO {
            visit [here ->:SoftNo:->] else { self.dead_end(here); }
        } elif intent == RepIntent.STONEWALLING {
            visit [here ->:Stonewalling:->] else { self.dead_end(here); }
        } elif intent == RepIntent.NEEDS_ESCALATION {
            visit [here ->:NeedsEscalation:->] else { self.dead_end(here); }
        } elif intent == RepIntent.ACCEPTED {
            visit [here ->:Accepted:->] else { self.dead_end(here); }
        } else {
            visit [here ->:HardNo:->] else { self.dead_end(here); }
        }
    }

    can arrive_deal with DealReached entry {
        self.status = "deal_reached";
        self.agent_line = "Wonderful - thank you so much, that's a real help. Have a great day.";
        self.transcript.append("AGENT: " + self.agent_line);
        self.end_node = here;
        disengage;
    }

    can arrive_dead_end with DeadEnd entry {
        self.status = "dead_end";
        self.agent_line = "I understand - thank you for taking the time to look into it for me.";
        self.transcript.append("AGENT: " + self.agent_line);
        self.end_node = here;
        disengage;
    }

    def dead_end(stuck: Tactic) {
        # No typed edge out for this classification: end the call gracefully
        # rather than crash. Stays on the current node.
        self.status = "dead_end";
        self.agent_line = "I understand - thank you for taking the time to look into it for me.";
        self.transcript.append("AGENT: " + self.agent_line);
        self.end_node = stuck;
        disengage;
    }
}


# --- Tests (MockLLM - no API key or network needed) --------------------------

test "rep agrees immediately and the call reaches a deal" {
    global llm;
    llm = MockLLM(model_name="mockllm", config={"outputs": [
        "Hi, I'm calling about my account - are there any financial assistance programs I might qualify for?",
        "Sure, let me get that set up for you right now.",
        RepIntent.ACCEPTED
    ]});

    opening = build_call_graph();
    result = opening spawn NegotiationAgent();

    assert result.outcome == "deal_reached";
    assert len(result.transcript) >= 3;
    assert "OUTCOME: deal reached" in result.transcript[-1];
}

test "a firm hard no from the rep leads to a dead end" {
    global llm;
    llm = MockLLM(model_name="mockllm", config={"outputs": [
        "Hi, I'm calling about my account - are there any financial assistance programs I might qualify for?",
        "No, we don't offer anything like that, sorry.",
        RepIntent.HARD_NO
    ]});

    opening = build_call_graph();
    result = opening spawn NegotiationAgent();

    assert result.outcome == "dead_end";
    assert result.transcript[-1] == "OUTCOME: no assistance available";
}

test "escalation followed by acceptance still reaches a deal" {
    global llm;
    llm = MockLLM(model_name="mockllm", config={"outputs": [
        "Hi, I'm calling about my account - are there any financial assistance programs I might qualify for?",
        "I can't approve that myself, you'd need to talk to my supervisor.",
        RepIntent.NEEDS_ESCALATION,
        "Let me see what my supervisor can authorize for a hardship adjustment.",
        "Okay, my supervisor approved an interest-free payment plan for you.",
        RepIntent.ACCEPTED
    ]});

    opening = build_call_graph();
    result = opening spawn NegotiationAgent();

    assert result.outcome == "deal_reached";
}
