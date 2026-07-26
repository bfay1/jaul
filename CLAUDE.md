# CLAUDE.md

## Project

Working name: "jaul" — a hackathon prototype
for JacHacks SF (July 26, 2026), submitting to the Agentic AI track (flagship).

## The Problem

Hospitals routinely have internal financial-assistance policies — income-based
discounts, charity care, interest-free payment plans — that go unused because
patients don't know to ask. This project builds an autonomous negotiation
agent that calls hospital billing departments and surfaces those programs.

## Architecture

Built using Jac's Object-Spatial Programming (nodes, edges, walkers) —
NOT a Python-with-if/else port. Core design:

- Each negotiation tactic is a typed NODE: Opening, CounterOffer,
  Escalation, DealReached, DeadEnd.
- Transitions between tactics are typed EDGES (e.g. Stonewalling,
  SoftNo, NeedsEscalation), representing what the rep just said.
- A WALKER traverses this graph live during the call — it does not know
  which edge it will take until the rep responds. This is intentional:
  the graph is built/traversed in real time, not pre-scripted.
- `by llm()` powers two things: (1) classifying the rep's response into
  the right edge/tactic, (2) generating the agent's next line of dialogue
  at each node.
- Graph-native persistence (root graph) stores call history/outcomes
  across runs — no separate database.

## Jac/Jaseci features to lean into (this is what's being judged)

- Walkers as the actual negotiation engine, not just an orchestration wrapper
- Typed edges encoding state, not a Python dict/switch statement
- `by llm()` at both classification and generation points
- Avoid superficial use — the whole point is the graph traversal IS the logic

## Build order (mock before real)

1. Node/edge/walker skeleton with STUBBED llm calls — verify traversal works
2. Swap stubs for real `by llm()` calls
3. Add a mock vendor-rep agent (a second `by llm()` playing the billing rep)
   to test full negotiation loops without a real phone call
4. Only last: real telephony integration (e.g. Twilio)

## Environment & Secrets

- API keys (e.g. ANTHROPIC_API_KEY) live in `.env`, which is gitignored.
  NEVER hardcode a key in any .jac, .py, .toml, or config file.
- If a model config needs a key, reference it as an environment variable —
  do not paste the literal value into jac.toml or source files.
- `.env.example` should list variable names only, no real values, and
  should be the only .env-related file committed to git.
- Before writing any file that touches auth/config, check .gitignore
  includes `.env` — if it's missing, add it before proceeding.

## Jac syntax notes

Jac is new enough that AI assistants (including you) may hallucinate syntax
from outdated or nonexistent versions. Reference:
https://docs.jaseci.org/learn/tools/llmdocs/ (llmdocs-jaseci-mini_v3.txt)
If uncertain about syntax, flag it rather than guessing.

## Submission requirements (JacHacks SF)

- Working demo (deployed or local)
- 3-minute max demo video
- Public GitHub repo
- Devpost written description: what it does, how it works, track, Jac/Jaseci
  features used
- Optional: a slide or two on the problem being solved
