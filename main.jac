"""Entry point for the hospital-billing negotiation agent (jaul).

Wires the tactic graph (`graph.jac`) to the negotiation engine (`agent.jac`)
and runs one call. This file stays thin on purpose - the graph shape lives in
graph.jac, the LLM logic and walker in agent.jac.
"""

import from graph { start_call, get_or_create_hospital }
import from agent { NegotiationAgent, PatientCase }
import from casefile { case_from_argv, hospital_from_argv }


with entry:__main__ {
    # Patient context is a markdown case file, configurable per run via
    # `--case <path>` (see casefile.py); it defaults to cases/jordan-rivera.md.
    # The `as` cast lands the untyped Python return into the typed PatientCase
    # the walker expects.
    patient = case_from_argv() as PatientCase;

    # Hospital is configurable via `--hospital <name>` (defaults to "Bay Area
    # General", matching the bundled demo case). Run with the same name across
    # several invocations to see cross-call learning shift the opening tactic.
    hospital_name = hospital_from_argv() as str;
    hospital = get_or_create_hospital(hospital_name);

    # root ++> hospital ++> opening happens inside get_or_create_hospital /
    # start_call, giving graph-native persistence of every call's tactic graph
    # and outcome across runs, grouped by hospital. We still spawn directly on
    # THIS call's opening node so the walker only ever traverses the fresh
    # subgraph, not prior calls' nodes.
    opening = start_call(hospital);

    result = opening spawn NegotiationAgent(patient=patient, hospital=hospital);

    print("--- hospital: " + hospital.name + " ---");
    print("--- case: " + patient.name + " ---");
    print("--- call transcript ---");
    for line in result.transcript {
        print(line);
    }
    print("--- outcome: " + result.outcome + " ---");

    # printgraph(opening) is a literal trace of the tactic path THIS call took
    # - different calls produce different shapes, since nothing was pre-wired.
    # Note: printgraph's depth is symmetric in both directions from the given
    # node, so with no depth limit it also climbs up through the Hospital to
    # root and back down into anything else there (other hospitals,
    # ProgramKnowledge facts) - fine for a demo with one hospital in play, but
    # worth knowing if the image ever looks busier than just this call.
    dot = printgraph(opening, file="call_graph.dot");
    print("--- graph written to call_graph.dot (" + str(len(dot)) + " bytes); render with: dot -Tsvg call_graph.dot -o call_graph.svg ---");
}
