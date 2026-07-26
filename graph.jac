"""The negotiation tactic graph: nodes, typed edges, and how a call starts.

This module owns the *shape* of a negotiation - the tactic node types and the
edge types that can connect them - with no LLM or walker logic. The graph is
NOT pre-wired: only the opening node exists when a call starts. The walker in
`agent.jac` creates each subsequent node and edge live, per turn, as it
decides what to do next - the graph is a trace of the call, not a map drawn in
advance of it.
"""

# --- Graph shape -----------------------------------------------------------
# Every negotiation tactic is a typed node. All tactic nodes share the
# `Tactic` base so edges can be typed `Tactic --> Tactic` instead of
# duplicated per concrete pair.

node Tactic {
    has label: str;
}

node Opening(Tactic) {}

# Every tactic after the opening is a TacticStep - created live by the walker
# each turn, never pre-wired. `move` holds the chosen TacticMove's name (e.g.
# "CITE_501R"); `label` (inherited from Tactic) is set to the same value, so
# every existing `here.label` read (generate_line, printgraph, ...) keeps
# working unchanged whether `here` is the Opening or a TacticStep.
node TacticStep(Tactic) {
    has move: str = "";
}

node DealReached(Tactic) {
    has terms: str = "";
}

node DeadEnd(Tactic) {
    has reason: str = "";
}

# Edges are typed by what the rep just said - the transition *is* the
# classification, not a branch in the walker's logic. Unchanged from before:
# these were already RepIntent-shaped, they're just wired live now instead of
# pre-wired in bulk.
edge SoftNo: Tactic --> Tactic {}
edge Stonewalling: Tactic --> Tactic {}
edge NeedsEscalation: Tactic --> Tactic {}
edge Accepted: Tactic --> Tactic {}
edge HardNo: Tactic --> Tactic {}


"""Start a call: create just the opening node, attached to root.

Nothing else is pre-wired - the walker in agent.jac builds every subsequent
node and edge live, per turn, as the rep's responses come in.
"""
def start_call() -> Opening {
    opening: Opening = Opening(label="opening");
    root ++> opening;
    return opening;
}
