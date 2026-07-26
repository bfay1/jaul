# SFT plan — making the agent's lines better

Owner: @asashepard. Branch: `sft`.

Sibling workstreams (don't collide): ElevenLabs voice lives in `telephony/`;
patient context lives in the graph/prompt inputs. **This workstream owns
`generate_line` and the data around it.** See "Merge surface" at the bottom.

---

## The constraint that shapes the whole plan

**You cannot SFT Claude.** Anthropic does not expose fine-tuning on the public
API — no endpoint exists in the API surface. The one historically supported
path was supervised fine-tuning of **Claude 3 Haiku on Amazon Bedrock**, and
that model **retired on 2026-04-19** — three months ago. It also required
buying Bedrock Provisioned Throughput to serve the result, which is not a
hackathon budget. Custom model training exists only under enterprise
agreements.

So "SFT" here means: **fine-tune a small open-weights model to imitate
successful negotiation lines, and swap it in for `generate_line` only.**
Classification and the rep simulator stay on Claude.

This is a better demo anyway — it gives a measurable before/after on a metric
that matters (deal rate), instead of a vibes claim about nicer wording.

---

## Where SFT attaches

Three `by llm()` functions in `agent.jac`:

| Function | Role | SFT target? |
|---|---|---|
| `generate_line` | Produces the agent's spoken line each turn | **Yes — primary.** This *is* "conversation responses." |
| `classify_response` | Maps the rep's reply to an edge type | Secondary. Easy to eval (labeled), cheap to serve, but it already works. |
| `rep_reply` | Mock billing rep | **No — this is the data generator.** Keep it on Claude; it's the environment. |

The swap itself is two lines, because byLLM binds models per function via any
module-level `glob`:

```jac
glob negotiator: Model = Model(model_name="ollama/jaul-negotiator");
def generate_line(tactic_label: str, transcript: list[str]) -> str by negotiator();
```

`classify_response` and `rep_reply` keep using `glob llm` (Claude). That
isolation is the point: one function changes, the graph traversal and the
evaluation harness are identical across base and tuned runs.

---

## Blocker: there is currently zero training data

**Nothing persists a transcript.** This is the single biggest gap and Phase 0
exists only to fix it.

- `build_call_graph()` does `root ++> opening`, which persists the *tactic
  graph shape* — five nodes and their edges — and nothing else.
- The transcript lives in walker state (`NegotiationAgent.transcript`) and is
  discarded when the walker finishes. `telephony/core.py` keeps it in an
  in-memory `NegotiationSession` that dies with the process.
- `DealReached.terms`, `DeadEnd.reason`, and `CounterOffer.offer_terms` are
  declared in `graph.jac` but **never written to**.

CLAUDE.md claims graph-native persistence of "call history/outcomes." Today
that claim is aspirational. Phase 0 makes it true, which is worth doing on its
own merits — it's a judged Jac feature and currently a hole in the demo.

---

## Phases

Sequential; each is independently demoable, so a stall doesn't sink the rest.

### Phase 0 — capture layer (~30 min)

Persist every call as graph data hanging off `root`. New node type in
`graph.jac`:

```jac
node CallRecord {
    has transcript: list[str] = [];
    has outcome: str = "";
    has tactic_path: list[str] = [];   # ["opening", "counter_offer", ...]
    has edge_path: list[str] = [];     # ["SoftNo", "NeedsEscalation", ...]
    has model_tag: str = "";           # "base" | "tuned" — for the A/B
}
```

Write it in the walker's exit ability so it captures both terminal paths, and
populate the three dead fields while we're in there. `model_tag` is what makes
Phase 4's comparison a graph query instead of a spreadsheet.

Deliverable: `jac test` proves a completed call leaves a queryable
`CallRecord` under `root`.

### Phase 1 — self-play data generation (~1 hr)

`rep_reply` is already a negotiation simulator. Run the agent against it N
times with varied rep personas and patient contexts, and keep the trajectories
that reach `DealReached`.

This is rejection sampling / behavior cloning on successes: train only on
lines that actually led to a deal. No real call recordings needed — which
matters, because real hospital billing calls are both scarce and legally
fraught to collect.

- Vary the rep: seed `rep_reply` with a persona (hard-liner, sympathetic,
  by-the-book, new hire) so trajectories aren't all the same shape.
- Target ~300–800 accepted `(tactic_label, transcript_so_far) → agent_line`
  pairs. Small, but LoRA on a 7B needs far less than people expect.
- Emit JSONL from a graph query over `CallRecord` — the capture layer means
  this is a read, not a separate pipeline.

Cost check: each simulated call is ~3 LLM calls/turn × ~4 turns. A few hundred
calls on Sonnet is single-digit dollars. Run it in the background while Phase 2
tooling is set up.

### Phase 2 — train (~1–1.5 hr, mostly unattended)

LoRA on a small instruct model — Qwen2.5-7B-Instruct or Llama-3.1-8B-Instruct.
On an M-series Mac, use MLX or unsloth; if it's slow, rent an A100 hour.

Keep it boring: rank 16, 2–3 epochs, hold out 10% for eval. The goal is not a
better base model, it's a model that has internalized *this* negotiation
register — persistent, specific, never pushy, always naming a concrete program.

### Phase 3 — serve and swap (~30 min)

`ollama create jaul-negotiator -f Modelfile` from the merged adapter, then the
two-line glob swap above. byLLM talks to Ollama natively (`ollama/<name>`), no
API key, no network.

Keep a `JAUL_NEGOTIATOR_MODEL` env var so the demo can flip between base and
tuned live. That flip *is* the demo moment.

### Phase 4 — evaluation (the part judges care about)

Run K held-out negotiations per arm against the same seeded rep personas,
tagging `CallRecord.model_tag`. Report:

| Metric | Why |
|---|---|
| **Deal rate** | The headline. Did SFT make it close more? |
| Turns to deal | Efficiency — fewer turns is a better call. |
| Escalation rate | Did it learn *when* to go over the rep's head? |
| Programs named per call | Proxy for specificity vs. generic politeness. |

All four are graph queries over `CallRecord`. Ship the harness even if
training underdelivers — "we built the eval and the tuned model didn't beat
base on deal rate" is an honest, respectable result, and it's still a working
`by llm()`-swappable pipeline.

---

## Scope warning

The hackathon deadline is **today** (JacHacks SF, 2026-07-26). Phases 0, 1, and
4 are the ones that are certain to land and are individually demoable. Phase 2
is the one that can eat unbounded time — GPU setup, dependency hell, a training
run that doesn't converge.

**If Phase 2 is at risk, cut it, not the others.** A capture layer + self-play
data generator + eval harness with a documented "tuned model pending" is a
complete, coherent story. A half-finished training run with no eval is not.

Fallback that preserves the demo: instead of weight-level SFT, do
**prompt-level distillation** — mine the winning trajectories for the highest-
value few-shot exemplars and inject them into `generate_line`'s `sem`. Same
data pipeline, same eval harness, same before/after chart, ~20 minutes instead
of ~2 hours. Weaker claim, but it is honestly describable as
"trajectory-mined" rather than "fine-tuned" — do not call it SFT on Devpost.

---

## Merge surface

Files this branch owns: `graph.jac` (adds `CallRecord`), `agent.jac`
(the `negotiator` glob + `generate_line` binding), plus new `sft/` tooling.

Conflict risk is low but real:
- **Voice workstream** touches `telephony/transport.py` and `server.py` — no
  overlap.
- **Patient-context workstream** likely changes `generate_line`'s *signature*
  (adding a patient-context arg). That's the one genuine collision. Agree
  early that they own the signature and we own the binding, and rebase often.

Rebase on `main` before the demo — `main` moved three times today already.
