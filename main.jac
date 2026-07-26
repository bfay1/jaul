"""Entry point for the hospital-billing negotiation agent (jaul).

Wires the tactic graph (`graph.jac`) to the negotiation engine (`agent.jac`)
and runs one call. This file stays thin on purpose - the graph shape lives in
graph.jac, the LLM logic and walker in agent.jac.
"""

import from graph { get_or_build_call_graph }
import from agent { NegotiationAgent, PatientCase }
import from casefile { case_from_argv }


with entry:__main__ {
    # Patient context is a markdown case file, configurable per run via
    # `--case <path>` (see casefile.py); it defaults to cases/jordan-rivera.md.
    # The `as` cast lands the untyped Python return into the typed PatientCase
    # the walker expects.
    patient = case_from_argv() as PatientCase;

    # The tactic graph is canonical: get_or_build_call_graph() creates the five
    # nodes once, under root, and every call thereafter traverses those same
    # nodes. That is what makes the learning loop possible - exemplars written
    # onto a node during one call are read by the next, and `jac clean --data`
    # is the only thing that resets it.
    opening = get_or_build_call_graph();

    # No structured 501(r) grounding (annual_income/hospital_key/etc.) passed
    # here: those are precise numbers for a hospital in data/fap_corpus.json,
    # and the bundled demo case (Bay Area General) isn't in that dataset -
    # citing mismatched real figures for a different hospital would be
    # incoherent. They default to inert (see agent.jac's assistance_facts).
    result = opening spawn NegotiationAgent(
        patient=patient,
        persona="A by-the-book billing rep with limited approval authority who knows the hospital has assistance programs but sticks closely to policy language.",
        call_id="cli-run",
        arm="base"
    );

    print("--- case: " + patient.name + " ---");
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
