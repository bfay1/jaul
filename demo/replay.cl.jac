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


# Every tactic node has all five of these leaving it. Which one the walker
# takes is not known until the rep answers - that is the whole design, so the
# page shows the road not taken as well as the road taken.
glob ALL_INTENTS: list[str] = [
    "SOFT_NO", "STONEWALLING", "NEEDS_ESCALATION", "ACCEPTED", "HARD_NO"
];


"""One candidate edge out of a node - lit if the walker took it, dim if not."""
def:pub EdgeOption(intent: str, target: str, gist: str, taken: bool) -> JsxElement {
    return <div className={"opt" + (" opt-taken" if taken else "")}>
        <span className="opt-stub"></span>
        <span className="opt-edge">{intent}</span>
        <span className="opt-gloss">{gist if taken else intent_label(intent)}</span>
        <span className="opt-target">{("→ " + pretty(target)) if taken else ""}</span>
    </div>;
}


"""The dialogue behind one taken edge - the two speakers kept visually apart."""
def:pub Exchange(t: TurnView) -> JsxElement {
    return <div className="exchange">
        <div className="say say-agent">
            <span className="who">Agent</span>
            <p>{t.agent}</p>
        </div>
        <div className="say say-rep">
            <span className="who">Billing rep</span>
            <p>{t.rep}</p>
        </div>
    </div>;
}


"""A node in the graph. `kind` is "tactic" or "final"."""
def:pub NodeBox(label: str, kind: str) -> JsxElement {
    return <div className={"nodebox nodebox-" + kind}>
        <span className="nodedot"></span>
        <span className="nodelabel">{pretty(label)}</span>
    </div>;
}


"""One hop: the node the walker was on, then the typed edge it took off it.

The exchange that produced that edge hangs off the edge itself, collapsed -
the rep's reply is literally what the classifier turned into this edge type.
"""
def:pub Step(t: TurnView, index: int, expanded: bool, onToggle: Callable[[int], None]) -> JsxElement {
    def handle(e: MouseEvent) {
        onToggle(index);
    }

    return <li className="step">
        <NodeBox label={t.tactic} kind="tactic" />
        <div className="link">
            <div className="fan">
                {for opt in ALL_INTENTS {
                    <EdgeOption intent={opt} target={t.next_tactic} gist={t.gist}
                                taken={opt == t.intent} key={opt} />;
                }}
            </div>
            <button className="peek" onClick={handle}>
                {"hide exchange" if expanded else "what the rep said"}
            </button>
            {<Exchange t={t} /> if expanded else None}
        </div>
    </li>;
}


def:pub app -> JsxElement {
    has turns: list[TurnView] = [];
    has meta: CallMeta | None = None;
    has shown: int = 0;
    has open_hop: int = -1;
    has playing: bool = True;
    has loaded: bool = False;
    # Horizontal lays the hops left-to-right, which reads more like a drawn
    # graph but has nowhere inline to put an exchange - so in that mode the
    # open exchange renders in one detail panel under the graph instead.
    has horiz: bool = False;

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

    def flip_layout(e: MouseEvent) {
        horiz = not horiz;
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
                Five typed edges leave every tactic node. The walker doesn't
                know which it takes until the rep answers — the lit one is what
                the reply was classified as.
            </p>

            <ul className={"flow flow-horiz" if horiz else "flow"}>
                {for i in range(shown) {
                    <Step t={turns[i]} index={i} expanded={open_hop == i}
                          onToggle={toggle_hop} key={str(i)} />;
                }}
                {<li className="step step-last">
                    <NodeBox label={turns[len(turns) - 1].next_tactic} kind="final" />
                </li> if done and len(turns) > 0 else None}
            </ul>

            {<div className="detail">
                <Exchange t={turns[open_hop]} />
            </div> if horiz and open_hop >= 0 and open_hop < shown else None}

            {<div className="outcome">
                <div className="outcome-head">terms agreed</div>
                <p>{meta.deal_terms if meta else ""}</p>
            </div> if done and meta and meta.outcome == "deal_reached" else None}

            <div className="controls">
                {<button className="btn" onClick={replay}>Replay</button> if done
                 else <button className="btn btn-ghost" onClick={show_all}>Skip</button>}
                <button className="btn btn-ghost" onClick={flip_layout}>
                    {"Vertical" if horiz else "Horizontal"}
                </button>
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
