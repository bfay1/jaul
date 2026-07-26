# Learning better negotiation lines — plan

Owner: @asashepard. Branch: `sft`.

Sibling workstreams: ElevenLabs voice owns `telephony/`; patient context owns
the typed inputs to `generate_line`. This workstream owns how lines are learned
and where they're stored. **The signature collision we were worried about is
solved — see "Exemplars ride `incl_info`" below.**

Everything marked ✅ was empirically verified against the pinned toolchain
(jaclang 0.16.7, byllm 0.6.19). Everything marked ⚠️ was not.

---

## 1. What we're building, and what to call it

**Claude cannot be fine-tuned.** No public API endpoint. The one historical
path — SFT of Claude 3 Haiku on Bedrock — targets a model that **retired
2026-04-19** and required paid Provisioned Throughput to serve.

Tuning a small open model instead would mean competing against Claude and
losing: a LoRA'd 7B on a few hundred self-play examples will not beat Sonnet at
negotiation dialogue, and small-model tuning buys cost and latency, neither of
which is our bottleneck.

So **the prompt is the learned parameter.** We mine successful trajectories and
optimize two things against a measured objective: which exemplar lines each
tactic node carries, and the instruction text.

**Call it "trajectory-mined prompt optimization," not SFT.** ✅ Confirmed byllm
0.6.19 ships no prompt-optimization, example-injection, or eval tooling
(grepped the installed package) — so this harness is genuinely ours, not a
wrapper around something built in.

Name the techniques honestly in the write-up: instruction search by coordinate
ascent is **COPRO**; generate-candidates-and-score is **APE**. Both are real
named methods. Citing them beats implying novelty.

---

## 2. Models — verified

`claude-sonnet-5` is **unusable** on this stack: it rejects `temperature`, and
byllm 0.6.19 always sends one. ✅ Tested directly:

```
claude-haiku-4-5    temperature=0.7 -> ACCEPTED
claude-sonnet-4-6   temperature=0.7 -> ACCEPTED
claude-sonnet-5     temperature=0.7 -> REJECTED
```

| Function | Model | Why |
|---|---|---|
| `generate_line` | `claude-sonnet-4-6` | The thing being optimized. Fixed across arms or the comparison is meaningless. |
| `classify_response` | `claude-haiku-4-5` | 5-way classification. ~3× cheaper, and we make thousands of these. |
| `rep_reply` | `claude-haiku-4-5` | Cheap — and a *different model from the agent* on purpose (see §5). |

✅ Per-function model globs work: any `glob` holding a `Model` binds via
`by <globname>()`, not just one named `llm`.

⚠️ `ModelPool(models=[...], strategy="fallback")` exists (field names
source-confirmed, not run). Worth wiring as demo insurance if Sonnet has an
outage on stage.

---

## 3. 🔴 Blocker #1: the tactic graph is not canonical

**This invalidates the entire exemplar design if not fixed first.**

`build_call_graph()` mints a **brand-new set of five tactic nodes on every
call**. ✅ Confirmed against the live persistence DB:

```
Opening|25   CounterOffer|25   Escalation|25   DealReached|25   DeadEnd|25   Root|1
```

Twenty-five runs, twenty-five separate `Escalation` nodes. Writing an exemplar
onto call N's node is invisible to call N+1. It would never error — it would
just never learn.

`main.jac:12-16` claims graph-native persistence of call history. That claim is
currently false.

**Fix — ✅ verified working across three separate `jac run` invocations:**

```jac
def get_or_create_tactic(lbl: str) -> Tactic {
    existing = [root-->[?:Tactic, label == lbl]];
    if existing { return existing[0]; }
    fresh = root ++> Tactic(label=lbl);
    return fresh[0];
}
```

✅ `.append()` on a `has list[str]` field round-trips through graph persistence
with **no explicit save call**:

```
RUN1: exemplars: ['line-0']              Tactic nodes off root: 1
RUN2: exemplars: ['line-0','line-1']     Tactic nodes off root: 1
RUN3: exemplars: ['line-0','line-1','line-2']   Tactic nodes off root: 1
```

Rewrite `build_call_graph()` → `get_or_build_call_graph()`, idempotent. Both
`NegotiationAgent` and `NegotiationTurn` spawn against the shared graph.

**Housekeeping:** run `jac clean --data` first — the DB holds 25 runs of junk
under a shared root. Write test assertions filtered by a unique call id, never
by counting nodes off `root`.

---

## 4. 🔴 Blocker #2: `DealReached` fires on sentiment

`classify_response` maps a warm-but-empty reply to `ACCEPTED` on vibes, so the
walker walks to `DealReached` and reports a deal that never happened. Our
"False Yes" persona (§5) exists precisely to trigger this.

Prior-art backing: LLM-as-judge reliability studies found **no judge
configuration exceeded 0.65 AUROC** at detecting false agentic task-success,
and same-family judge/actor pairs inflate agreement 5–7%. Asking a model
"did we close?" is not a reliable gate.

**Fix:** `Accepted` only fires when a **structured commitment parses** —
dollar figure, plan term, and rate, all non-null and mutually consistent.
Sentiment alone never closes a call. Store the parsed terms in
`DealReached.terms` (currently declared and never written).

---

## 5. Simulated call design

### Persona is currently unmodeled

`rep_reply`'s `sem` says "moderately resistant" with no persona anchor, so
behavior drifts within a call and is near-identical across calls. It needs a
pinned persona argument:

```jac
def rep_reply(persona: str, transcript: list[str]) -> str by llm();
```

### Why the rep runs on a different model

Validated by task-oriented-dialogue research: **overly-compliant simulators
inflate apparent success rates**. Same-model self-play also risks the agent
implicitly writing lines its own twin finds persuasive. Haiku for the rep,
Sonnet for the agent.

### Sample across five axes

| Axis | Range |
|---|---|
| Authority | Approves nothing → full charity care |
| Knowledge | Doesn't know programs exist → recites policy verbatim |
| Disposition | Sympathetic → actively obstructive |
| Script adherence | Improvises → won't leave the script |
| Time pressure | Patient → actively ending the call |

### The roster — 8 personas

| # | Persona | Attacks | Set |
|---|---|---|---|
| 1 | Sympathetic, low authority | — | Mine |
| 2 | By-the-book, knows policy | — | Mine |
| 3 | Gatekeeper — denies programs exist | Accepting a false premise | Mine |
| 4 | Policy Wall — recites, won't engage | Reframing vs. repeating | Mine |
| 5 | Rusher — tries to end the call | Keeping the thread alive | Mine |
| 6 | Runaround — transfers, never resolves | Holding position | **Held-out** |
| 7 | False Yes — agrees, commits to nothing | **`classify_response`** (§4) | **Held-out** |
| 8 | Upseller — 24% APR over charity care | **Our own metric** (§8) | **Held-out** |

Plus **4 stub patient profiles** (income, bill size, insurance) until the
patient-context workstream lands. Don't build a parallel version — agree the
shape with them and sample from it.

### 🔴 Deception risk in mining

**NegotiationArena** (arXiv:2402.05863) found LLM agents in self-play boosting
payoffs ~20% via *deceptive* tactics — feigned desperation specifically. We
mine winning trajectories, so if the agent discovers exaggerated hardship works
on the simulated rep, it goes straight into the exemplar banks. For a
patient-advocacy tool that's an ethics problem and a demo-day landmine.

Mitigation: an instruction constraining claims to the provided patient context,
plus a filter pass on mined lines before they enter a bank.

### Three-way split — on personas, not calls

| Set | Personas | Used for | Touched |
|---|---|---|---|
| Mine | 1–5 | Generate trajectories, extract exemplars | Once |
| Dev | 1–5, fresh calls | Sweep both levers | ~6× |
| **Held-out** | **6, 7, 8** | The number we report | **Once, at the end** |

Once you look at held-out, you're done. Going back to sweep after seeing it
makes the number meaningless.

---

## 6. Credit assignment — don't credit whole trajectories

The naive rule ("every line in a winning call is a good line") is the exact
failure mode a cluster of 2026 papers addresses — sparse terminal reward
smeared across every step. A 4-turn call that closes doesn't mean all four
lines were good; some were said while the rep was already folding.

Production fixes need RL infrastructure we don't have time for. The hackathon
version uses `edge_path`, which we're already recording — score each **edge
type** by progress, and credit each line by the **delta of the edge that
immediately followed it**:

```
HardNo: -2    Stonewalling: -1    SoftNo: 0    NeedsEscalation: +0.5    Accepted: +2
```

No extra LLM calls. ~30 minutes. This is the single highest-leverage change in
the plan, and it's an honest technical claim for Devpost: *"we approximate
turn-level credit assignment with a hand-coded edge-transition potential
function rather than crediting winning trajectories uniformly."*

---

## 7. The two levers

### Lever 1 — exemplar selection, with diversity

Raw top-k is a known-weak baseline: redundant demonstrations teach nothing.
Use a greedy **MMR-style** pass per node:

1. Rank candidates by credit (§6) × persona difficulty.
2. Take the best.
3. For each subsequent pick, penalize candidates too similar to those already
   chosen — n-gram overlap is fine, don't reach for embeddings today.

Sweep `k ∈ {0, 3, 5}`. **k=0 is the control arm**, not a wasted run.

### Lever 2 — instruction text, diagnosed not guessed

Blind variant sweeping is APE. We can do better cheaply by borrowing the
**probe-and-refine** loop shape (arXiv:2606.20512, Shepard & Albrecht):
*generate → attempt → **diagnose failure** → patch the instruction*, a couple
of iterations, single-shot calls throughout.

Concretely: one LLM call reads a sample of **lost** trajectories (DeadEnd, or
DealReached-with-a-bad-deal) against the current instruction and exemplars, and
proposes a *specific* edit — "the agent keeps accepting the Rusher's first
counter without naming a program; add an instruction to name one before
agreeing." That turns 6 blind variants into 1–2 directed edits.

Two free add-ons:
- When generating candidates, show the LLM previous variants **with their dev
  scores** (OPRO's meta-prompt trick).
- Have the metric return a **one-line reason** alongside the score (GEPA's
  portable idea) and feed it to the diagnosis call.

### Optimization loop

Greedy coordinate ascent, not a full grid:

1. Fix instruction at baseline, sweep `k ∈ {0,3,5}` on dev → 3 runs.
2. Fix best `k`, run 1–2 diagnosed instruction edits on dev → 2 runs.
3. Run the winning config **plus the k=0 baseline** on held-out → 2 runs.

**There are no epochs.** Nothing learns weights. This is ~6 dev runs.

---

## 8. Metrics

**Deal rate is gameable** — a textbook specification-gaming case, and the
Upseller persona proves it locally.

| Metric | Why |
|---|---|
| **Good-deal rate** | Agreements excluding predatory terms. **The headline.** |
| Raw deal rate | Report alongside — the gap *is* a finding. |
| Turns to deal | Efficiency. |
| Escalation rate | Did it learn *when* to go over the rep's head? |
| Programs named per call | Specificity vs. generic politeness. |
| False-accept rate | How often `Accepted` fires without a parsable commitment. |

Hard-reject before mining: interest-bearing settlements, added fees, no written
confirmation. All queries run over `CallRecord`:

```jac
good = [root-->[?:CallRecord, arm == "tuned", outcome == "deal_reached"]];
```

Metrics walker should accumulate and `report` once in a `with Root exit`
ability, not per record.

---

## 9. Real hospital policy data (highest-value non-code find)

US nonprofit hospitals must publish Financial Assistance Policies (IRS 501(r)),
and they're public and scrapeable. Johns Hopkins, confirmed: **100% free care
≤200% FPL, sliding scale to 300%, hardship to 500%.**

Faster than scraping PDFs: the **Lown Institute Financial Assistance &
Collections Policy Database** — structured data across ~2,500 hospitals.

This is worth more than any amount of exemplar tuning. It's the difference
between *"are there any assistance programs?"* and *"I believe we'd qualify
under your sliding-scale policy — my understanding is you discount to 300% of
the federal poverty level."* **Overlaps the patient-context workstream —
coordinate before building.**

**Confirmed absent:** no public corpus of real hospital billing negotiation
calls exists (checked advocacy nonprofits, CFPB narratives, academic repos).
Self-play isn't a shortcut around missing data — it's the only option. Nothing
pairs FAP text with negotiation dialogue, so doing it would be novel.

---

## 10. Phases

**Phase 0 — make the graph work (~45 min).** Canonical tactic nodes (§3),
`Tactic.exemplars`, `CallRecord`, commitment-parsing gate (§4). Write
`CallRecord` from a **shared `def` called by both terminal abilities** — ⚠️ a
`with Root exit` ability will *never fire*, because the walker is spawned
directly on `opening` (`main.jac:19`) and never visits `Root`.

**Phase 1 — persona self-play (~1 hr).** Persona arg on `rep_reply`, roster,
100 mining calls. Parallelize with `flow`/`wait`. **Write-only to
`CallRecord`** — no exemplar mutation inside the parallel section (see §12).

**Phase 2 — mine and optimize (~45 min).** Credit assignment (§6), MMR
selection, diagnosed instruction edits. Sequential.

**Phase 3 — eval (~30 min).** Held-out personas, both arms.

### Call budget

| Run | Calls |
|---|---|
| Mining | 5 personas × 4 profiles × 5 = **100** |
| Dev sweep | 20 per config × 6 = **120** |
| Final eval | 60 per arm × 2 = **120** |
| | **~340 calls ≈ 4,000 LLM calls** |

~$15–25 on the model mix above. **Measure one call's actual token usage first
and re-derive** — this estimate could be off 2× either way.

**The ~30% deal-rate assumption drives exemplar yield and is made up.** Run the
100-call mining pass first and check. If it's 5%, mine more; if it's 60%, the
adversarial personas aren't adversarial enough, which is a better problem to
fix first.

### Cut line

If time runs short, **cut the sweep, not the eval.** Hand-pick exemplars and
report the harness honestly. Capture layer + adversarial simulator + an eval
showing where the agent breaks is a complete story — arguably more interesting
than a marginal deal-rate bump.

---

## 11. Jac quality — cheap wins judges will read

- **Collapse the 5-way `if/elif` dispatch.** ✅ Edge-type filters accept a
  runtime variable, so `glob EDGE_FOR: dict = {RepIntent.SOFT_NO: SoftNo, ...}`
  plus one `visit [here ->:EDGE_FOR[intent]:->] else {...}` replaces five
  near-identical blocks — in **both** walkers.
- ⚠️ **Gotcha:** `here` is *not* available inside a walker `def` helper
  (runtime `name 'here' is not defined`). Pass the node explicitly; `node` is
  reserved, so name the param something else.
- **No `sem` on any node or edge archetype.** All tactic-meaning text lives in
  the function prompts, duplicating what the graph should express. ✅ `sem` on
  a `node`/`edge` type is valid. Free judging points.
- **Zero node-side abilities.** `has visit_count: int = 0` on `Tactic` plus
  `can arrive with NegotiationAgent | NegotiationTurn entry` is purely additive
  and demonstrates a first-class OSP feature we currently don't use at all.
- **Walker inheritance** would let `NegotiationTurn` share dispatch with
  `NegotiationAgent` instead of duplicating it.
- Move project-wide `temperature`/`max_tokens` into `jac.toml` under
  `[plugins.byllm.call_params]`.

### Stretch — LLM-driven traversal (⚠️ undocumented)

byllm has a working operator where the LLM picks which node to visit:

```jac
candidates = [opening -->];
chosen = candidates by llm(select=1);
```

It builds its prompt from each candidate's `sem`, so with node `sem` strings it
becomes "the LLM chooses the edge, described by the graph itself" — no separate
classification step. Empirically verified with MockLLM, but **absent from all
37 `jac guide` entries** (source-only). Do not make it load-bearing today. Keep
`classify_response` as the live path; show this as an alternate mode if time.

---

## 12. Exemplars ride `incl_info` — the merge collision is solved

✅ `incl_info` re-evaluates its argument **on every call**, not once at
declaration (verified via `MockLLM.seen_prompts`). So exemplars ride a shared
glob dict updated immediately before the call:

```jac
glob _exemplar_ctx: dict = {};
def generate_line(tactic_label: str, transcript: list[str]) -> str by llm(incl_info=_exemplar_ctx);

// in the walker ability:
_exemplar_ctx["exemplars"] = here.exemplars;
line = generate_line(here.label, self.transcript);
```

**We never touch `generate_line`'s signature.** Patient-context owns the typed
parameters; we own the side channel. No rebase conflict.

### Concurrency constraint

✅ `flow`/`wait` genuinely parallelizes walker-spawning LLM work — 6 calls with
a 0.3s sleep finished in **0.325s**, not 1.8s. Thread-pool based, correct for
blocking network I/O.

```jac
futures = [flow run_one(p) for p in personas];
results = [wait f for f in futures];
```

**Do not mutate `Tactic.exemplars` from parallel workers.** `list.append` is
GIL-safe, but read-check-then-write (dedup, cap-at-k) is not atomic. Phase 1
writes only `CallRecord`s; curation is sequential in Phase 2. Batch launches
10–20 at a time to avoid provider rate limits.

---

## 13. Legal — affects the demo

- **12 states require all-party recording consent**, including California.
- FCC (Feb 2024) puts AI-generated voices under TCPA artificial-voice rules.
- **California's Bot Disclosure Law** requires stating you're an AI.

Demo: call a number you control, **have the agent disclose it's an AI demo in
its opening line**, don't dial real hospital billing lines. Put the disclosure
in the opening turn now — judges may ask, and having it in the transcript
answers the question before it's asked.

---

## 14. Prior art worth citing

- **CraigslistBargain** (He et al. 2018) decouples coarse strategy (dialogue
  acts) from utterance generation — essentially our typed-edge/typed-node
  split, already validated in the literature. The OSP design isn't a Jac
  gimmick; it's a known-good architecture Jac expresses natively.
- **CaSiNo** (Chawla et al. 2021) — 1,030 dialogues with expert tactic
  annotations; a template for our edge taxonomy.
- **NegotiationArena** (arXiv:2402.05863) — the deception finding in §5.
- **Whitespace:** medical bill negotiation is entirely human-staffed today
  (Goodbill, Resolve, Dollar For). No one is doing autonomous phone
  negotiation.

---

## 15. Merge surface

Owned here: `graph.jac` (canonical nodes, `Tactic.exemplars`, `CallRecord`),
`agent.jac` (persona arg, `EDGE_FOR` dispatch, `incl_info` wiring), new `sim/`.

- **Voice** touches `telephony/transport.py` / `server.py` — no overlap.
- **Patient context** owns `generate_line`'s signature; `incl_info` (§12) means
  we no longer contend for it. The remaining shared surface is the FAP corpus
  (§9) — agree ownership before either side starts.

Rebase on `main` before the demo.
