"""The negotiation tactic graph: nodes, typed edges, and how to build one.

This module owns the *shape* of a negotiation - the tactics and the
transitions between them - with no LLM or walker logic. The walker that
traverses it lives in `agent.jac`.
"""

# --- Graph shape -----------------------------------------------------------
# Every negotiation tactic is a typed node. All tactic nodes share the
# `Tactic` base so the pre-wired transition edges below can be typed
# `Tactic --> Tactic` instead of duplicated per concrete pair.

node Tactic {
    has label: str;
}

node Opening(Tactic) {}

node CounterOffer(Tactic) {
    has offer_terms: str = "";
}

node Escalation(Tactic) {}

node DealReached(Tactic) {
    has terms: str = "";
}

node DeadEnd(Tactic) {
    has reason: str = "";
}

# Edges are typed by what the rep just said - the transition *is* the
# classification, not a branch in the walker's logic.
edge SoftNo: Tactic --> Tactic {}
edge Stonewalling: Tactic --> Tactic {}
edge NeedsEscalation: Tactic --> Tactic {}
edge Accepted: Tactic --> Tactic {}
edge HardNo: Tactic --> Tactic {}


"""Pre-wire every tactic transition a live call could take.

The walker does not know in advance which edge it will follow out of
a node - that is decided live, per turn, by classifying the rep's
response. This just lays down the possible transitions once.
"""
def build_call_graph() -> Opening {
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

    counter +>:Accepted():+> deal;
    counter +>:Stonewalling():+> escalation;
    counter +>:HardNo():+> dead;

    escalation +>:Accepted():+> deal;
    escalation +>:NeedsEscalation():+> escalation;
    escalation +>:HardNo():+> dead;

    return opening;
}
