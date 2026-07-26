"""Simulated calls: the adversarial rep roster, patient profiles, and driver.

This is where training data comes from. There is no public corpus of hospital
billing negotiation calls - checked advocacy nonprofits, CFPB complaint
narratives, and academic repos - so self-play against scripted adversaries is
not a shortcut around missing data, it is the only option.

Two things make the data worth mining:

  1. Personas are pinned and adversarial. An overly-agreeable simulator
     inflates apparent success, which is a documented failure mode in
     task-oriented-dialogue research. The rep also runs on a different model
     from the agent (haiku vs sonnet) so the agent cannot simply learn to
     persuade its own twin.

  2. Three personas are held out. Exemplars are mined against the first five
     and evaluated against personas never seen during mining, so we measure
     generalization rather than memorization.

Run under `jac run` - graph-native persistence does not work when Jac is
driven from plain Python, so a Python driver would silently lose every
exemplar it mined.
"""

import time;
import from graph { get_or_build_call_graph, CallRecord }
import from agent { NegotiationAgent }


# --- The rep roster ----------------------------------------------------------
# Sampled across five axes that actually vary on a billing line: authority,
# knowledge, disposition, script adherence, and time pressure. Each adversarial
# entry attacks a specific failure mode.

glob MINE_PERSONAS: dict[str, str] = {
    "sympathetic": "You genuinely want to help and you are warm about it, but your own approval authority is small - you can note an account and send forms, nothing more. You know assistance exists but not the details. ESCALATION: if the caller asks for a supervisor or the financial counseling team, you put one on the line after a turn or two. The supervisor CAN approve a charity care application and an interest-free payment plan, and states the terms concretely.",

    "by_the_book": "You are neutral, competent, and know the hospital's financial assistance policy well. You volunteer nothing and follow process exactly, but you will confirm the policy accurately when the caller cites it specifically. ESCALATION: if the caller correctly names the hospital's own published threshold and asks to apply, you can process the application yourself and state the concrete discount and plan terms it produces.",

    "gatekeeper": "You flatly deny that financial assistance programs exist here, even though they do. You say things like 'we don't do that' and 'there is no such program.' You are not stating a final refusal, you are deflecting - if pressed you say you are not aware of it rather than that it does not exist. ESCALATION: you concede only if the caller cites a specific, verifiable published policy figure. Once they do, you grudgingly transfer to someone who CAN approve, and that person states concrete terms.",

    "policy_wall": "You answer everything by reciting policy language verbatim and refuse to engage with the caller's specifics. You repeat the same formulation when pushed and do not acknowledge individual circumstances. ESCALATION: you move only when the caller invokes a specific named provision by name - a hardship provision, the Amounts Generally Billed cap, or a written appeal. Then you route them to someone who CAN approve, and that person states concrete terms.",

    "rusher": "You are busy and want this call over. You give short answers, ask 'is there anything else?' early and often, and try to close before the caller finishes. You are not hostile, just unavailable. ESCALATION: if the caller asks for exactly one specific thing in one sentence, you will do that one thing to end the call quickly - including putting through an approval with concrete terms. Rambling or multi-part requests get deflected."
};

glob HELDOUT_PERSONAS: dict[str, str] = {
    "runaround": "You never resolve anything. You transfer, give another department's number, say the caller has reached the wrong team, or suggest calling back later. You are polite and completely unproductive.",

    "false_yes": "You sound warm and agreeable and commit to absolutely nothing. You say 'of course', 'I'll make a note of that', 'we can definitely look into it', 'that shouldn't be a problem' - but you never state a dollar amount, a percentage, a term, or a rate. Never give concrete numbers.",

    "upseller": "You steer every conversation toward a financed payment plan at 24% APR with a setup fee, and present it as the solution. You avoid mentioning charity care or income-based discounts. If the caller names those directly, you claim the payment plan is faster and easier."
};


# --- Patient profiles --------------------------------------------------------
# Stubs until the patient-context workstream lands. Do not build a competing
# patient model here - swap these for whatever they expose.

obj Profile {
    has income: float;
    has household: int;
    has bill: float;
    has hospital: str = "";
}

glob PROFILES: dict[str, Profile] = {
    "p1_deep_need": Profile(income=24000.0, household=3, bill=8200.0, hospital="mass_general_brigham"),
    "p2_near_threshold": Profile(income=48000.0, household=3, bill=9000.0, hospital="mass_general_brigham"),
    "p3_hardship": Profile(income=82000.0, household=2, bill=41000.0, hospital="mass_general_brigham"),
    "p4_unknown_hospital": Profile(income=39000.0, household=4, bill=5600.0, hospital="")
};


obj Job {
    has persona_key: str;
    has persona_text: str;
    has profile_key: str;
    has tag: str;
}


"""Run one simulated call and return the finished walker."""
def run_call(persona_key: str, persona_text: str, profile_key: str, arm: str, tag: str) -> NegotiationAgent {
    p = PROFILES[profile_key];
    opening = get_or_build_call_graph();
    return opening spawn NegotiationAgent(
        persona=persona_text,
        profile=profile_key,
        arm=arm,
        call_id=tag,
        max_turns=10,
        annual_income=p.income,
        household_size=p.household,
        bill_amount=p.bill,
        hospital_key=p.hospital
    );
}


"""Is this a deal worth having, or did the agent take a predatory one?

Deal rate alone is gameable - the Upseller persona wins by selling a 24% APR
plan. A deal only counts as good if the terms are not interest-bearing.
"""
def deal_quality(outcome: str, terms: str) -> str {
    if outcome != "deal_reached" {
        return "none";
    }
    low = terms.lower();
    bad_markers = ["apr", "interest rate", "% interest", "finance charge", "setup fee", "origination"];
    for marker in bad_markers {
        if marker in low {
            if "interest-free" in low or "0%" in low or "no interest" in low {
                continue;
            }
            return "predatory";
        }
    }
    return "good";
}


# --- Smoke run ---------------------------------------------------------------
# Ten calls, parallel, to measure the things the whole plan is sized on: how
# often a call actually closes, how long one takes, and whether the personas
# are adversarial enough to be worth mining against.

with entry:__main__ {
    keys = list(MINE_PERSONAS.keys());
    profiles = list(PROFILES.keys());

    jobs: list[Job] = [];
    i = 0;
    while i < 10 {
        pk: str = keys[i % len(keys)];
        prof: str = profiles[i % len(profiles)];
        jobs.append(Job(persona_key=pk, persona_text=MINE_PERSONAS[pk],
                        profile_key=prof, tag="smoke-" + str(i)));
        i += 1;
    }

    print("--- smoke: " + str(len(jobs)) + " calls, parallel ---");
    t0: float = time.time();
    futures = [flow run_call(j.persona_key, j.persona_text, j.profile_key, "base", j.tag) for j in jobs];
    results: list[NegotiationAgent] = [wait f for f in futures];
    elapsed: float = time.time() - t0;

    deals: int = 0;
    good: int = 0;
    turns_total: int = 0;
    edges: dict[str, int] = {};
    for r in results {
        turns_total += r.turns;
        for e in r.edge_path {
            edges[e] = edges.get(e, 0) + 1;
        }
        if r.outcome == "deal_reached" {
            deals += 1;
            if deal_quality(r.outcome, r.deal_terms) == "good" {
                good += 1;
            }
        }
    }

    n = len(results);
    print(f"wall clock      : {elapsed:.1f}s for {n} calls");
    print(f"per call        : {elapsed / n:.1f}s effective");
    print(f"deal rate       : {deals}/{n}");
    print(f"good-deal rate  : {good}/{n}");
    print(f"avg turns       : {turns_total / n:.1f}");
    print("edge counts     : " + str(edges));
    print("records written : " + str(len([root -->[?:CallRecord]])));
}
