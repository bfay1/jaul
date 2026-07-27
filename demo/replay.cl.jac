"""The offline demo page: a frozen call replaying itself, turn by turn.

Everything rendered here comes from `ReplayCall` walking the frozen graph on
the server - the transcript, the tactic chain, and the typed edge labels are
all read off that traversal, not from a hand-written list.

The page has two halves, in the order the demo needs them:
  1. the replay itself, which needs no key, no phone line, and no network
     beyond this page;
  2. instructions for running the same agent live, against a real phone call.
"""

sv import from .trace { ReplayCall, call_meta, TurnView, CallMeta }


glob _NL: str = chr(10);

# How long each turn holds the screen before the next one arrives. Slow enough
# to read the rep's reply, fast enough that a 5-turn call fits in a demo.
glob TURN_MS: int = 4200;


"""Human-readable gloss for each typed edge, shown as the transition fires."""
def intent_label(intent: str) -> str {
    if intent == "SOFT_NO" {
        return "deflected - vague, no commitment";
    }
    if intent == "STONEWALLING" {
        return "won't move at their level";
    }
    if intent == "NEEDS_ESCALATION" {
        return "can't personally approve this";
    }
    if intent == "ACCEPTED" {
        return "committed to concrete terms";
    }
    if intent == "HARD_NO" {
        return "firm, final refusal";
    }
    return intent;
}


"""Tactic labels come off the graph as enum-ish names; make them readable."""
def pretty(label: str) -> str {
    words = label.replace("_", " ").lower();
    return words;
}


def:pub Chip(text: str, tone: str) -> JsxElement {
    return <span className={"chip chip-" + tone}>{text}</span>;
}


"""One exchange: what the agent said, what the rep said back, and the typed
edge the classifier turned that reply into."""
def:pub Exchange(t: TurnView, active: bool) -> JsxElement {
    return <div className={"exchange" + (" exchange-active" if active else "")}>
        <div className="ex-head">
            <Chip text={"turn " + str(t.turn)} tone="turn" />
            <Chip text={pretty(t.tactic)} tone="tactic" />
        </div>
        <p className="line line-agent"><b>Agent</b>{t.agent}</p>
        <p className="line line-rep"><b>Billing rep</b>{t.rep}</p>
        <div className="edge-note">
            <span className="edge-name">{t.intent}</span>
            <span className="edge-gloss">{intent_label(t.intent)}</span>
            <span className="edge-arrow">{"→ " + pretty(t.next_tactic)}</span>
        </div>
    </div>;
}


"""The tactic chain the walker built, revealed one node at a time."""
def:pub GraphTrace(turns: list[TurnView], shown: int) -> JsxElement {
    return <div className="graph">
        <div className="graph-title">the graph, as the walker built it</div>
        <div className="chain">
            {for i in range(len(turns)) {
                <div className={"chain-item" + (" on" if i < shown else "")} key={str(i)}>
                    <div className="gnode">{pretty(turns[i].tactic)}</div>
                    <div className="gedge">
                        <span className="gedge-label">{turns[i].intent}</span>
                    </div>
                </div>;
            }}
            <div className={"chain-item" + (" on" if shown >= len(turns) else "")}>
                <div className="gnode gnode-final">
                    {pretty(turns[len(turns) - 1].next_tactic) if len(turns) > 0 else ""}
                </div>
            </div>
        </div>
    </div>;
}


def:pub RunLive() -> JsxElement {
    return <section className="runlive">
        <h2>Run it live</h2>
        <p className="sub">
            The replay above needs nothing. Placing a real call needs a
            Twilio number and an Anthropic key, both supplied through
            environment variables - never committed.
        </p>

        <ol className="steps">
            <li>
                <b>Get the code</b>
                <pre><code>{"git clone https://github.com/bfay1/jaul" + _NL + "cd jaul"}</code></pre>
            </li>
            <li>
                <b>Install the pinned toolchain</b>
                <span className="note">
                    The repo runs on the jaclang 0.16.7 pip package, not the
                    standalone binary - they are not interchangeable.
                </span>
                <pre><code>{"python3 -m venv jac-env" + _NL + "source jac-env/bin/activate" + _NL + "pip install -r requirements.txt"}</code></pre>
            </li>
            <li>
                <b>Add credentials</b>
                <span className="note">
                    Copy <code>.env.example</code> to <code>.env</code> and fill
                    it in. <code>.env</code> is gitignored.
                </span>
                <pre><code>{"ANTHROPIC_API_KEY=..." + _NL + "TWILIO_ACCOUNT_SID=..." + _NL + "TWILIO_AUTH_TOKEN=..." + _NL + "TWILIO_FROM_NUMBER=+1..." + _NL + "TWILIO_TO_NUMBER=+1..."}</code></pre>
            </li>
            <li>
                <b>Try it with no phone and no key first</b>
                <span className="note">
                    A full negotiation against a simulated rep, on MockLLM.
                </span>
                <pre><code>{"jac test agent.jac" + _NL + "jac run telephony/demo_mock_server.jac   # then open /live"}</code></pre>
            </li>
            <li>
                <b>Place the real call</b>
                <span className="note">
                    Point <code>TWILIO_TO_NUMBER</code> at your own phone and
                    play the billing rep yourself - the safe way to demo it.
                </span>
                <pre><code>{"./bin/jaul"}</code></pre>
            </li>
        </ol>
    </section>;
}


# Inline text below uses explicit {"..."} string children rather than bare
# prose wherever a <code>/<em> tag sits at a line break: JSX trims the newline
# between two inline elements, which silently glues the words either side of
# it together.
def:pub OspNotes() -> JsxElement {
    return <section className="osp">
        <h2>What is actually Jac here</h2>
        <ul className="notes">
            <li>
                <b>Tactics are nodes; what the rep said is a typed edge.</b>
                <span>
                    <code>SoftNo</code>{", "}<code>Stonewalling</code>{", "}
                    <code>NeedsEscalation</code>{", "}<code>Accepted</code>{", "}
                    <code>HardNo</code>{" are edge archetypes. The classification "}
                    <em>is</em>{" the edge - there is no switch statement anywhere in the negotiation."}
                </span>
            </li>
            <li>
                <b>A walker is the engine, not a wrapper.</b>
                <span>
                    On a live call the walker cannot know its next hop until the
                    rep answers, so the graph is <em>built during the call</em>,
                    one node and one edge per turn. The chain above is the trace
                    of one such call, not a route drawn in advance.
                </span>
            </li>
            <li>
                <b>This page is the same design.</b>
                <span>
                    The frozen call is rebuilt as a real graph on the server and
                    a real walker (<code>ReplayCall</code>) traverses it to
                    produce what you just watched.
                </span>
            </li>
            <li>
                <b><code>by llm()</code> at four points.</b>
                <span>
                    Generating the agent's line, classifying the reply, choosing
                    the next tactic, and - so full calls can be tested with no
                    phone - playing the billing rep.
                </span>
            </li>
            <li>
                <b>Warmth is not agreement.</b>
                <span>
                    A rep who says "I'll put a note on the account" reads as a
                    yes to a classifier and commits to nothing. A commitment gate
                    downgrades any accept that carries no concrete terms, so the
                    agent keeps negotiating instead of reporting a deal that
                    never happened.
                </span>
            </li>
        </ul>
    </section>;
}


def:pub app -> JsxElement {
    has turns: list[TurnView] = [];
    has meta: CallMeta | None = None;
    has shown: int = 0;
    has playing: bool = True;
    has loaded: bool = False;

    async can with entry {
        result = root spawn ReplayCall();
        if result.reports and len(result.reports) > 0 {
            turns = result.reports;
        }
        meta = await call_meta();
        loaded = True;
    }

    # Advance the replay. Re-runs whenever `shown` or `playing` changes, which
    # is what drives the animation forward one turn at a time.
    #
    # Every path either returns a cleanup lambda or returns nothing at all:
    # an effect that returns None (rather than undefined) makes React try to
    # call null as the destructor on the next run.
    can with (shown, playing, loaded) entry {
        if loaded and playing and shown < len(turns) {
            timer = setTimeout(lambda { shown = shown + 1; }, TURN_MS if shown > 0 else 900);
            return lambda { clearTimeout(timer); };
        }
        if loaded and playing and shown >= len(turns) {
            playing = False;
        }
    }

    def toggle(e: MouseEvent) {
        if shown >= len(turns) {
            shown = 0;
            playing = True;
        } else {
            playing = not playing;
        }
    }

    def show_all(e: MouseEvent) {
        playing = False;
        shown = len(turns);
    }

    done = shown >= len(turns) and loaded;

    return <main className="page">
        <header className="masthead">
            <div>
                <h1>jaul</h1>
                <p className="tagline">
                    An agent that calls hospital billing departments and
                    negotiates the bill down.
                </p>
            </div>
            <Chip text="recorded call - no API key needed" tone="offline" />
        </header>

        {<p className="loading">Loading the recorded call…</p> if not loaded else
        <section className="demo">
            <div className="callbar">
                <span><b>{meta.patient if meta else ""}</b> vs. {meta.hospital if meta else ""}</span>
                <span className="muted">
                    {("recorded " + meta.captured_at + " · " + meta.model) if meta else ""}
                </span>
            </div>

            <GraphTrace turns={turns} shown={shown} />

            <div className="transcript">
                {for i in range(shown) {
                    <Exchange t={turns[i]} active={i == shown - 1} key={str(i)} />;
                }}
                {<div className="outcome">
                    <div className="outcome-head">deal reached</div>
                    <p>{meta.deal_terms if meta else ""}</p>
                </div> if done and meta and meta.outcome == "deal_reached" else None}
            </div>

            <div className="controls">
                <button className="btn" onClick={toggle}>
                    {"Replay" if done else ("Pause" if playing else "Play")}
                </button>
                <button className="btn btn-ghost" onClick={show_all}>Show whole call</button>
                <span className="progress">
                    {str(shown) + " / " + str(len(turns)) + " turns"}
                </span>
            </div>
        </section>}

        <OspNotes />
        <RunLive />

        <footer className="foot">
            Built for JacHacks SF · Agentic AI track ·
            <a href="https://github.com/bfay1/jaul"> github.com/bfay1/jaul</a>
        </footer>
    </main>;
}
