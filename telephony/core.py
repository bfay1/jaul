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


class NegotiationSession:
    """One live call. Not thread-safe; one session per CallSid."""

    def __init__(self, call_id: str = "") -> None:
        # The tactic graph is canonical and shared across every call - this
        # returns the same five nodes each time, so exemplars accumulate.
        self._node = _graph.get_or_build_call_graph()
        self.call_id = call_id
        self.transcript: list[str] = []
        self.status: str = "in_progress"
        self.turns: int = 0
        # Trajectory carried across webhook spawns; the walker writes a
        # CallRecord from it on the terminal turn.
        self.agent_lines: list[str] = []
        self.tactic_path: list[str] = []
        self.edge_path: list[str] = []
        self.deal_terms: str = ""

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

        w = _agent.NegotiationTurn(
            rep_utterance=rep_utterance,
            transcript=list(self.transcript),
            agent_lines=list(self.agent_lines),
            tactic_path=list(self.tactic_path),
            edge_path=list(self.edge_path),
            deal_terms=self.deal_terms,
            call_id=self.call_id,
        )
        spawn(w, self._node)

        self.transcript = list(w.transcript)
        self.agent_lines = list(w.agent_lines)
        self.tactic_path = list(w.tactic_path)
        self.edge_path = list(w.edge_path)
        self.deal_terms = w.deal_terms
        self.status = w.status
        if w.end_node is not None:
            self._node = w.end_node
        return w.agent_line, w.status


def use_mock_llm(gen_outputs: list, fast_outputs: list) -> None:
    """Swap both negotiation models for deterministic mocks (offline tests).

    Generation and classification run on separate models, so they need
    separate queues:
      gen_outputs  - one string per `generate_line` call.
      fast_outputs - per turn: the rep's reply, the RepIntent, and (only when
                     the intent is ACCEPTED) a Commitment for the gate.
    """
    from byllm.lib import MockLLM
    _agent.llm = MockLLM(model_name="mockllm", config={"outputs": list(gen_outputs)})
    _agent.fast = MockLLM(model_name="mockllm", config={"outputs": list(fast_outputs)})
