"""The offline demo page: a frozen call replaying itself, turn by turn.

Everything rendered here comes from `ReplayCall` walking the frozen graph on
the server - the nodes, the decisions, and the dialogue are all read off that
traversal, not from a hand-written list.

The page leads with the GRAPH: one row per hop, showing the tactic node and
the decision that moved the walker off it. The dialogue behind each hop is
collapsed until asked for, so the shape of the negotiation is what you see
first and the wall of transcript is opt-in.
"""

sv import from calltrace { ReplayCall, call_meta, TurnView, CallMeta }


glob _NL: str = chr(10);

# How long each hop holds the screen before the next one lands.
glob TURN_MS: int = 1700;


"""What each typed edge means, in a few words."""
def intent_label(intent: str) -> str {
    if intent == "SOFT_NO" {
        return "deflected, no commitment";
    }
    if intent == "STONEWALLING" {
        return "won't move at their level";
    }
    if intent == "NEEDS_ESCALATION" {
        return "can't approve it personally";
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
    return label.replace("_", " ").lower();
}


"""One hop of the walk: the node it was on, the decision that moved it, and -
on request - the exchange that produced that decision."""
def:pub Hop(t: TurnView, index: int, expanded: bool, onToggle: Callable[[int], None]) -> JsxElement {
    def handle(e: MouseEvent) {
        onToggle(index);
    }

    return <li className="hop">
        <div className="hop-row">
            <span className="node">{pretty(t.tactic)}</span>
            <span className="arrow">→</span>
            <span className="decision">{t.intent}</span>
            <span className="gloss">{intent_label(t.intent)}</span>
            <button className="peek" onClick={handle}>
                {"hide" if expanded else "transcript"}
            </button>
        </div>
        {<div className="hop-body">
            <p className="line line-agent"><b>Agent</b>{t.agent}</p>
            <p className="line line-rep"><b>Rep</b>{t.rep}</p>
        </div> if expanded else None}
    </li>;
}


def:pub app -> JsxElement {
    has turns: list[TurnView] = [];
    has meta: CallMeta | None = None;
    has shown: int = 0;
    has open_hop: int = -1;
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

    # Every path returns a cleanup lambda or nothing: an effect returning None
    # makes React try to call null as the destructor on the next run.
    can with (shown, playing, loaded) entry {
        if loaded and playing and shown < len(turns) {
            timer = setTimeout(lambda { shown = shown + 1; }, TURN_MS if shown > 0 else 500);
            return lambda { clearTimeout(timer); };
        }
        if loaded and playing and shown >= len(turns) {
            playing = False;
        }
    }

    def toggle_hop(i: int) {
        open_hop = -1 if open_hop == i else i;
    }

    def replay(e: MouseEvent) {
        open_hop = -1;
        shown = 0;
        playing = True;
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
            <span className="chip">recorded call · no API key</span>
        </header>

        {<p className="loading">Loading the recorded call…</p> if not loaded else
        <section className="demo">
            <div className="callbar">
                <span><b>{meta.patient if meta else ""}</b>{" vs. "}{meta.hospital if meta else ""}</span>
                <span className="muted">{("$4,200 · " + meta.model) if meta else ""}</span>
            </div>

            <p className="legend">
                Each row is one hop of the walker: the tactic it was on, and the
                typed edge the rep's reply became.
            </p>

            <ul className="flow">
                {for i in range(shown) {
                    <Hop t={turns[i]} index={i} expanded={open_hop == i}
                         onToggle={toggle_hop} key={str(i)} />;
                }}
            </ul>

            {<div className="outcome">
                <div className="outcome-head">deal reached</div>
                <p>{meta.deal_terms if meta else ""}</p>
            </div> if done and meta and meta.outcome == "deal_reached" else None}

            <div className="controls">
                {<button className="btn" onClick={replay}>Replay</button> if done
                 else <button className="btn btn-ghost" onClick={show_all}>Skip</button>}
                <span className="progress">
                    {str(shown) + " / " + str(len(turns)) + " hops"}
                </span>
            </div>
        </section>}

        <section className="tail">
            <h2>Why this is Jac</h2>
            <p>
                Tactics are <b>nodes</b>. What the rep said is a <b>typed edge</b>
                {" ("}<code>SoftNo</code>{", "}<code>NeedsEscalation</code>{", "}
                <code>Accepted</code>{"…) — the classification "}<em>is</em>
                {" the edge, not a switch statement. A "}<b>walker</b>
                {" builds the graph as the call happens, so it cannot know its next hop until the rep answers. This page is the same design: the call above is a real graph, walked by a real walker."}
            </p>

            <h2>Run it live</h2>
            <p>
                Needs a free Twilio trial. No Anthropic key on your end — the
                model calls run server-side.
            </p>
            <pre><code>{"git clone https://github.com/bfay1/jaul && cd jaul" + _NL + "./bin/jaul        # bootstraps, writes .env, asks for Twilio creds" + _NL + "./bin/jaul        # run again — your phone rings"}</code></pre>
            <p className="fine">
                No phone? <code>jac test agent.jac</code> needs no key at all;
                <code> jac run main.jac</code> plays out a whole negotiation
                against a simulated rep.
            </p>
        </section>

        <footer className="foot">
            JacHacks SF · Agentic AI ·
            <a href="https://github.com/bfay1/jaul"> github.com/bfay1/jaul</a>
        </footer>
    </main>;
}
