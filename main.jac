"""Entry point for the hospital-billing negotiation agent (jaul).

Wires the tactic graph (`graph.jac`) to the negotiation engine (`agent.jac`)
and runs one call. This file stays thin on purpose - the graph shape lives in
graph.jac, the LLM logic and walker in agent.jac.
"""

import from graph { build_call_graph }
import from agent { NegotiationAgent, demo_patient }


with entry:__main__ {
    # root ++> opening happens inside build_call_graph, giving graph-native
    # persistence of every call's tactic graph and outcome across runs.
    # We still spawn directly on THIS call's opening node so the walker
    # only ever traverses the fresh subgraph, not prior calls' nodes.
    patient = demo_patient();
    opening = build_call_graph();

    result = opening spawn NegotiationAgent(patient=patient);

    print("--- patient ---");
    print(f"{patient.name} | {patient.hospital_name} | bill ${patient.bill_amount} | income ${patient.annual_income}, household {patient.household_size}");
    print("--- call transcript ---");
    for line in result.transcript {
        print(line);
    }
    print("--- outcome: " + result.outcome + " ---");
}
