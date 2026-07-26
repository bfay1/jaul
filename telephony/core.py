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

# Jac's graph-native persistence works under `jac run` / `jac test` but not
# when Jac is driven from plain Python, which is what uvicorn does. So this
# process starts with an empty tactic graph every boot, and the exemplar banks
# the learning loop produced would be lost. Load them from the file the loop
# exports (see graph.save_exemplars) so live calls speak with what was learned.
EXEMPLAR_PATH = os.path.join(_ROOT, "exemplars.json")

# Live-call records can't persist to the graph from this process either, so
# they're appended here instead - the learning loop can mine them later.
CALL_LOG_PATH = os.path.join(_ROOT, "live_calls.jsonl")


def load_learned_exemplars(path: str = EXEMPLAR_PATH) -> int:
    """Apply exported exemplar banks to this process's tactic graph.

    Returns the number of lines loaded; 0 when the file is absent, so a fresh
    checkout serves calls normally with no exemplars rather than failing.
    """
    return _graph.load_exemplars(path)


_LOADED = load_learned_exemplars()


def load_case(path: str):
    """Load a markdown case file into a PatientCase (see casefile.load_case)."""
    from casefile import load_case as _load_case
    return _load_case(path)


class NegotiationSession:
    """One live call. Not thread-safe; one session per CallSid."""

    def __init__(self, call_id: str = "", patient=None) -> None:
        # The tactic graph is canonical and shared across every call - this
        # returns the same five nodes each time, so exemplars accumulate.
        self._node = _graph.get_or_build_call_graph()
        self.call_id = call_id
        # An _agent.PatientCase (e.g. via load_case), or None to let the
        # walker fall back to its demo_case() default.
        self._patient = patient
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

        kwargs = {
            "rep_utterance": rep_utterance,
            "transcript": list(self.transcript),
            "agent_lines": list(self.agent_lines),
            "tactic_path": list(self.tactic_path),
            "edge_path": list(self.edge_path),
            "deal_terms": self.deal_terms,
            "call_id": self.call_id,
        }
        if self._patient is not None:
            kwargs["patient"] = self._patient
        w = _agent.NegotiationTurn(**kwargs)
        spawn(w, self._node)

        self.transcript = list(w.transcript)
        self.agent_lines = list(w.agent_lines)
        self.tactic_path = list(w.tactic_path)
        self.edge_path = list(w.edge_path)
        self.deal_terms = w.deal_terms
        self.status = w.status
        if w.end_node is not None:
            self._node = w.end_node

        if self.status != "in_progress":
            self._log_call()
        return w.agent_line, w.status

    def _log_call(self) -> None:
        """Append the finished call to the JSONL log.

        The walker also writes a CallRecord to the graph, but that write does
        not survive this process (see EXEMPLAR_PATH note above), so this file
        is the durable copy the learning loop can mine.
        """
        import json

        record = {
            "call_id": self.call_id,
            "source": "live",
            "transcript": self.transcript,
            "agent_lines": self.agent_lines,
            "tactic_path": self.tactic_path,
            "edge_path": self.edge_path,
            "outcome": self.status,
            "deal_terms": self.deal_terms,
        }
        try:
            with open(CALL_LOG_PATH, "a") as f:
                f.write(json.dumps(record) + "\n")
        except OSError:
            # A demo call must not die because the log is unwritable.
            pass


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
