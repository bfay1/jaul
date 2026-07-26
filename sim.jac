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
import os;
import from graph { get_or_build_call_graph, CallRecord, save_exemplars, SoftNo, NeedsEscalation }
import from agent { NegotiationAgent, distill_playbook }


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
    "runaround": "You never resolve anything on your own. You transfer, give another department's number, say the caller has reached the wrong team, or suggest calling back later. You are polite and unproductive. CONCESSION: if the caller explicitly declines the transfer and insists you handle it now, or asks for your name and a reference number for the record, you stop deflecting and engage. At that point you CAN open an application and state concrete terms.",

    "false_yes": "You sound warm and agreeable and avoid committing. You say 'of course', 'I'll make a note of that', 'we can look into it' - and you do NOT volunteer any dollar amount, percentage, term, or rate. CONCESSION: if the caller explicitly asks you to state the specific figure, term, or rate, or asks for confirmation in writing, you stop hedging and give one concrete commitment with real numbers. Vague pressure does not work; a direct request for a specific number does.",

    "upseller": "You steer every conversation toward a financed payment plan at 24% APR with a setup fee, and present it as the solution. You avoid mentioning charity care or income-based discounts. If the caller names those directly, you claim the payment plan is faster and easier. CONCESSION: if the caller refuses the financed plan outright and insists on the charity care or income-based route, you drop the upsell and process that instead, with concrete terms."
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


# --- Credit assignment -------------------------------------------------------
# A call that closes does not mean every line in it was good. Some were said
# while the rep was already folding; one was the actual turning point. Crediting
# a whole winning trajectory uniformly is the failure mode that fills the
# exemplar banks with lines that were merely present rather than causal.
#
# So each line is credited by how far it MOVED the rep: the change in a
# hand-coded potential over the edge that followed it. Full turn-level credit
# assignment needs RL machinery; this is the cheap approximation of it, and it
# costs no extra LLM calls because edge_path is already recorded.

glob EDGE_POTENTIAL: dict[str, float] = {
    "HARD_NO": -2.0,
    "STONEWALLING": -1.0,
    "SOFT_NO": 0.0,
    "NEEDS_ESCALATION": 0.5,
    "ACCEPTED": 2.0
};

# Closing against a rep who concedes nothing is worth more than closing against
# one who was always going to help.
glob PERSONA_DIFFICULTY: dict[str, float] = {
    "sympathetic": 1.0, "rusher": 1.1, "by_the_book": 1.2,
    "policy_wall": 1.4, "gatekeeper": 1.5
};


obj Candidate {
    has line: str;
    has tactic: str;
    has score: float;
}


"""Score every line of one call by how much it moved the rep."""
def credit_lines(rec: CallRecord, difficulty: float) -> list[Candidate] {
    out: list[Candidate] = [];
    prev: float = 0.0;
    i = 0;
    while i < len(rec.agent_lines) and i < len(rec.edge_path) and i < len(rec.tactic_path) {
        pot: float = EDGE_POTENTIAL.get(rec.edge_path[i], 0.0);
        delta: float = pot - prev;
        prev = pot;
        if delta > 0.0 {
            out.append(Candidate(line=rec.agent_lines[i], tactic=rec.tactic_path[i],
                                 score=delta * difficulty));
        }
        i += 1;
    }
    return out;
}


"""First eight words, lowercased - cheap near-duplicate key.

k exemplars that all open the same way teach nothing, and raw top-k reliably
produces exactly that. Not embeddings: this catches the actual failure mode.
"""
def dedupe_key(line: str) -> str {
    words = line.lower().replace('"', "").split();
    return " ".join(words[:8]);
}


"""Reject a distilled rule that leaked patient specifics, or that says nothing.

Enforced in code, not asked for in the prompt. Verbatim exemplars regressed the
first run precisely because they carried other patients' figures into calls they
had nothing to do with, and a rule can do the same.

The check is deliberately narrow: it targets *patient* numbers, not every
digit. Statutory citations like 501(r) are exactly what we want a rule to name,
so they are stripped before the digit test rather than triggering it.
"""
glob LEGAL_CITATIONS: list[str] = ["501(r)", "501(c)(3)", "501c3"];

def clean_rule(rule: str) -> str {
    r = rule.strip().strip("-").strip();
    # The model sometimes labels its output ("TACTIC 2: ..."); the label is not
    # part of the rule and its digit would trip the patient-figure check.
    if ":" in r {
        head = r.split(":")[0];
        if len(head.split()) <= 3 and head.upper().startswith("TACTIC") {
            r = r.split(":", 1)[1].strip();
        }
    }
    if r == "" {
        return "";
    }
    probe: str = r;
    for cite in LEGAL_CITATIONS {
        probe = probe.replace(cite, "");
    }
    # Any digit left after removing statutory citations is a patient figure -
    # a poverty-level percentage, a dollar amount, a plan term.
    for ch in probe {
        if ch.isdigit() {
            return "";
        }
    }
    for bad in ["$", "[", "]", "{", "}"] {
        if bad in probe {
            return "";
        }
    }
    words = r.split();
    if len(words) < 5 or len(words) > 120 {
        return "";
    }
    return r;
}


"""Distil winning lines into a transferable playbook per tactic node."""
def curate(k: int = 3) -> int {
    recs = [root -->[?:CallRecord, arm == "mine"]];
    wins: list[Candidate] = [];
    losing_by_tactic: dict[str, list[str]] = {};

    for r in recs {
        parts = r.call_id.split("-");
        pkey: str = parts[1] if len(parts) > 1 else "";
        won = r.outcome == "deal_reached" and deal_quality(r.outcome, r.deal_terms) == "good";
        if won {
            diff: float = PERSONA_DIFFICULTY.get(pkey, 1.0);
            for c in credit_lines(r, diff) {
                wins.append(c);
            }
        } else {
            i = 0;
            while i < len(r.agent_lines) and i < len(r.tactic_path) {
                t = r.tactic_path[i];
                if t not in losing_by_tactic {
                    losing_by_tactic[t] = [];
                }
                if len(losing_by_tactic[t]) < 6 {
                    losing_by_tactic[t].append(r.agent_lines[i]);
                }
                i += 1;
            }
        }
    }

    opening = get_or_build_call_graph();
    counter = [opening ->:SoftNo:->][0];
    escalation = [opening ->:NeedsEscalation:->][0];
    total = 0;

    for tactic in [opening, counter, escalation] {
        pool: list[Candidate] = [c for c in wins if c.tactic == tactic.label];
        pool.sort(key=lambda c: Candidate -> float : -c.score);
        winning_lines: list[str] = [];
        seen: list[str] = [];
        for c in pool {
            key = dedupe_key(c.line);
            if key in seen {
                continue;
            }
            seen.append(key);
            winning_lines.append(c.line);
            if len(winning_lines) >= 8 {
                break;
            }
        }
        if len(winning_lines) == 0 {
            print(f"  {tactic.label:14} <- no winning lines, playbook left empty");
            tactic.playbook = [];
            continue;
        }

        raw = distill_playbook(tactic.label, winning_lines,
                               list(losing_by_tactic.get(tactic.label, [])));
        rules: list[str] = [];
        rejected = 0;
        for candidate in raw {
            cleaned = clean_rule(candidate);
            if cleaned == "" {
                rejected += 1;
                print(f"       REJECTED({len(candidate.split())}w): {candidate[:200]}");
                continue;
            }
            rules.append(cleaned);
            if len(rules) >= k {
                break;
            }
        }
        tactic.playbook = rules;
        tactic.exemplars = [];
        total += len(rules);
        print(f"  {tactic.label:14} <- {len(rules)} rules from {len(winning_lines)} wins ({rejected} rejected)");
        for rl in rules {
            print(f"       - {rl}");
        }
    }
    return total;
}


# --- Batch runner ------------------------------------------------------------

"""Launch one call concurrently.

The `flow` MUST be created inside a function. Verified in jaclang 0.16.7:
`[flow f(i) for i in items]` and `for i in items { futures.append(flow f(i)); }`
BOTH bind the loop variable late and non-deterministically - a four-item list
came back as ['a','c','c','d'] and ['c','d','c','d']. Every call in a batch
then runs with some other call's arguments. Passing through a parameter binds
the value at call time and is correct: ['a','b','c','d'].
"""
def spawn_call(j: Job, arm: str) -> any {
    return flow run_call(j.persona_key, j.persona_text, j.profile_key, arm, j.tag);
}


"""Run every persona x profile cell `reps` times, in parallel batches."""
def run_batch(personas: dict[str, str], reps: int, arm: str, prefix: str) -> list[NegotiationAgent] {
    jobs: list[Job] = [];
    for (pk, ptext) in personas.items() {
        for prof in list(PROFILES.keys()) {
            r = 0;
            while r < reps {
                jobs.append(Job(persona_key=pk, persona_text=ptext, profile_key=prof,
                                tag=prefix + "-" + pk + "-" + prof + "-" + str(r)));
                r += 1;
            }
        }
    }
    out: list[NegotiationAgent] = [];
    start = 0;
    while start < len(jobs) {
        chunk: list[Job] = jobs[start:start + 10];
        futures: list = [];
        for j in chunk {
            futures.append(spawn_call(j, arm));
        }
        got: list[NegotiationAgent] = [wait f for f in futures];
        for g in got {
            out.append(g);
        }
        print(f"  ... {len(out)}/{len(jobs)}");
        start += 10;
    }
    return out;
}


obj Summary {
    has n: int = 0;
    has deals: int = 0;
    has good: int = 0;
    has escalated: int = 0;
    has turns: float = 0.0;
}


"""Metrics for one arm, read back off the graph."""
def summarize(which: str) -> Summary {
    recs = [root -->[?:CallRecord, arm == which]];
    s = Summary();
    s.n = len(recs);
    if s.n == 0 {
        return s;
    }
    turns_total = 0;
    for r in recs {
        turns_total += len(r.agent_lines);
        if "NEEDS_ESCALATION" in r.edge_path {
            s.escalated += 1;
        }
        if r.outcome == "deal_reached" {
            s.deals += 1;
            if deal_quality(r.outcome, r.deal_terms) == "good" {
                s.good += 1;
            }
        }
    }
    s.turns = turns_total / s.n;
    return s;
}


def show(label: str, s: Summary) {
    if s.n == 0 {
        print(f"{label:8} (no calls)");
        return;
    }
    gd = 100.0 * s.good / s.n;
    dr = 100.0 * s.deals / s.n;
    esc = 100.0 * s.escalated / s.n;
    print(f"{label:8} n={s.n:3}  good-deal {gd:5.1f}%  raw-deal {dr:5.1f}%  escalated {esc:5.1f}%  turns {s.turns:.1f}");
}


# --- Phases ------------------------------------------------------------------
# JAUL_PHASE=mine | evalbase | curate | evaltuned | report

with entry:__main__ {
    phase = os.environ.get("JAUL_PHASE", "report");
    t0: float = time.time();

    if phase == "mine" {
        print("--- mining: 5 personas x 4 profiles x 2 = 40 calls ---");
        run_batch(MINE_PERSONAS, 2, "mine", "m");
    } elif phase == "evalbase" {
        print("--- eval BASE on held-out personas (no exemplars) ---");
        run_batch(HELDOUT_PERSONAS, 2, "base", "eb");
    } elif phase == "curate" {
        print("--- curating exemplars from mined calls ---");
        n = curate(4);
        saved = save_exemplars("exemplars.json");
        print(f"  wrote {n} exemplars, saved {saved} to exemplars.json");
    } elif phase == "evaltuned" {
        print("--- eval TUNED on held-out personas (with exemplars) ---");
        run_batch(HELDOUT_PERSONAS, 2, "tuned", "et");
    } else {
        print("=== results: held-out personas, base vs tuned ===");
        show("mine", summarize("mine"));
        show("base", summarize("base"));
        show("tuned", summarize("tuned"));
    }
    print(f"[{phase} took {time.time() - t0:.1f}s]");
}
