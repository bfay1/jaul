"""Record ONE real negotiation call to a frozen JSON trace.

The offline demo (see `demo/`) replays a real, model-generated conversation
with no API key and no phone line. This script is what produces it: it runs a
genuine call - real `by llm()` dialogue, real classification, real live graph
construction - and serializes both the transcript and the graph the walker
actually built.

    source jac-env/bin/activate       # pinned jaclang 0.16.7 - see CLAUDE.md
    jac run capture_trace.jac         # needs ANTHROPIC_API_KEY in .env

Costs a few cents per run. Re-run only when you want a different demo call;
the committed `demo/trace.json` is a captured artifact, not a build product.

The graph walk below reads the tactic path back off the graph rather than
tracking it in the walker, so the trace records what was *actually built*
during the call - if the recorded path and the transcript ever disagreed, the
graph would be the honest one.
"""

import json;
import os;
import from datetime { datetime }

import from graph {
    Tactic, Opening, start_call, get_or_create_hospital,
    SoftNo, Stonewalling, NeedsEscalation, Accepted, HardNo
}
import from agent { NegotiationAgent, PatientCase }
import from casefile { case_from_argv, hospital_from_argv }

glob OUT_PATH: str = os.path.join(os.path.dirname(os.path.abspath(__file__)), "demo", "trace.json");


"""Follow the one outgoing tactic edge from `current`, if any.

Returns (edge_type_name, next_node), or ("", None) at a terminal node. The
edge type IS the rep's classified intent - that is the whole point of the
typed-edge design, so reading it back needs no separate record of intent.

The five checks are spelled out because an edge-type filter is a compile-time
literal in Jac; they cannot be collapsed into a loop over a list of types.
"""
def step_from(current: Tactic) -> tuple {
    soft = [current ->:SoftNo:->];
    if len(soft) > 0 {
        return ("SOFT_NO", soft[0]);
    }
    stone = [current ->:Stonewalling:->];
    if len(stone) > 0 {
        return ("STONEWALLING", stone[0]);
    }
    esc = [current ->:NeedsEscalation:->];
    if len(esc) > 0 {
        return ("NEEDS_ESCALATION", esc[0]);
    }
    acc = [current ->:Accepted:->];
    if len(acc) > 0 {
        return ("ACCEPTED", acc[0]);
    }
    hard = [current ->:HardNo:->];
    if len(hard) > 0 {
        return ("HARD_NO", hard[0]);
    }
    return ("", None);
}


"""Split the walker's flat transcript into (agent_line, rep_line) pairs.

The walker appends "AGENT: ..." then "REP: ..." per turn, and finally a single
"OUTCOME: ..." line, which is dropped here - the outcome is recorded
separately and structurally.
"""
def paired_turns(transcript: list[str]) -> list {
    pairs: list = [];
    pending: str = "";
    for line in transcript {
        if line.startswith("AGENT: ") {
            pending = line[7:];
        } elif line.startswith("REP: ") {
            pairs.append({"agent": pending, "rep": line[5:]});
            pending = "";
        }
    }
    return pairs;
}


with entry:__main__ {
    patient = case_from_argv() as PatientCase;
    hospital_name = hospital_from_argv() as str;
    hospital = get_or_create_hospital(hospital_name);
    opening = start_call(hospital);

    # The walker's default cap is 6 turns, which a realistic rep spends just
    # getting the account open - the first capture ran out mid-conversation on
    # "please hold". A demo call needs room to actually reach an outcome.
    print("Placing a real call against " + hospital_name + " for " + patient.name + "...");
    result = opening spawn NegotiationAgent(patient=patient, hospital=hospital, max_turns=8);

    # Read the tactic path back off the graph the walker just built.
    path: list = [];
    current: Tactic = opening;
    while True {
        (edge_name, next_node) = step_from(current);
        if next_node is None {
            break;
        }
        step: Tactic = next_node as Tactic;
        path.append({
            "from": current.label,
            "intent": edge_name,
            "to": step.label
        });
        current = step;
    }

    # Fuse transcript with graph path: turn i's reply is what produced edge i.
    pairs = paired_turns(result.transcript);
    turns: list = [];
    for i in range(len(pairs)) {
        pair: dict = dict(pairs[i]);
        tactic = "opening";
        intent = "";
        next_tactic = "";
        if i < len(path) {
            hop: dict = dict(path[i]);
            tactic = hop.get("from", "opening") as str;
            intent = hop.get("intent", "") as str;
            next_tactic = hop.get("to", "") as str;
        }
        turns.append({
            "turn": i + 1,
            "tactic": tactic,
            "agent": pair.get("agent", ""),
            "rep": pair.get("rep", ""),
            "intent": intent,
            "next_tactic": next_tactic
        });
    }

    trace: dict = {
        "captured_at": str(datetime.now().date()),
        "model": "claude-sonnet-4-6",
        "hospital": hospital_name,
        "patient": patient.name,
        "outcome": result.outcome,
        "deal_terms": result.deal_terms,
        "turns": turns,
        "final_node": current.label
    };

    os.makedirs(os.path.dirname(OUT_PATH), exist_ok=True);
    with open(OUT_PATH, "w") as f {
        json.dump(trace, f, indent=2);
    }

    print("--- transcript ---");
    for line in result.transcript {
        print(line);
    }
    print("--- outcome: " + result.outcome + " (" + str(len(turns)) + " turns) ---");
    print("--- wrote " + OUT_PATH + " ---");
}
