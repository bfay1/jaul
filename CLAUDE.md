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
from outdated or nonexistent versions. The authoritative reference ships
inside the compiler — use it, don't guess:

- `jac guide` — list every guide
- `jac guide jac-core-cheatsheet` — baseline syntax; read this first
- `jac guide jac-walker-patterns` / `jac guide jac-node-edge-patterns` — OSP
- `jac guide jac-by-llm` — `by llm()`, `sem` strings, MockLLM
- `jac guide --search <keyword>` — find a guide by topic

Verified gotchas from porting the whole `telephony/` package + `casefile.py`
from Python to Jac (all confirmed via `jac check` + real runtime tests, not
guessed):

- **`self` is implicit in `obj`/`node`/`edge`/`walker` methods** (never
  declare it) **but must be explicit and typed in a `class` archetype**
  (`def foo(self: MyClass, ...)`) - `class` methods are NOT auto-bound the
  way `obj` methods are; omitting it compiles clean but dies at runtime with
  `NameError: name 'self' is not defined` the moment the body touches `self`.
- **Single-quoted f-strings with 2+ interpolations that are each individually
  adjacent to embedded literal `"` chars silently corrupt** (e.g.
  `f'a="{x}" b="{y}"'` → `'a="X b=Y"'`, losing quote boundaries). One
  interpolation is fine; the bug needs two-or-more, each quote-adjacent. Use
  double-quoted f-strings with `\"` escapes instead when this shape shows up.
- **`@contextlib.contextmanager`-decorated generator functions taking
  parameters false-positive on `jac check`** at every `with fn(args) { }` call
  site (`E1051: Too many positional arguments`) even though they run
  correctly. Sidestep entirely with a plain `obj` implementing
  `__enter__`/`__exit__` instead - checks clean, same runtime behavior.
- **Relative imports (`import from .sibling { x }`) only work for files
  imported as package modules**, not for a file directly targeted by
  `jac run <path>` / `jac test <path>` (that file has "no known parent
  package" at that point) - use the absolute form
  (`import from telephony.sibling { x }`) for anything meant to be run/tested
  directly.
- **`spawn` works as the normal infix operator (`node spawn Walker(...)`)
  inside a plain `obj` method**, not just inside `with entry` blocks or walker
  abilities - confirmed directly. This is what let `telephony/core.jac`
  become fully native Jac instead of a Python bridge through `jaclang.lib`.
- **`by postinit` can run arbitrary side-effecting setup**, not just pure
  field derivation from other fields - confirmed a postinit block calling an
  external function with real side effects. Use it for a real constructor
  body on an `obj` (there is no custom `__init__` on `obj`/`node`/`edge`/
  `walker` - the constructor is always auto-generated from `has` fields).
- Monkeypatching a strictly-typed external attribute (e.g. `requests.post` in
  a test) fails direct assignment (`E1001: Cannot assign Any to <typed
  function>`); `setattr(module, "name", fn)` sidesteps the same type check
  entirely for the identical runtime effect.

Then verify with `jac check main.jac`. If still uncertain, flag it rather
than guessing.

## Toolchain — pinned, do not casually upgrade

This project runs on the **`jaclang` 0.16.7 pip package** in a local venv
(`python3 -m venv jac-env && pip install -r requirements.txt`), NOT the newer
self-contained `jac` binary from the curl installer. Both exist; they are not
interchangeable, and the whole team must be on the same one.

The pin is load-bearing: `uvicorn telephony.server:app` starts a plain Python
process that imports an all-Jac package (`telephony/*.jac`) via jaclang's
`.pth`-installed import hook - which only exists if `jaclang` is pip-installed
in *that* Python environment. The standalone binary embeds its own Python and
has no such package, so uvicorn simply couldn't import `telephony.server` at
all under it.

Two things also differ under the binary and will silently mislead you:
`byllm` imports as `jaclang.byllm.lib` rather than `byllm.lib`, and `global`
is not a statement (0.16.7 accepts `global llm;`; the binary rejects it).

If a version bump is ever wanted, it is a team decision and requires porting
the telephony transport — not a one-line edit.

## Submission requirements (JacHacks SF)

- Working demo (deployed or local)
- 3-minute max demo video
- Public GitHub repo
- Devpost written description: what it does, how it works, track, Jac/Jaseci
  features used
- Optional: a slide or two on the problem being solved
