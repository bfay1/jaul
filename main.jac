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
        arm="base",
        # Real 501(r) grounding: a household of three on $48,000 sits at 176%
        # of the 2026 federal poverty level, under Mass General Brigham's
        # published 300% threshold. See fap.jac / data/fap_corpus.json.
        annual_income=48000.0,
        household_size=3,
        bill_amount=9000.0,
        hospital_key="mass_general_brigham"
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
