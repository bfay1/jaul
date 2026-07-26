"""The negotiation tactic graph: nodes, typed edges, and how to build one.

This module owns the *shape* of a negotiation - the tactics, the transitions
between them, and the per-call record we learn from. No LLM or walker logic;
the walker that traverses this lives in `agent.jac`.

The tactic graph is CANONICAL: one shared set of five nodes for every call
ever placed. That is what makes learning possible - a winning line written
onto `Escalation.exemplars` during call N is read by call N+1, because both
calls traverse the same node. Minting a fresh graph per call (which this
module used to do) makes the exemplar banks silently inert.
"""

# --- Graph shape -----------------------------------------------------------
# Every negotiation tactic is a typed node. All tactic nodes share the
# `Tactic` base so the pre-wired transition edges below can be typed
# `Tactic --> Tactic` instead of duplicated per concrete pair.
#
# `sem` on a node/edge archetype is what the graph means, expressed on the
# graph itself rather than duplicated inside each prompt. byLLM reads these.

node Tactic {
    has label: str;
    # Winning lines previously spoken from this tactic. Retrieved at
    # generation time - this list IS the learned artifact.
    has exemplars: list[str] = [];
    # Transferable tactics distilled from what worked at this node. Unlike raw
    # exemplars, these carry no patient-specific figures - a rule cannot leak
    # another patient's poverty-level percentage or plan terms into this call.
    has playbook: list[str] = [];
    has visit_count: int = 0;
}
sem Tactic = "A phase of a hospital-billing negotiation the agent can be in.";

node Opening(Tactic) {}
sem Opening = "The start of the call: introduce the request and ask, openly, what financial assistance programs exist.";

node CounterOffer(Tactic) {
    has offer_terms: str = "";
}
sem CounterOffer = "The agent proposes something specific - a percentage discount, a charity-care application, or an interest-free payment plan - rather than asking open-endedly.";

node Escalation(Tactic) {}
sem Escalation = "The agent asks to involve a supervisor or the financial-assistance department, because the current rep cannot approve what is being asked.";

node DealReached(Tactic) {
    has terms: str = "";
}
sem DealReached = "The rep committed to a concrete, verifiable arrangement. Terminal.";

node DeadEnd(Tactic) {
    has reason: str = "";
}
sem DeadEnd = "The call ended without an arrangement. Terminal.";

# Edges are typed by what the rep just said - the transition *is* the
# classification, not a branch in the walker's logic.
edge SoftNo: Tactic --> Tactic {}
sem SoftNo = "The rep deflected: vague, noncommittal, no real progress, but not a refusal.";

edge Stonewalling: Tactic --> Tactic {}
sem Stonewalling = "The rep will not move further at their level, but has not issued a final no.";

edge NeedsEscalation: Tactic --> Tactic {}
sem NeedsEscalation = "The rep cannot personally approve this; a supervisor must get involved.";

edge Accepted: Tactic --> Tactic {}
sem Accepted = "The rep committed to a concrete arrangement, with terms specific enough to hold them to.";

edge HardNo: Tactic --> Tactic {}
sem HardNo = "The rep firmly and finally refused.";


# --- Per-call record: the training data ------------------------------------
# One CallRecord per call, hung off root. Every metric in the eval is a query
# over these, and every exemplar mined in Phase 2 comes from these.

node CallRecord {
    has call_id: str = "";
    has persona: str = "";          # which rep persona this call faced
    has profile: str = "";          # which patient profile
    has arm: str = "";              # "base" | "tuned" - for the A/B
    has transcript: list[str] = [];
    has agent_lines: list[str] = [];   # just the agent's lines, in order
    has tactic_path: list[str] = [];   # node labels, in visit order
    has edge_path: list[str] = [];     # edge types taken, in order
    has outcome: str = "";             # "deal_reached" | "dead_end"
    has deal_terms: str = "";          # parsed commitment, if any
    has deal_quality: str = "none";    # "good" | "predatory" | "none"
    has note: str = "";                # one-line postmortem, feeds diagnosis
}


# --- Exemplar transfer -------------------------------------------------------
# Graph-native persistence works under `jac run` / `jac test` but NOT when Jac
# is driven from plain Python (verified: the Jac path accumulates across runs,
# the Python path starts fresh every time and writes land inconsistently).
# Telephony is Python - uvicorn/FastAPI - so a live call would otherwise begin
# with empty exemplar banks and learn nothing.
#
# These two functions bridge that gap. The learning loop runs under `jac run`,
# persists natively, and exports; the telephony process imports at startup and
# gets the learned banks in memory for every call it serves.

import json;
import os;

"""Write the canonical graph's exemplar banks to a JSON file."""
def save_exemplars(path: str) -> int {
    opening = get_or_build_call_graph();
    banks: dict = {};
    total = 0;
    tactics: list[Tactic] = [
        opening, [opening ->:SoftNo:->][0], [opening ->:NeedsEscalation:->][0]
    ];
    for tactic in tactics {
        banks[tactic.label] = {
            "exemplars": list(tactic.exemplars),
            "playbook": list(tactic.playbook)
        };
        total += len(tactic.playbook);
    }
    with open(path, "w") as f {
        json.dump(banks, f, indent=2);
    }
    return total;
}

"""Load exemplar banks from a JSON file onto the canonical graph.

Returns the number of lines loaded; 0 if the file does not exist, so a fresh
checkout runs fine with no exemplars rather than crashing.
"""
def load_exemplars(path: str) -> int {
    if not os.path.exists(path) {
        return 0;
    }
    with open(path) as f {
        banks = json.load(f);
    }
    opening = get_or_build_call_graph();
    total = 0;
    tactics: list[Tactic] = [
        opening, [opening ->:SoftNo:->][0], [opening ->:NeedsEscalation:->][0]
    ];
    for tactic in tactics {
        raw = banks.get(tactic.label, {});
        # Tolerate the older flat shape ({label: [lines]}) as well as the
        # current one ({label: {exemplars: [], playbook: []}}).
        if isinstance(raw, list) {
            tactic.exemplars = list(raw);
            tactic.playbook = [];
        } else {
            entry: dict = dict(raw);
            tactic.exemplars = list(entry.get("exemplars", []));
            tactic.playbook = list(entry.get("playbook", []));
        }
        total += len(tactic.playbook) + len(tactic.exemplars);
    }
    return total;
}


"""Get the canonical tactic graph, building it once if it does not exist.

Idempotent by design. Every call - simulated or live - spawns against the
same five nodes, so exemplars accumulate across calls and across process
restarts via Jac's graph-native persistence.
"""
def get_or_build_call_graph() -> Opening {
    existing = [root -->[?:Opening]];
    if existing {
        return existing[0];
    }

    opening: Opening = Opening(label="opening");
    counter: CounterOffer = CounterOffer(label="counter_offer");
    escalation: Escalation = Escalation(label="escalation");
    deal: DealReached = DealReached(label="deal_reached");
    dead: DeadEnd = DeadEnd(label="dead_end");

    root ++> opening;

    opening +>:SoftNo():+> counter;
    opening +>:Stonewalling():+> escalation;
    opening +>:NeedsEscalation():+> escalation;
    opening +>:HardNo():+> dead;
    opening +>:Accepted():+> deal;

    # Every tactic node wires all five intents. A node missing one silently
    # ends the call: the walker's `visit [...] else` fallback fires and the
    # negotiation reports dead_end even though the rep never refused.
    counter +>:Accepted():+> deal;
    counter +>:SoftNo():+> escalation;
    counter +>:Stonewalling():+> escalation;
    counter +>:NeedsEscalation():+> escalation;
    counter +>:HardNo():+> dead;

    # Escalation self-loops on everything short of a decision: the supervisor
    # deflecting, holding firm, or handing off again all mean "keep pressing".
    # Only Accepted/HardNo leave the node; max_turns bounds the loop.
    escalation +>:Accepted():+> deal;
    escalation +>:SoftNo():+> escalation;
    escalation +>:Stonewalling():+> escalation;
    escalation +>:NeedsEscalation():+> escalation;
    escalation +>:HardNo():+> dead;

    return opening;
}
