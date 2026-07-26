"""Bridge from the phone transport to the Jac negotiation core.

A NegotiationSession owns one call's graph position and transcript, and exposes
`start()` / `advance(rep_utterance)` — each returns the agent's next line and
the call status. Under the hood every step spawns the Jac `NegotiationTurn`
walker, which advances the tactic graph exactly one hop. The OSP traversal in
agent.jac stays the single source of negotiation logic; this file just carries
state between webhooks.
"""
import os
import sys

# Make the .jac modules importable no matter where uvicorn is launched from.
_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _ROOT not in sys.path:
    sys.path.insert(0, _ROOT)

import jaclang  # noqa: F401 — registers the .jac import hook (dev install)
import graph as _graph
import agent as _agent
from jaclang.lib import spawn

# Safety cap: even a rep who loops forever gets a graceful hangup.
MAX_TURNS = 12


def load_case(path: str):
    """Load a markdown case file into a PatientCase (see casefile.load_case)."""
    from casefile import load_case as _load_case
    return _load_case(path)


class NegotiationSession:
    """One live call. Not thread-safe; one session per CallSid."""

    def __init__(self, patient=None) -> None:
        self._node = _graph.build_call_graph()   # this call's fresh opening node
        # An _agent.PatientCase (e.g. via load_case), or None to let the walker
        # fall back to its demo_case() default.
        self._patient = patient
        self.transcript: list[str] = []
        self.status: str = "in_progress"
        self.turns: int = 0

    def start(self) -> tuple[str, str]:
        """Begin the call: the agent's opening line. Returns (line, status)."""
        return self._step(rep_utterance="")

    def advance(self, rep_utterance: str) -> tuple[str, str]:
        """Feed the rep's latest utterance and get the agent's reply."""
        return self._step(rep_utterance=rep_utterance)

    def _step(self, rep_utterance: str) -> tuple[str, str]:
        self.turns += 1
        if self.turns > MAX_TURNS and self.status == "in_progress":
            self.status = "dead_end"
            line = "I appreciate your time — I'll follow up in writing. Thank you."
            self.transcript.append("AGENT: " + line)
            return line, self.status

        kwargs = {"rep_utterance": rep_utterance, "transcript": list(self.transcript)}
        if self._patient is not None:
            kwargs["patient"] = self._patient
        w = _agent.NegotiationTurn(**kwargs)
        spawn(w, self._node)

        self.transcript = list(w.transcript)
        self.status = w.status
        if w.end_node is not None:
            self._node = w.end_node
        return w.agent_line, w.status


def use_mock_llm(outputs: list) -> None:
    """Swap the negotiation model for a deterministic mock (offline tests).

    `outputs` are consumed one per by-llm call, in order (strings for the
    generated lines, RepIntent members for the classifications).
    """
    from byllm.lib import MockLLM
    _agent.llm = MockLLM(model_name="mockllm", config={"outputs": outputs})
