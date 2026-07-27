"""The frozen call, stored as a real graph and replayed by a real walker.

This is the offline demo's server half. It exists to make one point honestly:
the transcript below is not a JSON file being printed. It is rebuilt as an
actual Object-Spatial graph - a `Tactic` node per phase of the call, a TYPED
edge per classified rep reply - and a walker traverses it to produce what the
page renders, exactly as `agent.jac` does during a live call.

The dialogue itself was captured from one genuine run against the mock
hospital rep (`capture_trace.jac` in the repo root, model claude-sonnet-4-6).
No API key, phone line, or network call is involved in replaying it.

NOTE ON TOOLCHAIN: this directory targets JacHammer's modern Jac, NOT the
jaclang 0.16.7 the rest of the repo is pinned to. Do not run it with
`jac-env`. See demo/README.md.
"""

# --- Graph shape -------------------------------------------------------------
# Deliberately the same shape as graph.jac: tactics are nodes, and what the rep
# just said is the EDGE TYPE, not a field or a branch in the walker.

# Bump when the seeded data changes. A previously-seeded root graph survives
# restarts and redeploys, so without a version check an updated trace is
# silently ignored in favour of the stale nodes already on the graph.
glob SEED_VERSION: int = 2;

node Tactic {
    has label: str;
    has seed_version: int = 0;
    has turn: int = 0;
    has agent_line: str = "";
    has rep_line: str = "";
    # A few words on what the rep actually DID, for the graph row. Generated
    # by gist_trace.jac, not hand-written.
    has gist: str = "";
}

node Terminal(Tactic) {
    has terms: str = "";
}

edge SoftNo: Tactic --> Tactic {}
edge Stonewalling: Tactic --> Tactic {}
edge NeedsEscalation: Tactic --> Tactic {}
edge Accepted: Tactic --> Tactic {}
edge HardNo: Tactic --> Tactic {}


# --- What crosses the wire ---------------------------------------------------
# Typed objs, so the client gets hydrated instances with dot access rather
# than untyped dicts.

obj CallMeta {
    has hospital: str = "";
    has patient: str = "";
    has captured_at: str = "";
    has model: str = "";
    has outcome: str = "";
    has deal_terms: str = "";
}

obj TurnView {
    has turn: int = 0;
    has tactic: str = "";
    has agent: str = "";
    has rep: str = "";
    has intent: str = "";
    has next_tactic: str = "";
    has gist: str = "";
    has terms: str = "";
}

# The result of following the one outgoing edge from a node.
obj Hop {
    has intent: str = "";
    has node: Tactic | None = None;
}

# --- The frozen call ---------------------------------------------------------
# Generated from demo/trace.json by capture_trace.jac. Every line below was
# spoken by a model during one real run on 2026-07-26; nothing is hand-written.

glob CALL_META: CallMeta = CallMeta(
    hospital="Bay Area General",
    patient="Jordan Rivera",
    captured_at="2026-07-26",
    model="claude-sonnet-4-6",
    outcome="deal_reached",
    deal_terms="Rep committed to an 85% charity care discount bringing the balance to $630, payable over up to 12 months interest-free, with an immediate collections hold and written confirmation within two business days."
);

"""Rebuild the frozen call as a real graph: one node per tactic, one typed
edge per classified rep reply. Idempotent - safe to call on every request."""
def seed_call -> Tactic {
    # Match on version as well as type: a stale chain from an older seed is
    # left in place but never traversed again.
    existing = [root -->[?:Tactic, seed_version == SEED_VERSION]];
    if len(existing) > 0 {
        return existing[0];
    }

    n0: Tactic = Tactic(label="opening", turn=1, seed_version=SEED_VERSION,
        agent_line="Hi, I'm calling on behalf of Jordan Rivera — date of birth August 14, 1991, account number BAG-4471902 — regarding a $4,200 balance from an emergency appendectomy on March 12, 2026, and I'd like to ask about any financial assistance or charity care programs Bay Area General may offer, as Jordan is currently uninsured and experiencing significant hardship.",
        rep_line="Sure, I can pull up that account — give me just a moment... okay, I'm seeing the balance you're referring to. We do have some assistance options available, but I'd need to know a bit more about Mr. Rivera's situation, like current income and household size, before I can say whether he'd qualify for anything.",
        gist="asks about income and household size");
    root ++> n0;
    n1: Tactic = Tactic(label="ESCALATE", turn=2,
        agent_line="Jordan's household of three has a gross annual income of about $31,000 — roughly 150% of the federal poverty level — and given that Bay Area General is a nonprofit hospital, I'd like to respectfully ask to speak with a supervisor or your financial assistance department, because under IRC 501(r)(4) through (6), Bay Area General is required to maintain a written Financial Assistance Policy and must determine FAP eligibility before taking any extraordinary collection actions, and with a collections notice already sent last week, I want to make sure we get Jordan's application reviewed right away.",
        rep_line="Okay, you're right that we have those obligations under our FAP, and at 150% FPL with a household of three, Mr. Rivera would likely fall within our assistance guidelines — let me go ahead and transfer you to our financial counseling department, because they're the ones who can actually review and approve an application. Please hold for just a moment while I connect you.",
        gist="transfers to financial counseling department");
    n0 +>:SoftNo:+> n1;
    n2: Tactic = Tactic(label="ESCALATE", turn=3,
        agent_line="Thank you so much for transferring us — while we wait for the financial counselor, could I also request that an itemized bill be sent to Jordan so we can review all the charges for accuracy before any payment arrangement is finalized?",
        rep_line="Sure, that's a completely reasonable request — I'll make a note on the account to have an itemized statement mailed to the address we have on file, and you can also request it in writing if you'd like a copy sent somewhere specific. Just hold tight, I'm getting the financial counselor on the line now.",
        gist="offers itemized statement, transfers call");
    n1 +>:NeedsEscalation:+> n2;
    n3: Tactic = Tactic(label="REQUEST_CHARITY_CARE", turn=4,
        agent_line="Thank you for your patience — when the financial counselor joins, I'd like to formally apply for charity care on Jordan's behalf, given that Jordan is a single parent supporting two children on roughly $31,000 a year, which is approximately 150% of the federal poverty level, and under Bay Area General's Financial Assistance Policy, that income level very likely falls within the eligibility range for free or significantly reduced care.",
        rep_line="Hi, thanks for holding — this is Maria Delgado, financial counselor here at Bay Area General. I've reviewed the notes from the rep and I can see Mr. Rivera's account. Go ahead and walk me through the application details and I'll get this processed for you.",
        gist="transfers to financial counselor");
    n2 +>:NeedsEscalation:+> n3;
    n4: Tactic = Tactic(label="REQUEST_CHARITY_CARE", turn=5,
        agent_line="Hi Maria, thank you for joining — I'm calling on behalf of Jordan Rivera, account BAG-4471902. Jordan is a 34-year-old single parent of two children, a household of three with a gross annual income of approximately $31,000 — about 150% of the federal poverty level — who was uninsured at the time of an emergency appendectomy on March 12th due to a February layoff. Given that income level, I'd like to formally request that Jordan be considered for charity care under Bay Area General's Financial Assistance Policy, and I'd also ask that collections activity be paused while the application is under review, as required under IRC 501(r)(6) before any extraordinary collection actions can proceed.",
        rep_line="Based on what you've described, Mr. Rivera's income at 150% FPL falls squarely within our charity care tier, which provides an 85% discount on the balance — bringing the $4,200 down to $630 — and we can set that up as an interest-free payment plan of up to 12 months if he'd like to spread it out. I'm also placing a collections hold on the account right now, effective immediately, so no further collection activity will occur while this is processed and going forward. I'll send written confirmation of the approved assistance and the hold to the address on file within two business days.",
        gist="approves discount, hold, and payment plan");
    n3 +>:NeedsEscalation:+> n4;
    n5: Terminal = Terminal(label="deal_reached", turn=6,
        terms="Rep committed to an 85% charity care discount bringing the balance to $630, payable over up to 12 months interest-free, with an immediate collections hold and written confirmation within two business days.");
    n4 +>:Accepted:+> n5;

    return n0;
}

# --- Traversal ---------------------------------------------------------------

"""Follow the single outgoing tactic edge from `current`.

The edge TYPE is the rep's classified intent - reading it back needs no
separate record of what the classifier decided, because the classification
*is* the edge. Spelled out five ways because an edge-type filter is a
compile-time literal in Jac and cannot be looped over.
"""
def next_hop(current: Tactic) -> Hop {
    soft = [current ->:SoftNo:->];
    if len(soft) > 0 {
        return Hop(intent="SOFT_NO", node=soft[0]);
    }
    stone = [current ->:Stonewalling:->];
    if len(stone) > 0 {
        return Hop(intent="STONEWALLING", node=stone[0]);
    }
    esc = [current ->:NeedsEscalation:->];
    if len(esc) > 0 {
        return Hop(intent="NEEDS_ESCALATION", node=esc[0]);
    }
    acc = [current ->:Accepted:->];
    if len(acc) > 0 {
        return Hop(intent="ACCEPTED", node=acc[0]);
    }
    hard = [current ->:HardNo:->];
    if len(hard) > 0 {
        return Hop(intent="HARD_NO", node=hard[0]);
    }
    return Hop(intent="", node=None);
}


"""Walk the frozen call and report one TurnView per hop.

A real walker over a real graph - the page renders whatever this reports. The
walk terminates because the frozen graph is a finite chain ending at a
`Terminal` node with no outgoing edge.
"""
walker:pub ReplayCall {
    has reports: list[TurnView] = [];

    can start with Root entry {
        visit [seed_call()];
    }

    can step with Tactic entry {
        hop = next_hop(here);
        if hop.node is None {
            disengage;
        }
        landing: Tactic = hop.node as Tactic;
        terms = "";
        if isinstance(landing, Terminal) {
            terms = (landing as Terminal).terms;
        }
        report TurnView(
            turn=here.turn,
            tactic=here.label,
            agent=here.agent_line,
            rep=here.rep_line,
            intent=hop.intent,
            next_tactic=landing.label,
            gist=here.gist,
            terms=terms
        );
        visit [landing];
    }
}


"""The frozen call's metadata - hospital, patient, outcome, agreed terms."""
def:pub call_meta -> CallMeta {
    return CALL_META;
}
