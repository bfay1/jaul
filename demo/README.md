# jaul — offline demo

A self-contained page that replays **one real negotiation call** and, below it,
explains how to run the agent live. No Anthropic key, no Twilio account, no
phone line, no network calls.

Built to deploy on [JacHammer](https://jachammer.ai).

---

## ⚠️ This directory is on a different Jac than the rest of the repo

| | Jac | Where |
|---|---|---|
| The project (`agent.jac`, `graph.jac`, `telephony/`, …) | **jaclang 0.16.7** pip package | `jac-env/` venv |
| **This directory** | **Jac 0.34.7** (standalone binary) | JacHammer |

They are not interchangeable, and the 0.16.7 pin on the main project is
load-bearing — see the root `CLAUDE.md`. **Do not run this directory with
`jac-env` activated**, and do not import anything from the repo root here.

That isolation is deliberate and cheap to maintain, because the demo needs no
agent code at runtime: it replays a *recorded* call. Nothing in `demo/` imports
`agent.jac` or `graph.jac`, so the two toolchains never meet.

To work on this directory:

```bash
# NOT `source jac-env/bin/activate`
cd demo
jac check main.jac          # the 0.34.7 binary, e.g. ~/.local/bin/jac
jac start main.jac --port 8123
open http://localhost:8123
```

---

## What's here

| File | What it is |
|---|---|
| `calltrace.jac` | The frozen call as a **real graph** — a `Tactic` node per phase, a typed edge per classified reply — plus the `ReplayCall` walker that traverses it. |
| `replay.cl.jac` | The page: animated replay, the tactic chain drawing itself, the OSP notes, and the run-live instructions. |
| `main.jac` | Entry point; wires the server half to the client half. |
| `app.css` | Styling. |
| `trace.json` | The captured call, as recorded. Source of truth for `calltrace.jac`. |

The module is called `calltrace`, not `trace`, on purpose: `trace` is a Python
standard-library module name, and shadowing it made the import resolve
unpredictably once deployed. It is a plain `.jac` (server is the default
context) rather than a `.sv.jac` variant module for the same reason — one less
resolution step to go wrong in someone else's sandbox.

### The demo is not a JSON viewer

That is the point worth defending if someone asks. The transcript is **rebuilt
as an Object-Spatial graph on the server and walked by a real walker** — the
same design `agent.jac` uses on a live call. What the page renders is whatever
`ReplayCall` reports as it traverses. The typed edges (`SoftNo`,
`Stonewalling`, `NeedsEscalation`, `Accepted`, `HardNo`) are real edge
archetypes, and the walk follows them.

---

## Where the transcript came from

It is **not** hand-written. It was captured from one genuine run against the
`by llm()` mock billing rep, on `claude-sonnet-4-6`, on 2026-07-26:

```bash
source jac-env/bin/activate     # the 0.16.7 project, NOT this directory
jac run capture_trace.jac        # needs ANTHROPIC_API_KEY; writes demo/trace.json
```

That call reached a real deal: an 85% charity-care discount taking a $4,200
balance to $630, interest-free over 12 months, plus an immediate collections
hold.

**Re-running `capture_trace.jac` overwrites `demo/trace.json` with a different
call**, and `trace.sv.jac` will then be out of date — it holds the dialogue
inline so the demo has no file-IO dependency at runtime. Only re-capture when
you actually want a different demo call, and regenerate `trace.sv.jac`'s seed
block from the new JSON if you do.

---

## Deploying to JacHammer

JacHammer's Free plan allows **1 sandbox deploy** (expires after 7 days) and
**no permanent deploys**; GitHub import, folder upload, and JacPack import are
Builder/Pro features. So on Free, create the project and paste the files in:

1. Sign in at [jachammer.ai](https://jachammer.ai) and create a new project
   from the **blank template**.
2. Create these four files **at the project root — no folders**, and paste in
   the contents from this directory:
   `main.jac`, `calltrace.jac`, `replay.cl.jac`, `app.css`.
   (Its own `jac.toml` comes from the template — the one here is only for
   running locally. If the template's `[serve]` section lacks
   `base_route_app = "app"`, add it, or the app serves at `/cl/app` instead
   of `/`.)
3. Check the preview renders, then open the **Deploy** tab and choose
   **Sandbox**. Pick a subdomain if you want a memorable URL.

### If the preview fails with `cannot import name 'ReplayCall'`

That means `calltrace.jac` loaded but came up short — almost always a
**truncated paste**, since the file carries the whole transcript inline as
long string literals. `ReplayCall` is defined near the bottom, so it is the
first thing to go missing.

Check the pasted file is **192 lines** and ends with:

```jac
def:pub call_meta -> CallMeta {
    return CALL_META;
}
```

If it doesn't, re-paste it in two halves rather than one.

No environment variables are needed — that is the whole point of this demo.

On Builder/Pro you can skip the pasting and import the repo directly, pointing
the project at `demo/`.
