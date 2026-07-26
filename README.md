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

A negotiation is modeled as a graph and walked in real time:

- **Nodes are tactics** — `Opening`, `CounterOffer`, `Escalation`,
  `DealReached`, `DeadEnd`.
- **Edges are what the rep just said** — `SoftNo`, `Stonewalling`,
  `NeedsEscalation`, `Accepted`, `HardNo`. The edge type *is* the
  classification; there is no `switch` statement.
- **A walker is the negotiation engine.** Each turn it generates its next line,
  reads the rep's reply, classifies it into an edge, and traverses that one
  edge — landing on the next tactic. It cannot know its path in advance.
- **`by llm()` powers two points**: classifying the rep's reply into an edge,
  and generating the agent's next line. A third `by llm()` plays a mock billing
  rep so full negotiations can run with no phone call.
- **The graph persists** across runs on Jac's root graph — no separate database.

```
Opening ──SoftNo──▶ CounterOffer ──Accepted──▶ DealReached
   │                     │
   │NeedsEscalation      └──Stonewalling──▶ Escalation ──Accepted──▶ DealReached
   ▼                                            │
Escalation ◀────────────────────────────────────┘
   │HardNo
   ▼
DeadEnd
```

## Project layout

| File | Role |
|---|---|
| `graph.jac` | The tactic graph — nodes, typed edges, `build_call_graph()` |
| `agent.jac` | The intelligence: `RepIntent` enum, the `by llm()` functions, and the walkers (`NegotiationAgent` for full-loop runs, `NegotiationTurn` for one-hop-per-webhook telephony) + MockLLM tests |
| `main.jac` | Thin entry point wiring the two together |
| `casefile.py` | Loads a markdown patient case file into agent context (`--case`) |
| `cases/` | Example patient case files (markdown) |
| `telephony/` | Python transport that carries a live phone call to the Jac core (see below) |

The `telephony/` package is deliberately thin — **all negotiation logic stays
in Jac.** Python only handles the phone:

| File | Role |
|---|---|
| `telephony/core.py` | `NegotiationSession` — drives the Jac `NegotiationTurn` walker one turn at a time (Jac library mode) |
| `telephony/transport.py` | `Transport` interface — `TurnBasedTransport` (Twilio Say+Gather) today, `StreamingTransport` (Media Streams) documented as a swap-in |
| `telephony/server.py` | FastAPI webhook app Twilio drives (`/twiml/start`, `/twiml/turn`) |
| `telephony/dial.py` | Places the outbound call (real Twilio; behind env config) |
| `telephony/test_flow.py` | Offline tests of the whole call flow — no Twilio/network/key |

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
jac check main.jac                # type-check the whole project
jac test agent.jac                # negotiation tests (MockLLM)
python -m telephony.test_flow     # telephony flow tests (MockLLM)
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

```bash
set -a; source .env; set +a
uvicorn telephony.server:app --port 8080     # 1) webhook server
ngrok http 8080                              # 2) copy the https URL into PUBLIC_BASE_URL in .env
python -m telephony.dial                     # 3) places the call
```

Answer the phone, play the billing rep, and the agent negotiates live — walking
the graph one turn per exchange.

> **Demo safely:** point `TWILIO_TO_NUMBER` at **your own phone** and role-play
> the rep. Don't autodial a real hospital billing line — recording-consent and
> robocall rules vary by jurisdiction.

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
- `PUBLIC_BASE_URL` — the https URL where `telephony/server.py` is reachable
  (e.g. your ngrok URL).

A **free trial account works for the demo.** It comes with credit and a number;
its only catch is that it can call *verified* numbers only — which is exactly
the self-call demo (verify your own phone in the console). No paid upgrade
needed.

---

## Jac / Jaseci features used

- **Walkers as the negotiation engine** — the graph traversal *is* the logic,
  not an orchestration wrapper around Python control flow.
- **Typed edges encode state** — the rep's response class is the edge type, not
  a dict key or `switch`.
- **`by llm()` at two points** — response classification (into a typed enum) and
  next-line generation — plus a third that role-plays the rep.
- **Graph-native persistence** — call state lives on the root graph.
- **Single-turn walker for event-driven telephony** — `NegotiationTurn`
  advances the graph exactly one hop per webhook, so the same OSP engine drives
  both the blocking mock demo and a live, webhook-paced phone call.

## Build status

- [x] Node/edge/walker skeleton (traversal verified)
- [x] Real `by llm()` for classification + generation
- [x] Mock vendor-rep agent (phone-free full loops)
- [x] Twilio telephony — turn-based (Say + Gather), with a documented seam for
      real-time Media Streams
