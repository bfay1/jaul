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


# --- Real assistance-program facts ------------------------------------------
# Root-anchored, seeded once, read by agent.jac and flattened to plain strings
# before ever reaching a by llm() call - never pass these nodes themselves
# into an LLM call (an obj/node parameter is the exact bug class that broke
# every call before Upgrade 1's fix).

node ProgramKnowledge {
    has name: str;
    has eligibility: str;
    has citation: str;
}

"""Seed the canonical assistance-program facts under root, once. Idempotent -
safe to call on every start_call()."""
def seed_program_knowledge() -> None {
    if len([root -->[?:ProgramKnowledge]]) > 0 {
        return;
    }
    root ++> ProgramKnowledge(
        name="IRS 501(r) Financial Assistance Policy",
        eligibility="Nonprofit hospitals must maintain a written Financial Assistance Policy (FAP) and determine FAP eligibility before pursuing extraordinary collection actions.",
        citation="IRC 501(r)(4)-(6)"
    );
    root ++> ProgramKnowledge(
        name="Amounts Generally Billed (AGB) cap",
        eligibility="FAP-eligible patients at a nonprofit hospital cannot be charged more than AGB - what insured patients would typically pay - for emergency or medically necessary care.",
        citation="IRC 501(r)(5)"
    );
    root ++> ProgramKnowledge(
        name="Charity care",
        eligibility="Many hospitals offer free or deeply discounted care for patients under roughly 200-400% of the Federal Poverty Level, varying by hospital policy.",
        citation="Hospital-specific Financial Assistance Policy"
    );
    root ++> ProgramKnowledge(
        name="Interest-free payment plans",
        eligibility="Patients who don't qualify for a discount can often still get a monthly payment plan with no interest or fees added.",
        citation="Hospital billing policy"
    );
    root ++> ProgramKnowledge(
        name="Itemized bill review",
        eligibility="Patients can request an itemized bill and dispute duplicate or incorrect charges before paying.",
        citation="Standard billing practice"
    );
}

"""Flatten seeded program facts into plain strings for LLM context."""
def program_context() -> list[str] {
    facts: list[str] = [];
    for p in [root -->[?:ProgramKnowledge]] {
        facts.append(p.name + ": " + p.eligibility + " (" + p.citation + ")");
    }
    return facts;
}


"""Start a call: create just the opening node, attached to root.

Nothing else is pre-wired - the walker in agent.jac builds every subsequent
node and edge live, per turn, as the rep's responses come in.
"""
def start_call() -> Opening {
    seed_program_knowledge();
    opening: Opening = Opening(label="opening");
    root ++> opening;
    return opening;
}
