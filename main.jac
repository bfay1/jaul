"""Entry point for the hospital-billing negotiation agent (jaul).

Wires the tactic graph (`graph.jac`) to the negotiation engine (`agent.jac`)
and runs one simulated call. This file stays thin on purpose - the graph shape
lives in graph.jac, the LLM logic and walker in agent.jac.
"""

import from graph { get_or_build_call_graph }
import from agent { NegotiationAgent }


with entry:__main__ {
    # The tactic graph is canonical: get_or_build_call_graph() creates the five
    # nodes once, under root, and every call thereafter traverses those same
    # nodes. That is what makes the learning loop possible - exemplars written
    # onto a node during one call are read by the next, and `jac clean --data`
    # is the only thing that resets it.
    opening = get_or_build_call_graph();

    result = opening spawn NegotiationAgent(
        persona="A by-the-book billing rep with limited approval authority who knows the hospital has assistance programs but sticks closely to policy language.",
        call_id="cli-run",
        arm="base"
    );

    print("--- call transcript ---");
    for line in result.transcript {
        print(line);
    }
    print("--- outcome: " + result.outcome + " ---");
    if result.deal_terms != "" {
        print("--- terms: " + result.deal_terms + " ---");
    }
    print("--- tactics: " + str(result.tactic_path) + " ---");
    print("--- edges:   " + str(result.edge_path) + " ---");
}
