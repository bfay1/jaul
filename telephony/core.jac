"""Bridge from the phone transport to the Jac negotiation core.

A NegotiationSession owns one call's graph position and transcript, and exposes
`start()` / `advance(rep_utterance)` - each returns the agent's next line and
the call status. Under the hood every step spawns the `NegotiationTurn`
walker, which advances the tactic graph exactly one hop.

This module is itself native Jac now (not a Python bridge through
jaclang.lib): `spawn` works as the normal infix operator inside a plain `obj`
method, verified directly before writing this - no `jaclang.lib.spawn(...)`
function-call form needed. graph.jac / agent.jac are imported the same way
main.jac imports them.
"""
import from graph { Hospital, Tactic, get_or_create_hospital, start_call }
import from agent { NegotiationTurn, PatientCase }

# Safety cap: even a rep who loops forever gets a graceful hangup.
glob MAX_TURNS: int = 12;


"""One live call. Not thread-safe; one session per CallSid.

Resolved/created once per session and reused every turn, so cross-call
learning (Hospital/CallOutcome) groups repeated calls against the same
hospital rather than starting fresh each time.
"""
obj NegotiationSession {
    has hospital_name: str = "Bay Area General";
    has patient: PatientCase | None = None;
    has hospital: Hospital by postinit;
    has node: Tactic by postinit;
    has transcript: list[str] = [];
    has status: str = "in_progress";
    has turns: int = 0;
    has last_intent: str = "";   # this turn's RepIntent classification, "" before any reply
    has last_move: str = "";     # this turn's chosen TacticMove, "" if terminal or none yet
    has patient_name: str {
        getter -> str { return self.patient.name if self.patient is not None else "the patient"; }
    }

    def postinit {
        self.hospital = get_or_create_hospital(self.hospital_name);
        self.node = start_call(self.hospital);   # this call's fresh opening node
    }

    """Begin the call: the agent's opening line. Returns (line, status)."""
    def start -> tuple[str, str] {
        return self._step("");
    }

    """Feed the rep's latest utterance and get the agent's reply."""
    def advance(rep_utterance: str) -> tuple[str, str] {
        return self._step(rep_utterance);
    }

    def _step(rep_utterance: str) -> tuple[str, str] {
        self.turns += 1;
        if self.turns > MAX_TURNS and self.status == "in_progress" {
            self.status = "dead_end";
            line = "I appreciate your time - I'll follow up in writing. Thank you.";
            self.transcript.append("AGENT: " + line);
            return (line, self.status);
        }

        if self.patient is None {
            w = NegotiationTurn(rep_utterance=rep_utterance, transcript=list(self.transcript), hospital=self.hospital);
        } else {
            w = NegotiationTurn(rep_utterance=rep_utterance, transcript=list(self.transcript), hospital=self.hospital, patient=self.patient);
        }
        self.node spawn w;

        self.transcript = list(w.transcript);
        self.status = w.status;
        self.last_intent = w.last_intent;
        self.last_move = w.last_move;
        if w.end_node is not None {
            self.node = w.end_node;
        }
        return (w.agent_line, w.status);
    }
}


"""Swap the negotiation model for a deterministic mock (offline tests).

`outputs` are consumed one per by-llm call, in order (strings for the
generated lines, RepIntent/TacticMove members for the decisions).
"""
def use_mock_llm(outputs: list) {
    import from byllm.lib { MockLLM }
    import agent;
    agent.llm = MockLLM(model_name="mockllm", config={"outputs": outputs});
}
