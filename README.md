# jaul

An autonomous agent that **calls hospital billing departments and negotiates
your medical bill** — surfacing the income-based discounts, charity care, and
interest-free payment plans that hospitals offer but patients rarely know to
ask for.

Built for **JacHacks SF** (Agentic AI track) in [Jac](https://www.jaseci.org/)
using Object-Spatial Programming: the negotiation isn't a script of `if/else`
branches — it's a **live traversal of a typed graph**, where the agent doesn't
know which path it will take until the rep responds.

---

## How it works

A negotiation is modeled as a graph — and the graph is **built live, one node
and edge per turn**, not pre-wired before the call starts. Two calls against
the same hospital produce differently-shaped graphs, because the shape *is*
the trace of what the rep actually said each turn:

- **`Opening` is the only node that exists when a call starts.** Everything
  after it — every `TacticStep` and the typed edge connecting it to the
  previous node — is created live, mid-walk, by the walker itself.
- **Edges are what the rep just said** — `SoftNo`, `Stonewalling`,
  `NeedsEscalation`, `Accepted`, `HardNo`. The edge type *is* the
  classification; there is no `switch` statement. `Accepted`/`HardNo` are the
  sole authority on whether a call ends, landing on `DealReached`/`DeadEnd`.
- **A walker is the negotiation engine.** Each turn it generates its line,
  reads the rep's reply, classifies it, and — for a continuing reply — decides
  the next tactic to try (`choose_next_tactic`) and *builds* the node and edge
  for that move on the spot before traversing it. It cannot know its path in
  advance because the graph doesn't have one until it's walked.
- **`by llm()` powers three points**: classifying the rep's reply, choosing the
  next tactic, and generating the agent's line. A fourth `by llm()` plays a
  mock billing rep so full negotiations can run with no phone call.
- **Tactic choice and dialogue are grounded in real assistance-program facts**
  — IRS 501(r), Amounts Generally Billed, charity-care thresholds, interest-free
  payment plans — stored as root-anchored `ProgramKnowledge` nodes, flattened
  to plain text before ever reaching an LLM call.
- **The graph persists across runs on Jac's root graph**, grouped by hospital:
  every call's `Opening` hangs off a `Hospital` node (not bare root), and each
  completed call appends a `CallOutcome` under it. A later call against the
  same hospital reads that history and can lean toward whatever worked before.
- **`printgraph()` renders the actual path a call took** to a Graphviz DOT
  file after every `jac run main.jac` — the single most direct way to *see*
  that the graph really was built live, not just traversed.

```
Opening ──SoftNo──▶ TacticStep(OFFER_INCOME_DISCOUNT) ──Accepted──▶ DealReached
   │
   │NeedsEscalation
   ▼
TacticStep(ESCALATE) ──HardNo──▶ DeadEnd
```
This is one possible shape, not *the* shape — the next call, or a call against
a different hospital, walks a different path and builds a different graph.

## Project layout

| File | Role |
|---|---|
| `graph.jac` | Graph shape only, no LLM logic: `Tactic`/`Opening`/`TacticStep`/`DealReached`/`DeadEnd` nodes, typed edges, `start_call()`; `Hospital`/`CallOutcome` (cross-call learning) and `ProgramKnowledge` (real assistance-program facts) |
| `agent.jac` | The intelligence: `RepIntent` + `TacticMove` enums, the `by llm()` functions (`classify_response`, `choose_next_tactic`, `PatientCase.generate_line`, `rep_reply`), the graph-building helpers (`advance_tactic`, `reach_terminal`), and the walkers (`NegotiationAgent` for full-loop runs, `NegotiationTurn` for one-hop-per-webhook telephony) + MockLLM tests |
| `main.jac` | Thin entry point wiring it together; also emits `call_graph.dot` after each run |
| `casefile.jac` | Loads a markdown patient case file into agent context (`--case`); also reads `--hospital` |
| `cases/` | Example patient case files (markdown) |
| `telephony/` | The transport that carries a live phone call to the Jac core (see below) |

**Essentially the entire project is Jac** — including telephony. The one
exception is `telephony/__init__.py`, which stays `.py` only because Python's
package system specifically requires that exact filename to mark a directory
importable; it holds no logic, just a docstring. Third-party frameworks
(FastAPI's `@app.post(...)` decorators, ElevenLabs/Twilio's REST clients) work
directly on Jac functions via normal Python interop — no bridging layer needed:

| File | Role |
|---|---|
| `telephony/core.jac` | `NegotiationSession` — drives the `NegotiationTurn` walker one turn at a time, natively (`spawn`/`root`/`++>` work directly here, not through a Python bridge) |
| `telephony/transport.jac` | `Transport` interface — `TurnBasedTransport` (Twilio Say+Gather) today, `StreamingTransport` (Media Streams) documented as a swap-in |
| `telephony/server.jac` | FastAPI webhook app Twilio drives (`/twiml/start`, `/twiml/turn`) — plain `@app.post(...)` decorators on async Jac functions |
| `telephony/voice.jac` | ElevenLabs TTS — opt-in, never on the critical path |
| `telephony/dial.jac` | Places the outbound call (real Twilio; behind env config) |
| `telephony/test_flow.jac` | Offline tests of the whole call flow — no Twilio/network/key |
| `telephony/test_voice.jac` | Offline tests of the ElevenLabs TTS path |

Jac's *native* server layer (`walker:pub`) was deliberately **not** used for
the webhook server: it always wraps responses in Jac's own JSON envelope and
has no raw-XML response mode, which Twilio's TwiML contract requires (verified
against the framework docs before choosing plain FastAPI-in-Jac instead).

`render.yaml` and `.python-version` configure a persistent deploy of the
webhook server on Render (see "Deploying" below) — a stable alternative to
restarting ngrok every session.

---

## Setup

Requires Python 3.14.

```bash
git clone git@github.com:bfay1/jaul.git
cd jaul
python3 -m venv jac-env && source jac-env/bin/activate
pip install -r requirements.txt
cp .env.example .env          # fill in keys (see "Credentials" below)
```

Verify the install with the checks and offline tests — **these need no API key
or network**:

```bash
jac check main.jac                        # type-check the whole project
jac test agent.jac                        # negotiation tests (MockLLM)
jac test telephony/test_flow.jac          # telephony flow tests (MockLLM)
jac test telephony/test_voice.jac         # ElevenLabs TTS tests (mocked)
```

## Running it

There are three ways to run, in increasing order of what they need:

### 1. Full negotiation loop, no phone (needs `ANTHROPIC_API_KEY`)

The agent negotiates against the LLM-powered mock rep — a real end-to-end call
without telephony. Good for iterating on prompts.

```bash
set -a; source .env; set +a
jac run main.jac
```

### 2. Live phone call (needs `ANTHROPIC_API_KEY` + Twilio + a public URL)

The webhook server needs to be reachable from the public internet — either a
temporary local tunnel (fast iteration, URL changes every restart) or a real
deploy (stable URL, no restart-and-repaste). Pick one:

**a) Local + ngrok (quick iteration):**
```bash
set -a; source .env; set +a
uvicorn telephony.server:app --port 8080     # 1) webhook server (imports the .jac module directly)
ngrok http 8080                              # 2) copy the https URL into PUBLIC_BASE_URL in .env
jac run telephony/dial.jac                   # 3) places the call
```

**b) Deployed on Render (stable URL — see "Deploying" below):**
```bash
set -a; source .env; set +a          # PUBLIC_BASE_URL = your Render URL (one-time)
jac run telephony/dial.jac
```

Answer the phone, play the billing rep, and the agent negotiates live — walking
the graph one turn per exchange.

> **Demo safely:** point `TWILIO_TO_NUMBER` at **your own phone** and role-play
> the rep. Don't autodial a real hospital billing line — recording-consent and
> robocall rules vary by jurisdiction.

## Deploying (Render)

Solves the "ngrok URL changes every time I restart it" problem: Render runs
`telephony/server.jac` as a persistent process with a stable `https://` URL, so
`PUBLIC_BASE_URL` only needs to be set once, ever.

1. Push this repo to GitHub (already done for `bfay1/jaul`).
2. In the [Render dashboard](https://dashboard.render.com): **New → Blueprint**,
   point it at the repo. Render reads `render.yaml` and creates the
   `jaul-telephony` web service automatically.
3. Render prompts for the secret env vars marked `sync: false` in
   `render.yaml`: `ANTHROPIC_API_KEY`, `TWILIO_ACCOUNT_SID`,
   `TWILIO_AUTH_TOKEN`, `TWILIO_FROM_NUMBER`, `TWILIO_TO_NUMBER`. Fill these in
   the dashboard — they're never committed to the repo.
4. Deploy. Render assigns a URL like `https://jaul-telephony.onrender.com` —
   the server finds this itself via Render's auto-injected
   `RENDER_EXTERNAL_URL`, so **no `PUBLIC_BASE_URL` is needed on Render**.
5. **One local step:** copy that URL into `PUBLIC_BASE_URL` in your *local*
   `.env` — `telephony/dial.jac` runs on your machine and needs to know where
   to send the outbound call.

```bash
# .env, after step 4:
PUBLIC_BASE_URL=https://jaul-telephony.onrender.com
```

```bash
set -a; source .env; set +a
jac run telephony/dial.jac
```

**Free-tier note:** Render's free plan sleeps the service after ~15 min idle;
the first request after sleep takes a few extra seconds to spin up. Fine for a
demo — just place the call right after opening the dashboard, or leave the
`/health` endpoint open in a tab beforehand to keep it warm.

## Patient context (case files)

The agent negotiates on behalf of a specific patient, described in a **single
markdown case file** — bill, income, insurance, hardship, goals. The whole
document is passed to the agent as context, so it argues from real specifics
(e.g. *"income near 150% of the federal poverty level"*, *"nonprofit hospital,
so IRS 501(r) applies"*) instead of generically.

```bash
jac run main.jac                                   # uses cases/jordan-rivera.md
jac run main.jac -- --case cases/your-patient.md   # any case file you write
```

To add a patient, drop a markdown file in `cases/` — no code changes. The first
`# H1` heading becomes the display name; everything else is free-form prose the
agent reads (see `cases/jordan-rivera.md` for the shape — structure is a
suggestion, not a requirement). The offline tests and the live phone call fall
back to a built-in demo case when none is supplied.

## Cross-call learning + visualizing the graph

Every call belongs to a hospital (`--hospital`, defaults to "Bay Area
General" — the hospital in the bundled demo case). Run against the same name
repeatedly and the agent's opening tactic can shift toward whatever worked
last time, since it reads that hospital's prior `CallOutcome`s before choosing:

```bash
jac run main.jac -- --hospital "Bay Area General"   # run this 2-3 times in a row
```

After each run, `printgraph(opening)` writes the exact path that call took to
`call_graph.dot` — render it with Graphviz (`brew install graphviz` if you
don't have it):

```bash
dot -Tsvg call_graph.dot -o call_graph.svg
```

Two different runs produce two different SVGs — that's the point.

---

## Credentials

Everything lives in `.env` (gitignored). `.env.example` lists the names.

**Anthropic** (the negotiation brain — required for any *real* run; tests use a
mock instead):
- `ANTHROPIC_API_KEY` — from the [Anthropic Console](https://console.anthropic.com).

**Twilio** (only for a *live phone call* — the server and all tests need none):

Twilio has no single "API key" for this. You need three things from the free
[Twilio Console](https://console.twilio.com):
- `TWILIO_ACCOUNT_SID` and `TWILIO_AUTH_TOKEN` — on the dashboard.
- `TWILIO_FROM_NUMBER` — a Twilio phone number to call *from*.
- `TWILIO_TO_NUMBER` — the number to call (your own phone for the demo).
- `PUBLIC_BASE_URL` — the https URL where `telephony/server.jac` is reachable
  (e.g. your ngrok URL).

A **free trial account works for the demo.** It comes with credit and a number;
its only catch is that it can call *verified* numbers only — which is exactly
the self-call demo (verify your own phone in the console). No paid upgrade
needed.

---

## Jac / Jaseci features used

- **The graph is built live, not pre-wired** — a call starts with just an
  `Opening` node; the walker creates every subsequent `TacticStep` and its
  typed edge mid-traversal, so the graph's *shape* is a genuine live decision,
  not just the path taken through a fixed map.
- **Walkers as the negotiation engine** — the graph traversal *is* the logic,
  not an orchestration wrapper around Python control flow.
- **Typed edges encode state** — the rep's response class is the edge type, not
  a dict key or `switch`.
- **`by llm()` at three points** — response classification, next-tactic choice,
  and line generation (as a method on `PatientCase`, so the LLM call's object
  context is automatic) — plus a fourth that role-plays the rep.
- **Graph-native persistence, used for something** — not just "state lives on
  the root graph" but genuine cross-call learning: `Hospital`/`CallOutcome`
  nodes accumulate across separate `jac run` invocations, and a later call
  reads that history before choosing its opening tactic.
- **`printgraph()` renders the graph the walker actually built** — the most
  direct way to show a judge the traversal *is* the graph, not dressing on top
  of a fixed one.
- **Single-turn walker for event-driven telephony** — `NegotiationTurn`
  advances the graph exactly one hop per webhook, so the same OSP engine drives
  both the blocking mock demo and a live, webhook-paced phone call — dynamic
  node creation included; no telephony code needed to change for it.
- **The telephony layer is Jac too, not a Python shim around it** — the FastAPI
  webhook server, the ElevenLabs TTS call, the Twilio dialer, and the session
  bridge (`NegotiationSession`) are all `.jac`. `spawn`/`root`/`++>` work as
  native operators inside a plain `obj` method, so there's no
  `jaclang.lib`-bridge boundary between the phone transport and the graph
  anymore — one compiler, one language, start to finish. The only `.py` file
  left in the project is `telephony/__init__.py`, which is empty of logic and
  stays `.py` purely because Python's package system requires that exact
  filename.

## Build status

- [x] Node/edge/walker skeleton (traversal verified)
- [x] Real `by llm()` for classification + generation
- [x] Mock vendor-rep agent (phone-free full loops)
- [x] Twilio telephony — turn-based (Say + Gather), with a documented seam for
      real-time Media Streams
- [x] Dynamic graph construction — the walker builds each tactic node/edge
      live instead of traversing a pre-wired graph
- [x] Tactic choice and dialogue grounded in real assistance-program facts
      (IRS 501(r), AGB, charity care, payment plans)
- [x] Cross-call learning — `Hospital`/`CallOutcome` persistence across runs
- [x] Graph visualization — `printgraph()` renders each call's actual path
