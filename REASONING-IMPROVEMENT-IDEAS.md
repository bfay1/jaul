# Improving the agent's reasoning — what to try next

Written after the first end-to-end tuning run (see `docs/sft-plan.md` §Results).
Ordered by expected value per hour, not by how interesting they are.

Everything here is motivated by something we actually observed. Where an idea is
speculative I say so.

---

## What the run told us

Four observations drive most of this list:

1. **Tactics were learned from the wrong unit.** Playbook rules are keyed to the
   tactic *node*. Against Runaround — a rep who never disputes eligibility and
   simply passes you along — the agent applied "cite the policy, open the
   application now" and went 6/8 → 3/8. The rules were right for the resistance
   they were mined against and wrong for a different kind.

2. **The agent has no model of who it is talking to.** It reacts turn by turn
   with no representation of the rep's behavior pattern, so it cannot notice
   "this one is deflecting, not refusing" and change approach.

3. **Nearly every call ran long.** Escalation rate was 86–96% and turns averaged
   8.2–8.5 against a cap of 10. The agent doesn't know it's running out of call.

4. **Real policy data was the single largest quality jump in the project** —
   larger than either tuning method. Grounding beat optimization.

---

## Tier 1 — do these first

### 1.1 Key the playbook to the edge, not just the node

**The most directly evidenced item on this list.** Today `Tactic.playbook` is a
flat list per node. Make it a map from incoming edge type to rules:

```jac
node Tactic {
    has playbook: dict[str, list[str]] = {};   # "SOFT_NO" -> [rules]
}
```

The walker already knows which edge it traversed — it's appending it to
`edge_path` one line earlier. Retrieval becomes "rules for being at Escalation
*because the rep stonewalled*" rather than "rules for Escalation."

This is also the most Jac-native thing on the list: the typed edge stops being
only a routing decision and becomes part of what the agent knows. Curation
changes from three distillation calls to one per (node, edge) pair that has
enough winning lines, falling back to the node-level playbook when it doesn't.

Cost: ~45 min. Risk: sparsity — 3 nodes × 5 edges is 15 cells and we only mined
~20 winning calls. Needs a fallback and probably more mining data.

### 1.2 Give the agent a model of the rep

Add an explicit belief state the walker carries and updates each turn:

```jac
obj RepModel {
    has posture: str = "unknown";     // deflecting | stonewalling | passing_off | upselling | cooperative
    has authority: str = "unknown";   // none | limited | can_approve
    has conceded: list[str] = [];     // what they've already granted
    has resisted: list[str] = [];     // what they've already refused
}
```

Update it with a cheap `by fast()` call each turn and pass it into
`generate_line` through the same `incl_info` channel. Two things fall out: the
agent stops re-asking for things already refused, and it can pick a strategy
matched to posture — which is the Runaround failure stated in general form.

`resisted` matters more than it looks. Reading the transcripts, several calls
burn turns re-requesting something the rep already declined.

Cost: ~40 min, one extra Haiku call per turn. Risk: another classifier to get
wrong; keep the enum small.

### 1.3 Tell the agent how much call it has left

One line of context: turns used, turns remaining. Right now the agent negotiates
identically on turn 2 and turn 9, then gets cut off mid-application. A human
advocate who knows the rep is about to hang up asks for the single most valuable
thing — a reference number, a written confirmation, a collections hold.

Cheapest item here by far and it targets the most common failure we saw
(hitting the cap). Pair it with an instruction about what to prioritize when
time is short.

Cost: ~15 min. Risk: could make the agent close prematurely; measure turns-to-
deal alongside deal rate.

---

## Tier 2 — promising, weaker evidence

### 2.1 Plan before speaking

`generate_line` is purely reactive. Insert a short planning step: state the goal
for this turn and the fallback if refused, then generate the line conditioned on
it. This is the classic reason-then-act split, and it gives the mining step
something better to learn from — a *plan* generalizes across patients more
cleanly than a sentence does.

It may also fix a distillation problem we hit: rules had to be reverse-engineered
from utterances. If the agent emits its intent explicitly, distillation reads
intents instead of guessing at them.

Cost: ~45 min, one extra generation call per turn. Risk: doubles the expensive
model's calls; consider running the planner on Haiku.

### 2.2 Generate several candidate lines and pick one

Best-of-N at the turn level: produce 3 candidates, score each against the rep
model, the policy facts, and what's already been refused, then speak the winner.
Generation is only about a quarter of our LLM calls, so 3× on that is roughly
1.5× overall.

This is worth trying *because* the playbook gains were small. If line quality
isn't the binding constraint, best-of-N won't help either — and that's a useful
negative result that tells us to stop optimizing phrasing and go after structure.

Cost: ~30 min. Risk: the scorer is a judge, and we already know judges are
unreliable at this (no configuration exceeded 0.65 AUROC on agentic success).
Score against concrete criteria, not "which is better."

### 2.3 Track what's still missing as a checklist

The commitment gate is binary: terms parse or they don't. Make it a live
checklist the agent reasons over — discount agreed, plan term, rate, written
confirmation, collections hold, reference number. Then the agent drives toward
gaps rather than reacting.

This turns the endgame from "keep talking until something closes" into
goal-directed behavior, and it composes well with 1.3: when turns are short, ask
for the highest-value unfilled item.

Cost: ~40 min. Risk: could make the agent rigid and checklist-y on a call where
the rep is already cooperating.

---

## Tier 3 — measurement, without which the above is guesswork

### 3.1 Deal quality should be a model judgment, not substring matching

`deal_quality` currently greps for `apr`, `setup fee`, `finance charge`. A
predatory deal phrased any other way scores as good. This is the metric the
whole objective rests on, and it's the flimsiest part of the pipeline. Make it a
structured `by llm()` returning an obj with a reason, like `extract_commitment`.

We got away with it because the Upseller says "24% APR" in so many words. A real
rep would not be so obliging.

### 3.2 Audit for deception

NegotiationArena found self-play agents boosting payoffs ~20% via deceptive
tactics such as feigned desperation. We mine winning trajectories, so any such
tactic gets promoted straight into the playbook. **We have never measured
whether this is happening.**

Add a pass that checks every mined line against the supplied patient facts and
rejects any claim not supported by them. This is a safety property, not a
performance one — for a patient-advocacy tool that shipped a deceptive tactic,
being right on deal rate would not be much comfort.

Cost: ~30 min, and it slots into the existing `clean_rule` guard.

### 3.3 Enough samples to see the effect

n=24 per arm cannot resolve an 8-point difference; the current headline is a
two-call swing. Roughly 200 per arm would resolve ~10 points. At ~6s per call
with 10-way parallelism that's ~20 minutes per arm, which is affordable now that
the harness works. Report confidence intervals rather than point estimates.

Also: 8 personas × 4 profiles is 32 cells. Several are unrepresentative — the
`p4_unknown_hospital` profile exercises the national-priors path, which is a
different code path, not just a different patient.

### 3.4 Expand the FAP corpus

Real policy data produced the largest quality jump in the project. We have two
hospitals. Each additional one is ~10 minutes of reading a published PDF, and it
makes the agent's claims checkable against a real institution rather than
national averages. Highest value-per-minute item in the whole document, and it
requires no ML at all.

---

## Things I would not do

**Fine-tune a small open model.** Already argued in the plan: it competes with
Sonnet and loses. Nothing in this run changes that.

**Adopt DSPy.** The integration cost is real — it wants to own the module graph,
and ours is a walker mid-traversal. What we hand-rolled is COPRO/APE-shaped
already.

**Sweep instruction variants blindly.** The distillation step is a better use of
the same budget, and probe-and-refine style diagnosis beats blind search.

**Add more adversarial personas before fixing 1.1.** We already have a persona
whose failure we don't understand well enough to fix. More of them would add
variance, not information.

---

## If there were time for exactly one thing

**1.1 — edge-keyed playbooks.** It's the only item with a direct experimental
result behind it, it's the most Jac-native change available, and it turns the
typed-edge design from a routing mechanism into something the agent reasons
with. If it works, the graph stops being scaffolding around the LLM and starts
being the thing that makes the LLM better — which is the claim the project is
supposed to demonstrate.
