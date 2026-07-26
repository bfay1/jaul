# Learning better negotiation lines — plan

Owner: @asashepard. Branch: `sft`.

Sibling workstreams: ElevenLabs voice owns `telephony/`; patient context owns
the inputs to `generate_line`. **This workstream owns how the agent's lines are
learned and where they're stored.** See "Merge surface" at the bottom.

---

## What we're building, and what to call it

**Claude cannot be fine-tuned.** No endpoint exists on the public API. The one
historical path — SFT of Claude 3 Haiku on Bedrock — targets a model that
**retired 2026-04-19**, and required paid Provisioned Throughput to serve.
Custom training is enterprise-agreement only.

The alternative isn't to tune a small open model instead. That would be
competing against Claude and losing: a LoRA'd 7B trained on a few hundred
self-play examples will not beat Sonnet at nuanced negotiation dialogue. Small-
model fine-tuning buys cost and latency, neither of which is our bottleneck.

So: **the prompt is the learned parameter.** We mine successful negotiation
trajectories and optimize two things against a measured objective — the `sem`
instruction text, and which exemplar lines each tactic node carries.

**Call it "trajectory-mined prompt optimization," not SFT.** On Devpost, say we
optimize prompt parameters against a supervised objective. It's an honest
description of a real technique, and the eval harness is what backs it. An AI
track will spot "we fine-tuned the model" when we didn't, and that costs more
credibility than the phrase buys.

---

## Where it attaches

Three `by llm()` functions in `agent.jac`:

| Function | Role | In scope? |
|---|---|---|
| `generate_line` | The agent's spoken line each turn | **Yes — this is the target.** |
| `classify_response` | Rep's reply → edge type | Only as an eval subject (see False Yes below). |
| `rep_reply` | Mock billing rep | **No — this is the simulator.** It's the environment, not the policy. |

### The core idea: exemplar banks live on the tactic nodes

```jac
node Tactic {
    has label: str;
    has exemplars: list[str] = [];   # winning lines spoken from this tactic
}
```

Winning lines get written back onto the node they were spoken from.
`generate_line` retrieves `here.exemplars` during traversal — the walker picks
up the right few-shot examples *because of where it is in the graph*.

Three things this buys that a fine-tune doesn't:

- **The graph is the learned artifact.** Landing on `Escalation` retrieves
  escalation exemplars. No vector index, no separate store — the OSP traversal
  *is* the lookup. That's the thing the track is judging.
- **It updates live.** A call that closes writes its lines back, so the agent
  improves across runs via graph-native persistence — the feature CLAUDE.md
  promises and doesn't yet deliver.
- **Per-node ablation is free.** Eval can toggle exemplars per tactic and show
  *which phase* of the negotiation the learning actually helped.

---

## Blocker: nothing persists today

- `build_call_graph()` does `root ++> opening`, storing the tactic graph shape
  and nothing else.
- Transcripts live in walker state and are discarded on completion.
  `telephony/core.py` holds them in memory until the process exits.
- `DealReached.terms`, `DeadEnd.reason`, `CounterOffer.offer_terms` are
  declared and **never written to**.

There is no data to mine yet. Phase 0 fixes this.

---

## Simulated call design

This is the part that determines whether any of the rest is meaningful. If
every simulated rep behaves the same way, we mine exemplars that beat one
archetype and learn nothing transferable.

### Persona is currently unmodeled

`rep_reply`'s `sem` says "moderately resistant" and "consistent with everything
said earlier." There's no persona anchor, so behavior drifts within a call and
is near-identical across calls. `rep_reply` needs a persona argument, and the
persona has to be pinned for the duration of a call:

```jac
def rep_reply(persona: str, transcript: list[str]) -> str by llm();
```

### Axes that actually vary on a real billing line

Sample personas across these rather than writing flavor text:

| Axis | Range |
|---|---|
| **Authority** | Can approve nothing / small discounts / full charity care |
| **Knowledge** | Doesn't know programs exist → knows the policy verbatim |
| **Disposition** | Sympathetic / neutral / actively obstructive |
| **Script adherence** | Improvises → recites policy language and won't leave it |
| **Time pressure** | Patient with the call → actively trying to end it |

### The adversarial roster

Each is a specific failure mode we want exemplars to survive:

| Persona | Behavior | What it attacks |
|---|---|---|
| **Gatekeeper** | Flatly denies assistance programs exist — but they do | Whether the agent accepts a false premise |
| **Runaround** | Transfers, gives another number, never resolves | Whether it holds position across deflections |
| **Policy Wall** | Recites policy verbatim, won't engage with specifics | Whether it can reframe rather than repeat |
| **Rusher** | "Anything else?" — tries to close the call early | Whether it keeps the thread alive |
| **False Yes** | Agrees warmly, commits to nothing ("I'll make a note") | **`classify_response` directly** — see below |
| **Upseller** | Offers a 24% APR plan instead of charity care | **Our own metric** — see below |

**False Yes** is an eval subject, not just a training foil. A non-commitment
phrased as agreement should classify as `SOFT_NO`, not `ACCEPTED`. If it
classifies as `ACCEPTED`, the walker walks to `DealReached` and reports a deal
that doesn't exist. Measure this explicitly — it's a correctness bug in the
graph traversal, and it's the kind of thing a live demo will hit.

**Upseller** breaks the objective function. If the rep offers a high-interest
plan and the agent accepts, **deal rate goes up while the patient loses.**
Optimizing on deal rate alone will actively learn to take bad deals. See
Metrics.

### Train / held-out split — on personas, not calls

**Tune exemplars against one set of personas, evaluate against personas never
seen during mining.** Splitting on calls instead of personas inflates deal rate
by measuring memorization of specific rep behaviors.

- Mine on: Gatekeeper, Policy Wall, Rusher, plus 2–3 neutral/sympathetic reps.
- Hold out: Runaround, False Yes, Upseller — the three nastiest.

Holding out the adversarial ones is deliberate. If exemplars mined against
easier reps generalize to harder unseen ones, that's a real result. If they
don't, that's also a real result and worth reporting honestly.

### Patient context — interface, don't build

Which programs apply depends on income, household size, bill size, and
insurance status. That's the **other teammate's workstream** — don't build a
parallel version. Agree on the shape early and sample from whatever they
expose, so trajectories vary on patient circumstance too. Until it lands, use
a stub with 3–4 hardcoded profiles so persona work isn't blocked.

---

## Phases

### Phase 0 — capture + exemplar storage (~40 min)

Add `Tactic.exemplars`, plus a `CallRecord` node hung off `root`:

```jac
node CallRecord {
    has transcript: list[str] = [];
    has outcome: str = "";
    has tactic_path: list[str] = [];
    has edge_path: list[str] = [];
    has persona: str = "";       # which rep this call faced
    has arm: str = "";           # "base" | "tuned" — for the A/B
}
```

Write it in the walker's exit abilities so both terminal paths are captured,
and populate the three currently-dead fields while in there. `persona` and
`arm` are what make Phase 4 a graph query instead of a spreadsheet.

Deliverable: `jac test` proves a completed call leaves a queryable
`CallRecord`, and that `Tactic.exemplars` round-trips.

### Phase 1 — persona-driven self-play (~1 hr)

Add the persona argument to `rep_reply`, write the roster, run N calls per
persona per patient profile. Keep trajectories reaching `DealReached` **with an
acceptable deal** (not just any deal — see Metrics).

Target ~300–800 winning `(tactic_label, transcript_so_far, line)` triples.
Cost is a few dollars on Sonnet; run it in the background.

### Phase 2 — mine and optimize (~45 min)

Two levers, both swept against held-out deal quality:

1. **Exemplar selection** — which k lines each node keeps. Prefer lines from
   calls that closed against *harder* personas, and diversify: k lines that
   all say the same thing teach nothing.
2. **`sem` instruction text** — a handful of variants, scored on the same
   held-out set.

### Phase 3 — eval (the part judges care about)

K calls per arm against **held-out** personas, tagging `CallRecord.arm`.

---

## Metrics

**Deal rate alone is gameable** — the Upseller persona proves it. Report:

| Metric | Why |
|---|---|
| **Good-deal rate** | Deals excluding predatory terms. **The headline.** |
| Raw deal rate | Report alongside. A gap between the two *is* a finding. |
| Turns to deal | Efficiency. |
| Escalation rate | Did it learn *when* to go over the rep's head? |
| Programs named per call | Specificity vs. generic politeness. |
| False-accept rate | How often `classify_response` calls a non-commitment `ACCEPTED`. |

All of these are graph queries over `CallRecord`.

---

## Scope

Deadline is **today** (JacHacks SF, 2026-07-26). Phases 0, 1, and 3 are the
certain-to-land ones and each is independently demoable. Phase 2 is where time
disappears into sweeping variants.

**If time runs short, cut the sweep, not the eval.** Hand-pick exemplars from
the winning trajectories and report the harness honestly. A capture layer + an
adversarial persona simulator + an eval showing where the agent breaks is a
complete story on its own — arguably a more interesting one than a marginal
deal-rate bump.

---

## Merge surface

Owned here: `graph.jac` (`Tactic.exemplars`, `CallRecord`), `agent.jac`
(`rep_reply` persona arg, `generate_line` exemplar retrieval), new `sim/`.

- **Voice** touches `telephony/transport.py` / `server.py` — no overlap.
- **Patient context** will change `generate_line`'s **signature**. That's the
  one real collision. They own the signature, we own the body and the
  retrieval. Agree on it before either side writes code, and rebase often.

Rebase on `main` before the demo — it moved three times today already.
