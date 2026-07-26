# Upgrade plan — making the OSP the star

> **This file is a hand-off prompt.** Paste it (or point a Claude Code session
> at it) to resume. It assumes no memory of the conversation that produced it.
> Goal: take jaul from "complete and working" to "flagship-worthy" for the
> JacHacks SF **Agentic AI** track, where judging weights *genuine* use of Jac's
> Object-Spatial Programming (OSP), not superficial graph dressing.

## Why these four upgrades

The current negotiation graph is **static and fully pre-wired** (`graph.jac`'s
`build_call_graph()` lays down all 5 nodes and every edge before the call
starts). The *traversal* is live, but the *graph* isn't — so a sharp judge can
fairly call it "a 5-state switch statement in graph clothing." That is exactly
the "superficial use" failure mode `CLAUDE.md` warns against. These upgrades
make the OSP *be* the logic:

1. **Dynamic graph construction** — build the graph *during* the call (the
   headline fix; everything else builds on it).
2. **Graph visualization** — show the live-built graph in the demo.
3. **Cross-call learning** — use root-graph persistence so the agent improves
   against a given hospital over repeated calls.
4. **Real-program grounding** — ground tactics in actual assistance programs
   (IRS 501(r), charity care) so it's a credible advocate, not a generic haggler.

---

## Before you touch any `.jac` — required reading

Jac syntax is easily hallucinated. The installed compiler ships **version-matched**
reference guides; they are authoritative over anything from memory or the web.

```bash
source jac-env/bin/activate          # Python 3.14 venv; do this in every shell
jac guide jac-node-edge-patterns     # creating nodes/edges live, traversal filters
jac guide jac-walker-patterns        # visit/spawn/disengage, entry abilities
jac guide jac-by-llm                 # by llm(), sem, enums, MockLLM, tools=[...]
jac guide jac-types                  # typing rules, unions, any-boundary
jac guide jac-testing                # jac test mechanics, MockLLM
```

## Verified gotchas (we already hit these — don't repeat them)

- **Docstrings go BEFORE a declaration, never inside the body.** A `"""..."""`
  as the first statement of a `def`/ability body is a *parse error*.
- **`by llm()` replaces the body** — never write both a body and `by llm(...)`.
  Describe everything LLM-visible with **`sem`**, not docstrings.
- **`++>` returns a LIST, not the node** — `n = here ++> Foo();` makes `n` a list;
  use `n[0]` (or `visit`-the-list directly).
- **Typed edges:** create with `a +>:E():+> b` (`+` both sides); traverse with
  `[here ->:E:->]` (**single** arrows). `-->:E:-->` is a parse error.
- **Declare edge endpoints** (`edge E: Tactic --> Tactic {}`) so traversal infers
  node types — our edges already do this.
- **MockLLM `outputs` are consumed sequentially, one per `by llm()` call**, in
  call order. Adding a new `by llm()` decision per turn means every test's output
  list gets longer — recount the call order carefully or tests desync.
- **Stale graph state:** `jac run`/`jac test` persist to `./.jac/`. Changing
  archetypes between runs can throw `NodeAnchor ... is not a valid reference!`.
  Reset with `yes | jac clean --all` (interactive prompt otherwise). **NOTE:**
  `rm -rf .jac` may be blocked by the sandbox — use `jac clean`. **Exception:**
  Upgrade 3 *wants* persistence across runs — see its section.
- **Model:** `glob llm: Model | MockLLM = Model(model_name="claude-sonnet-5")` in
  `agent.jac`. Auth via `ANTHROPIC_API_KEY` (in `.env`, gitignored). Never
  hardcode a key.
- **Python library mode** (how `telephony/` drives Jac): `import jaclang` first
  (registers the import hook), then `import graph` / `import agent`;
  `from jaclang.lib import spawn`; `root` is a **function** there — `root()`.

## Current architecture (what you're extending)

- **`graph.jac`** — `Tactic` base node; `Opening`/`CounterOffer`/`Escalation`/
  `DealReached`/`DeadEnd` subtypes; typed edges `SoftNo`/`Stonewalling`/
  `NeedsEscalation`/`Accepted`/`HardNo` (all `Tactic --> Tactic`);
  `build_call_graph() -> Opening` pre-wires everything and returns the opening
  node (also does `root ++> opening`).
- **`agent.jac`** — `glob llm`; `enum RepIntent` (+ per-member `sem`); three
  `by llm()` functions: `classify_response(response) -> RepIntent`,
  `generate_line(tactic_label, transcript) -> str`, `rep_reply(transcript) -> str`
  (the mock rep); `walker NegotiationAgent` (blocking full-loop, for the mock
  demo + `main.jac`); `walker NegotiationTurn` (advances ONE hop per spawn, for
  telephony); three MockLLM `test` blocks.
- **`main.jac`** — thin entry point: `build_call_graph()` then
  `opening spawn NegotiationAgent()`.
- **`telephony/`** — Python transport. `core.py` (`NegotiationSession` drives
  `NegotiationTurn` per turn), `transport.py` (`Transport` iface;
  `TurnBasedTransport` live, `StreamingTransport` documented seam), `server.py`
  (FastAPI webhooks), `dial.py` (Twilio outbound), `test_flow.py` (offline tests).

## Always verify with (all pass today; keep them passing)

```bash
jac check main.jac                 # type-checks graph + agent + main
jac test agent.jac                 # negotiation tests (MockLLM, no key)
python -m telephony.test_flow      # telephony flow tests (MockLLM, no key)
```

(Ignore litellm's red `Provider List:` banner during tests — harmless.)

---

## Upgrade 1 — Dynamic graph construction (do this FIRST)

**Goal.** The walker *builds* the negotiation graph as the call unfolds instead
of traversing a pre-wired one. Each call produces a differently-shaped graph
that is a literal trace of the conversation.

**Design.**
- Stop pre-wiring in `build_call_graph()`. Start a call with just an `Opening`
  node attached to `root` (keep a `start_call() -> Opening` that only creates the
  opening node, or repurpose `build_call_graph`).
- Add a **second LLM decision point**: `choose_next_tactic`. Introduce
  `enum TacticMove` of the moves the agent can pick — e.g. `ASK_ASSISTANCE`,
  `OFFER_INCOME_DISCOUNT`, `REQUEST_CHARITY_CARE`, `PROPOSE_PAYMENT_PLAN`,
  `CITE_501R`, `ESCALATE`, `ACCEPT_DEAL`, `WALK_AWAY` — each with a `sem`. Then
  `def choose_next_tactic(transcript: list[str], last_intent: RepIntent) -> TacticMove by llm();`
  (with `sem`). This is the "what do I try next" brain.
- Per turn the walker now:
  1. speaks the current node's line (`generate_line`, which should take the
     chosen `TacticMove` so the line reflects the tactic),
  2. reads the rep, classifies it (`classify_response -> RepIntent`, existing),
  3. calls `choose_next_tactic(...)` to pick the next move,
  4. **creates a new node for that move and a typed edge from `here` to it**
     (edge type = the `RepIntent` that triggered the move), then `visit`s it.
  5. `ACCEPT_DEAL`/`WALK_AWAY` (or `RepIntent.ACCEPTED`/`HARD_NO`) create a
     terminal `DealReached`/`DeadEnd` node and end the call.
- Keep the node taxonomy or generalize: simplest is a single `Tactic` node with
  a `has move: str` (the `TacticMove` name) + `has line: str`; keep
  `DealReached`/`DeadEnd` as terminals. Edges stay `RepIntent`-typed. (Decide
  and document which you pick.)

**Files.** `graph.jac` (node/edge defs, start-call helper), `agent.jac` (new
enum + `choose_next_tactic`, rewrite both walkers to build-as-they-go, update
tests), `main.jac` (call the new start helper), `telephony/core.py` (its
`NegotiationSession` must match the new `NegotiationTurn` shape).

**Acceptance.**
- Two runs of `jac run main.jac` produce graphs of **different shape/size**
  (verify via Upgrade 2's `printgraph`).
- `jac check main.jac` clean; `jac test agent.jac` + `python -m telephony.test_flow`
  pass (you WILL need to extend the MockLLM `outputs` lists — now one extra
  `choose_next_tactic` call per turn; get the order right).

**Gotchas.** `++>` returns a list (index `[0]`). Recount MockLLM output order
after adding the decision call. Every created node must be reachable from `root`
(it is, if you only ever `here ++> new`, since `here` traces back to the opening
under `root`). `jac clean` between shape-changing runs.

---

## Upgrade 2 — Visualize the built graph

**Goal.** Show the graph the agent built — the single most persuasive demo
visual for an OSP track.

**Design.**
- `printgraph(root)` **returns** a Graphviz DOT string (it does not print
  itself). Add an option to `main.jac`'s entry (e.g. after the call:
  `print(printgraph(root));` or write it to `call_graph.dot`).
- Render for the demo: `dot -Tsvg call_graph.dot -o call_graph.svg` (needs
  Graphviz: `brew install graphviz` — the DOT string itself needs nothing).
- Optional polish: a tiny script or a Jac walker that reports DOT for just the
  latest call's subgraph (filter from the opening node), so the image shows one
  clean path, not every persisted call.

**Files.** `main.jac` (emit DOT), optionally a `viz.py` or `viz.jac` helper.

**Acceptance.** After a run you can produce an SVG/PNG of the actual path the
agent walked. Different calls → visibly different graphs.

**Gotchas.** If Upgrade 3's persistence is on, `root` accumulates many calls —
filter to the current call's subgraph for a legible image.

---

## Upgrade 3 — Cross-call learning via root-graph persistence

**Goal.** The agent gets better against a specific hospital over repeated calls:
"it opened with the tactic that worked last time." Makes graph-native
persistence *matter*.

**Design.**
- Model hospitals + outcomes on the graph: `node Hospital { has name: str; }`
  hanging off `root`; each completed call appends a
  `node CallOutcome { has result: str; has winning_move: str; has date: str; }`
  under its `Hospital` (typed edge, e.g. `edge HadCall: Hospital --> CallOutcome`).
- **At call start:** get-or-create the `Hospital` (`visit [root-->[?:Hospital, name==H]] else { ... }` — the get-or-create pattern from `jac-walker-patterns`), read its prior `CallOutcome`s, and summarize them into a `prior_experience: str` passed into `choose_next_tactic` (add the param + `sem`, or pass via `by llm(incl_info=...)`).
- **At call end** (an exit ability / terminal node): append a new `CallOutcome`
  recording the result and which `TacticMove` led to `ACCEPTED`.
- Demo: run the same hospital 3× and show the opening tactic shift toward what
  worked. Convert any relative dates to absolute when storing.

**Files.** `graph.jac` (`Hospital`, `CallOutcome`, edge), `agent.jac`
(start-of-call lookup, end-of-call record, thread `prior_experience` into the
tactic choice), `main.jac`/`telephony` (pass a hospital name in).

**Acceptance.** Across three same-hospital runs **without** `jac clean` between
them, the agent's opening move demonstrably reflects prior outcomes; a fresh
hospital name starts naive.

**Gotchas.** This is the ONE place you must **NOT** `jac clean` between runs —
persistence across `jac run` invocations is the whole point. But that same
persistence caused an earlier duplicate-`Opening` bug: **always spawn the walker
on the specific current-call node you created, never on `root`**, and key the
`Hospital` lookup exactly so you find the existing node instead of making a
second one. Test isolation still applies to `jac test` (each test gets a fresh
root) — keep learning-behavior tests explicit about the graph they set up.

---

## Upgrade 4 — Ground tactics in real assistance programs

**Goal.** The agent cites specific, real programs, so it sounds like a patient
advocate who knows the rules.

**Design.** Give the tactic-choice / line-generation steps real domain facts:
- **IRS 501(r):** nonprofit hospitals must maintain a written **Financial
  Assistance Policy (FAP)**, must **limit charges** for FAP-eligible patients to
  no more than **Amounts Generally Billed (AGB)**, and must not pursue
  extraordinary collections before checking FAP eligibility.
- **Charity care:** often free/discounted care under ~200–400% of the Federal
  Poverty Level (varies by hospital).
- **Other levers:** interest-free payment plans, prompt-pay discounts,
  itemized-bill review for billing errors, financial-hardship applications.
- Represent this knowledge one of two ways (pick one, document it):
  - **OSP-flavored:** `node ProgramKnowledge { has name; has eligibility; has citation; }`
    nodes under `root` the walker can read and pass as context — most on-theme.
  - **Simpler:** a structured `obj`/dict of programs passed into the LLM calls
    via `sem` context or `by llm(incl_info=...)`.
- Have `choose_next_tactic`/`generate_line` reference these so moves like
  `CITE_501R` produce lines such as: *"As a nonprofit hospital under IRS 501(r),
  you're required to have a financial assistance policy — can we check whether I
  qualify before this goes to collections?"*

**Files.** `graph.jac` (if using knowledge nodes), `agent.jac` (wire the
knowledge into the tactic/line `sem` or `incl_info`).

**Acceptance.** Generated lines name specific real programs/rules. (Hard to
assert deterministically through MockLLM — instead unit-test that the knowledge
is *wired in* as context, and eyeball a real `jac run` with a key.)

**Gotchas.** Keep claims accurate — 501(r) applies to **nonprofit** hospitals;
don't overstate entitlements. This is guidance for negotiation, not legal advice.

---

## Suggested order & final checklist

1. **Upgrade 1** (foundational — changes walkers + core).
2. **Upgrade 4** (plugs into the new tactic-choice step; do alongside/after 1).
3. **Upgrade 3** (builds on end-of-call outcome recording).
4. **Upgrade 2** (independent; do last so there's a dynamic graph worth showing).

Ship each upgrade as its own commit on a feature branch (not straight to
`main`), and after each:

```bash
jac check main.jac && jac test agent.jac && python -m telephony.test_flow
```

Update `README.md`'s "Build status" and feature list as you go. Live-run sanity
check with a key: `set -a; source .env; set +a && jac run main.jac`.
