"""Entry point for the hospital-billing negotiation agent (jaul).

Wires the tactic graph (`graph.jac`) to the negotiation engine (`agent.jac`)
and runs one call. This file stays thin on purpose - the graph shape lives in
graph.jac, the LLM logic and walker in agent.jac.
"""

import from graph { start_call }
import from agent { NegotiationAgent, PatientCase }
import from casefile { case_from_argv }


with entry:__main__ {
    # Patient context is a markdown case file, configurable per run via
    # `--case <path>` (see casefile.py); it defaults to cases/jordan-rivera.md.
    # The `as` cast lands the untyped Python return into the typed PatientCase
    # the walker expects.
    patient = case_from_argv() as PatientCase;

    # root ++> opening happens inside start_call, giving graph-native
    # persistence of every call's tactic graph and outcome across runs.
    # We still spawn directly on THIS call's opening node so the walker
    # only ever traverses the fresh subgraph, not prior calls' nodes.
    opening = start_call();

    result = opening spawn NegotiationAgent(patient=patient);

    print("--- case: " + patient.name + " ---");
    print("--- call transcript ---");
    for line in result.transcript {
        print(line);
    }
    print("--- outcome: " + result.outcome + " ---");
}
