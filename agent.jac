"""The negotiation engine: LLM-backed intelligence + the traversing walker.

This module owns the *behavior* - how the agent decides what to say, how it
reads the rep's reply, how it picks its next tactic, and how the walker
builds and moves across the tactic graph defined in `graph.jac`. The graph is
NOT pre-wired: each walker creates the next node and edge live, per turn, as
it decides what to do - the traversal and the graph's shape are the same
live decision. The MockLLM tests live here too, because they swap this
module's `glob llm` and exercise the same functions.
"""

import from byllm.lib { Model, MockLLM }
import from graph {
    Tactic, Opening, TacticStep, DealReached, DeadEnd, ProgramKnowledge,
    Hospital,
    SoftNo, Stonewalling, NeedsEscalation, Accepted, HardNo, HadCall,
    start_call, program_context, seed_program_knowledge,
    get_or_create_hospital, summarize_experience, record_call_outcome
}

# --- Model config ------------------------------------------------------------
# Auth comes from the ANTHROPIC_API_KEY env var (see .env / .env.example) -
# never hardcode a key here or in jac.toml. The `Model | MockLLM` union lets
# the tests below swap in a deterministic mock without an API key.
#
# Model choice is constrained by byllm 0.6.19: it always sends a `temperature`
# on the call, and claude-sonnet-5 rejects that outright ("`temperature` is
# deprecated for this model"), which 500s every live turn. sonnet-4-6 still
# accepts it. Revisit if byllm is ever upgraded.
glob llm: Model | MockLLM = Model(model_name="claude-sonnet-4-6");


# --- Patient context --------------------------------------------------------
# The patient's case file - a single markdown document (bill, income, insurance,
# hardship, goals) that the agent argues from. `notes` holds the full markdown;
# `name` is a short label pulled from its heading. An `obj` (not a node) because
# it's the LLM boundary: `by llm()` takes objs, and storage can evolve apart.
# The case file is loaded from disk by casefile.py (CLI `--case`) or telephony.

obj PatientCase {
    has name: str = "the patient";
    has notes: str = "";

    # A METHOD, not a free function taking PatientCase as a parameter. This
    # matters: byllm 0.6.19's compile-time param extraction silently drops an
    # obj-typed parameter from its internal params list while the runtime args
    # dict still has it, crashing every call with an IndexError deep in
    # byllm's prompt builder. Method-level `by llm()` sidesteps this entirely
    # and is byllm's own documented idiom - the object's `has` fields (name,
    # notes) are automatically included as context, no explicit passing
    # needed. Verified working via a minimal repro before adopting this.
    def generate_line(tactic_label: str, transcript: list[str], programs: list[str]) -> str by llm();
}
sem PatientCase = "The case file for the patient the agent is advocating for.";
sem PatientCase.name = "A short name/label for the patient, for display.";
sem PatientCase.notes = "The full case file (markdown): the patient's financial situation, insurance, bill, hardship, and goals. Ground every ask in these specifics.";
sem PatientCase.generate_line = "You are a calm, persistent patient advocate on a phone call with a hospital billing department, calling on behalf of the patient described by your name and notes. Introduce yourself only as calling on behalf of that patient by name (e.g. \"I'm calling on behalf of Jordan Rivera\") - you have no name of your own, so NEVER invent, state, or use a placeholder name (such as 'Agent Name' or similar) for yourself. Ground every ask in the case's specifics - income relative to the federal poverty level, the bill amount, insurance status, nonprofit 501(r) obligations, and hardship - to argue for income-based discounts, charity care, and interest-free payment plans they may qualify for, without being pushy. When the tactic phase calls for citing a specific real program (e.g. CITE_501R), name the actual rule or citation from the given program facts rather than speaking generically. Given the current tactic phase, the transcript so far, and the real program facts available, draft the agent's single next spoken line - polite, concise, specific to this patient, and fitting the phase.";
sem PatientCase.generate_line.tactic_label = "The current negotiation phase: 'opening' (first ask about assistance programs), or the name of the tactic move just chosen - 'ASK_ASSISTANCE' (reiterating the ask), 'OFFER_INCOME_DISCOUNT' (proposing an income-based discount), 'REQUEST_CHARITY_CARE' (asking about charity care eligibility), 'PROPOSE_PAYMENT_PLAN' (proposing an interest-free payment plan), 'CITE_501R' (invoking the hospital's IRS 501(r) financial assistance policy obligations), or 'ESCALATE' (asking to speak with a supervisor).";
sem PatientCase.generate_line.transcript = "The call transcript so far, as alternating 'AGENT: ...' and 'REP: ...' lines.";
sem PatientCase.generate_line.programs = "Real financial-assistance program facts (name, eligibility, and legal/policy citation) the agent can draw on and cite by name - especially for the CITE_501R tactic.";

"""A built-in default case - used for tests and as the walkers' default when no
case file is supplied. Mirrors cases/jordan-rivera.md in brief."""
def demo_case() -> PatientCase {
    return PatientCase(
        name="Jordan Rivera",
        notes="Single parent, household of 3, ~$31,000/yr income (~150% of the federal poverty level). Uninsured after a February layoff. $4,200 emergency-surgery bill at Bay Area General, a nonprofit hospital (IRS 501(r) applies). Behind on rent; seeking charity care, an income-based discount, or an interest-free payment plan."
    );
}


# --- LLM-backed intelligence -------------------------------------------------
# Classification, tactic choice, dialogue generation, and the mock vendor-rep
# are each powered by `by llm()`. `sem` strings (not docstrings) tell the LLM
# what each piece means - docstrings inside a `by llm()` body are a parse
# error anyway, since `by llm()` replaces the body entirely.

enum RepIntent {
    SOFT_NO,
    STONEWALLING,
    NEEDS_ESCALATION,
    ACCEPTED,
    HARD_NO
}
sem RepIntent.SOFT_NO = "The rep gave a vague, noncommittal, or deflecting reply - not a refusal, but no real progress either.";
sem RepIntent.STONEWALLING = "The rep won't offer anything more at their level and is not budging, but hasn't issued a firm final no.";
sem RepIntent.NEEDS_ESCALATION = "The rep says they personally can't approve this and a supervisor or specialist must get involved.";
sem RepIntent.ACCEPTED = "The rep agrees to and confirms a concrete financial-assistance arrangement (discount, charity care, or payment plan).";
sem RepIntent.HARD_NO = "The rep firmly and finally states no assistance programs exist or will be offered.";

# The tactic the agent chooses to try next. RepIntent remains the SOLE
# authority on whether the call is over (ACCEPTED/HARD_NO short-circuit to
# DealReached/DeadEnd without ever calling choose_next_tactic) - there is no
# ACCEPT_DEAL/WALK_AWAY move here, deliberately, so there is never a case
# where the classifier and the tactic-chooser could disagree about whether
# the negotiation has ended.
enum TacticMove {
    ASK_ASSISTANCE,
    OFFER_INCOME_DISCOUNT,
    REQUEST_CHARITY_CARE,
    PROPOSE_PAYMENT_PLAN,
    CITE_501R,
    ESCALATE
}
sem TacticMove.ASK_ASSISTANCE = "Reiterate or clarify the ask about income-based financial assistance programs.";
sem TacticMove.OFFER_INCOME_DISCOUNT = "Propose a specific income-based discount on the bill.";
sem TacticMove.REQUEST_CHARITY_CARE = "Ask whether the patient qualifies for charity care - free or deeply discounted care.";
sem TacticMove.PROPOSE_PAYMENT_PLAN = "Propose an interest-free payment plan for the remaining balance.";
sem TacticMove.CITE_501R = "Invoke the hospital's IRS 501(r) financial assistance policy obligations, if it is a nonprofit hospital.";
sem TacticMove.ESCALATE = "Ask to speak with a supervisor or specialist who can approve more than the current rep can.";

def classify_response(response: str) -> RepIntent by llm();
sem classify_response = "Classify a hospital billing rep's most recent spoken line, during a patient's call negotiating financial assistance, into the intent that best matches what the rep just said.";
sem classify_response.response = "The rep's most recent spoken line in the call.";

def choose_next_tactic(transcript: list[str], last_intent: RepIntent, programs: list[str], prior_experience: str) -> TacticMove by llm();
sem choose_next_tactic = "Decide the patient advocate's next negotiation tactic during a call with a hospital billing department, given how the rep just responded, the transcript so far, the real assistance programs available, and what has worked against this same hospital in prior calls. Pick the single move most likely to advance toward a concrete financial-assistance arrangement, without repeating a tactic that visibly isn't working. Prefer CITE_501R when the available program facts include a nonprofit-hospital obligation that's directly relevant and hasn't been raised yet. When prior experience shows a tactic that has worked against this hospital before, prefer trying it earlier.";
sem choose_next_tactic.transcript = "The call transcript so far, as alternating 'AGENT: ...' and 'REP: ...' lines.";
sem choose_next_tactic.last_intent = "How the rep's most recent reply was just classified - what prompted this decision.";
sem choose_next_tactic.programs = "Real financial-assistance program facts (name, eligibility, and legal/policy citation) available to ground this choice - e.g. whether a 501(r) obligation or charity-care threshold applies.";
sem choose_next_tactic.prior_experience = "A summary of prior call outcomes against this same hospital, if any - which tactics led to a deal versus a dead end.";

# --- The commitment gate -----------------------------------------------------
# A rep who says "absolutely, I'll put a note on the account" sounds like a yes
# and commits to nothing. Sentiment alone must never close a call: ACCEPTED is
# honored only when concrete terms actually parse out of the rep's line.
#
# Without this, captured calls ended on the rep offering a phone number and a
# promise to make a note, and the walker recorded `deal_reached` - a deal that
# never happened. Verified against real captured transcripts, not hypothetical.

obj Commitment {
    has is_firm: bool = False;
    has amount: str = "";
    has term_months: int = 0;
    has interest_rate: str = "";
    has summary: str = "";
}
sem Commitment = "A concrete financial arrangement a hospital billing rep committed to, if any.";
sem Commitment.is_firm = "True only if the rep committed to a specific, verifiable arrangement the patient could hold them to. Vague goodwill, 'I'll note it', 'we can look into that', giving out a phone number, or a promise to call back are all False.";
sem Commitment.amount = "The dollar amount or percentage discount agreed, verbatim, or empty if none was stated.";
sem Commitment.term_months = "Length of the payment plan in months, or 0 if not stated.";
sem Commitment.interest_rate = "The stated interest rate or APR, verbatim. Empty if none was stated. Note 'interest-free' or '0%' explicitly if said.";
sem Commitment.summary = "One short sentence stating what was actually agreed, or why it does not count as a commitment.";

def extract_commitment(response: str) -> Commitment by llm();
sem extract_commitment = "Read a hospital billing rep's spoken line and extract any concrete financial arrangement they committed to. Be strict: only report is_firm when specific terms were actually stated.";
sem extract_commitment.response = "The rep's most recent spoken line in the call.";


# A plain obj rather than a tuple: an untyped tuple return erases RepIntent to
# `any` at every unpack site, which `jac check` then rejects downstream.
obj GatedIntent {
    has intent: RepIntent = RepIntent.SOFT_NO;
    has terms: str = "";
}


"""Classify the rep's line, then refuse to let warmth alone end the call.

Only ACCEPTED pays for the second LLM call, and an ACCEPTED carrying no firm
terms is downgraded to SOFT_NO so the walker keeps negotiating instead of
walking to DealReached on a promise to make a note.
"""
def gated_intent(response: str) -> GatedIntent {
    intent = classify_response(response);
    if intent != RepIntent.ACCEPTED {
        return GatedIntent(intent=intent, terms="");
    }
    commitment = extract_commitment(response);
    if not commitment.is_firm {
        return GatedIntent(intent=RepIntent.SOFT_NO, terms="");
    }
    return GatedIntent(intent=intent, terms=commitment.summary);
}


def rep_reply(transcript: list[str]) -> str by llm();
sem rep_reply = "You are playing a realistic, moderately resistant hospital billing department representative on a phone call. Respond naturally and briefly - two or three sentences - to the agent's most recent line, staying consistent with everything said earlier in the call. Be a believable mix of vague deflection, protectiveness about what you're allowed to approve, occasional willingness to loop in a supervisor, and only rarely an immediate yes. CRUCIALLY, you must have a real path to authority: a front-line rep genuinely cannot approve a discount, but once the advocate escalates and you hand the call to a supervisor or financial counselor, you are then speaking AS that person - and a counselor presented with a documented case that plainly meets the stated policy does approve it, stating the concrete terms out loud (the specific discount or waiver, the plan length, and that it is interest-free). Never concede terms before escalation; once escalated and the case clearly qualifies, do not stall indefinitely.";
sem rep_reply.transcript = "The call transcript so far, as alternating 'AGENT: ...' and 'REP: ...' lines. Reply as the REP's next line only.";


# --- Graph-building helpers --------------------------------------------------
# Shared by both walkers below. Live here (not graph.jac) because they need
# RepIntent/TacticMove at runtime, and graph.jac stays LLM/decision-free.

"""Create the next TacticStep for a continuing intent (SOFT_NO/STONEWALLING/
NEEDS_ESCALATION), connect it from `current` via the matching typed edge, and
return it. Edge-type creation is compile-time-literal (`+>:E():+>`), hence the
ladder rather than a single parameterized call - confirmed via a scratch check
before writing this."""
def advance_tactic(current: Tactic, intent: RepIntent, move: TacticMove) -> TacticStep {
    move_name: str = move.name;
    new_step: TacticStep = TacticStep(label=move_name, move=move_name);
    if intent == RepIntent.SOFT_NO {
        current +>:SoftNo():+> new_step;
    } elif intent == RepIntent.STONEWALLING {
        current +>:Stonewalling():+> new_step;
    } else {
        current +>:NeedsEscalation():+> new_step;
    }
    return new_step;
}

"""Create the terminal node for ACCEPTED/HARD_NO, connect it from `current`,
and return it. The only place a call can end - RepIntent is the sole
authority on this, never TacticMove."""
def reach_terminal(current: Tactic, intent: RepIntent) -> Tactic {
    if intent == RepIntent.ACCEPTED {
        deal: DealReached = DealReached(label="deal_reached");
        current +>:Accepted():+> deal;
        return deal;
    }
    dead: DeadEnd = DeadEnd(label="dead_end");
    current +>:HardNo():+> dead;
    return dead;
}

"""Strip a leading speaker label and wrapping quotes off a generated line.

The `sem` strings ask for a bare spoken line, but the transcript the model is
shown is formatted as "AGENT: ..." / "REP: ...", so it periodically echoes
that prefix back - and sometimes wraps the whole line in quotes on top. Both
reach the caller verbatim if left alone: a transcript reads "AGENT: AGENT:
Hi..." and, worse, a live Twilio call literally speaks the word "agent"
before the actual sentence.
"""
def clean_line(raw: str, label: str) -> str {
    line: str = raw.strip();
    if line.upper().startswith(label) {
        line = line[len(label):].strip();
    }
    if len(line) >= 2 and line.startswith("\"") and line.endswith("\"") {
        line = line[1:len(line) - 1].strip();
    }
    return line;
}


"""Read which tactic move led to a just-reached terminal node (DealReached or
DeadEnd), for outcome recording. "opening" means the call ended on the very
first turn, before any tactic move was ever chosen. Reads the incoming edge
rather than tracking a walker field across the visit - works identically for
NegotiationAgent's single spawn and NegotiationTurn's fresh-spawn-per-turn."""
def move_leading_to(terminal: Tactic) -> str {
    predecessors = [terminal <--];
    if len(predecessors) == 0 {
        return "opening";
    }
    prior = predecessors[0];
    if isinstance(prior, TacticStep) {
        return prior.move;
    }
    return "opening";
}


# --- The walker: the negotiation engine -------------------------------------

walker NegotiationAgent {
    has transcript: list[str] = [];
    has outcome: str = "in_progress";
    has turns: int = 0;
    has max_turns: int = 6;
    has patient: PatientCase = demo_case();
    has hospital: Hospital | None = None;
    has deal_terms: str = "";              # OUT: what was actually agreed, if anything

    can negotiate with Opening | TacticStep entry {
        self.turns += 1;
        if self.turns > self.max_turns {
            self.outcome = "dead_end";
            disengage;
        }

        programs = program_context();
        line = clean_line(self.patient.generate_line(here.label, self.transcript, programs), "AGENT:");
        self.transcript.append("AGENT: " + line);

        response = clean_line(rep_reply(self.transcript), "REP:");
        self.transcript.append("REP: " + response);

        gated = gated_intent(response);
        intent = gated.intent;
        if gated.terms != "" {
            self.deal_terms = gated.terms;
        }

        if intent == RepIntent.ACCEPTED or intent == RepIntent.HARD_NO {
            terminal_node = reach_terminal(here, intent);
            visit [terminal_node];
        } else {
            prior_experience = "No prior calls with this hospital.";
            if self.hospital is not None {
                prior_experience = summarize_experience(self.hospital);
            }
            move = choose_next_tactic(self.transcript, intent, programs, prior_experience);
            new_step = advance_tactic(here, intent, move);
            visit [new_step];
        }
    }

    can reach_deal with DealReached entry {
        self.outcome = "deal_reached";
        here.terms = self.deal_terms;
        self.transcript.append("OUTCOME: deal reached - " + self.deal_terms);
        if self.hospital is not None {
            record_call_outcome(self.hospital, "deal_reached", move_leading_to(here));
        }
        disengage;
    }

    can reach_dead_end with DeadEnd entry {
        self.outcome = "dead_end";
        self.transcript.append("OUTCOME: no assistance available");
        if self.hospital is not None {
            record_call_outcome(self.hospital, "dead_end", move_leading_to(here));
        }
        disengage;
    }
}


# --- Single-turn walker (telephony transport) -------------------------------
# NegotiationAgent above runs a whole call in one blocking loop (great for the
# mock demo and tests). A live phone call is different: each turn arrives as a
# separate Twilio webhook, so the walker must advance ONE hop per spawn and
# hand control back. NegotiationTurn does exactly that - the transport layer
# (telephony/) spawns a fresh one each webhook, on the node the last turn ended
# on, passing in what the rep just said. The traversal logic is identical; only
# who supplies the rep's line differs (a real human, not `rep_reply`).
#
# Dynamic node creation doesn't threaten the one-hop-per-spawn contract:
# on the "have a reply" branch below, the ability constructs the target node
# THIS INSTANT and `visit`s it - the same spawn immediately re-enters that
# fresh node's "just arrived" branch (rep_utterance is now ""), sets
# end_node, and disengages. Identical shape to traversing a pre-wired edge;
# telephony/core.py needs no changes for this.

walker NegotiationTurn {
    has rep_utterance: str = "";           # empty on the opening turn
    has transcript: list[str] = [];        # carried across turns by the caller
    has agent_line: str = "";              # OUT: what to speak this turn
    has status: str = "in_progress";       # OUT: in_progress | deal_reached | dead_end
    has end_node: Tactic | None = None;    # OUT: node to resume from next turn
    has patient: PatientCase = demo_case();
    has hospital: Hospital | None = None;
    has last_intent: str = "";             # OUT: this turn's RepIntent classification, "" before any reply
    has last_move: str = "";               # OUT: this turn's chosen TacticMove, "" if terminal or none yet
    has deal_terms: str = "";              # OUT: what was actually agreed, if anything

    can step with Opening | TacticStep entry {
        # No rep utterance yet => we just arrived at this tactic (either the
        # call's opening, or a hop taken this same spawn). Speak its line and
        # stop, leaving `end_node` here for the next webhook to resume from.
        if self.rep_utterance == "" {
            programs = program_context();
            self.agent_line = clean_line(self.patient.generate_line(here.label, self.transcript, programs), "AGENT:");
            self.transcript.append("AGENT: " + self.agent_line);
            self.end_node = here;
            disengage;
        }

        # We have the rep's reply to the line we spoke last turn: classify it,
        # then build and traverse exactly one typed edge to a fresh node.
        # Clearing rep_utterance means the node we land on takes the branch
        # above and generates the next line.
        self.transcript.append("REP: " + self.rep_utterance);
        gated = gated_intent(self.rep_utterance);
        intent = gated.intent;
        if gated.terms != "" {
            self.deal_terms = gated.terms;
        }
        self.last_intent = intent.name;
        self.rep_utterance = "";

        if intent == RepIntent.ACCEPTED or intent == RepIntent.HARD_NO {
            self.last_move = "";
            terminal_node = reach_terminal(here, intent);
            visit [terminal_node];
        } else {
            prior_experience = "No prior calls with this hospital.";
            if self.hospital is not None {
                prior_experience = summarize_experience(self.hospital);
            }
            move = choose_next_tactic(self.transcript, intent, program_context(), prior_experience);
            self.last_move = move.name;
            new_step = advance_tactic(here, intent, move);
            visit [new_step];
        }
    }

    can arrive_deal with DealReached entry {
        self.status = "deal_reached";
        here.terms = self.deal_terms;
        self.agent_line = "Wonderful - thank you so much, that's a real help. Have a great day.";
        self.transcript.append("AGENT: " + self.agent_line);
        self.end_node = here;
        if self.hospital is not None {
            record_call_outcome(self.hospital, "deal_reached", move_leading_to(here));
        }
        disengage;
    }

    can arrive_dead_end with DeadEnd entry {
        self.status = "dead_end";
        self.agent_line = "I understand - thank you for taking the time to look into it for me.";
        self.transcript.append("AGENT: " + self.agent_line);
        self.end_node = here;
        if self.hospital is not None {
            record_call_outcome(self.hospital, "dead_end", move_leading_to(here));
        }
        disengage;
    }
}


# --- Tests (MockLLM - no API key or network needed) --------------------------

test "rep agrees immediately and the call reaches a deal" {
    global llm;
    llm = MockLLM(model_name="mockllm", config={"outputs": [
        "Hi, I'm calling about my account - are there any financial assistance programs I might qualify for?",
        "Sure, let me get that set up for you right now.",
        RepIntent.ACCEPTED,
        Commitment(is_firm=True, amount="40%", summary="40% income-based discount applied to the balance")
    ]});

    hospital = get_or_create_hospital("Test Hospital - immediate accept");
    opening = start_call(hospital);
    result = opening spawn NegotiationAgent(hospital=hospital);

    assert result.outcome == "deal_reached";
    assert len(result.transcript) >= 3;
    assert "OUTCOME: deal reached" in result.transcript[-1];
}

test "a firm hard no from the rep leads to a dead end" {
    global llm;
    llm = MockLLM(model_name="mockllm", config={"outputs": [
        "Hi, I'm calling about my account - are there any financial assistance programs I might qualify for?",
        "No, we don't offer anything like that, sorry.",
        RepIntent.HARD_NO
    ]});

    hospital = get_or_create_hospital("Test Hospital - hard no");
    opening = start_call(hospital);
    result = opening spawn NegotiationAgent(hospital=hospital);

    assert result.outcome == "dead_end";
    assert result.transcript[-1] == "OUTCOME: no assistance available";
}

test "escalation followed by acceptance still reaches a deal" {
    global llm;
    llm = MockLLM(model_name="mockllm", config={"outputs": [
        "Hi, I'm calling about my account - are there any financial assistance programs I might qualify for?",
        "I can't approve that myself, you'd need to talk to my supervisor.",
        RepIntent.NEEDS_ESCALATION,
        TacticMove.ESCALATE,
        "Let me see what my supervisor can authorize for a hardship adjustment.",
        "Okay, my supervisor approved an interest-free payment plan for you.",
        RepIntent.ACCEPTED,
        Commitment(is_firm=True, term_months=24, interest_rate="0%",
                   summary="Interest-free payment plan over 24 months")
    ]});

    hospital = get_or_create_hospital("Test Hospital - escalation then accept");
    opening = start_call(hospital);
    result = opening spawn NegotiationAgent(hospital=hospital);

    assert result.outcome == "deal_reached";
}

test "a warm non-commitment does not close the call" {
    # The exact failure two real captured calls hit: the rep offers a phone
    # number and a promise to put a note on the account, the classifier reads
    # that warmth as ACCEPTED, and the walker reports a deal that never
    # happened. The gate must downgrade it to SOFT_NO and keep negotiating.
    global llm;
    llm = MockLLM(model_name="mockllm", config={"outputs": [
        "Hi, I'm calling about my account - are there any financial assistance programs I might qualify for?",
        "Of course - I'll put a note on the account and you can call financial counseling at 555-0183.",
        RepIntent.ACCEPTED,
        Commitment(is_firm=False, summary="Only promised to note it and gave a phone number; no terms stated"),
        TacticMove.PROPOSE_PAYMENT_PLAN,
        "Could we set up an interest-free payment plan on the balance instead?",
        "No, we don't do that here.",
        RepIntent.HARD_NO
    ]});

    hospital = get_or_create_hospital("Test Hospital - warm non-commitment");
    opening = start_call(hospital);
    result = opening spawn NegotiationAgent(hospital=hospital);

    # It must NOT have closed on the warm line; it kept going and only ended
    # on the genuine refusal that followed.
    assert result.outcome == "dead_end";
    assert result.deal_terms == "";
    assert any("interest-free payment plan" in line for line in result.transcript);
}

test "a firm commitment records the agreed terms" {
    global llm;
    llm = MockLLM(model_name="mockllm", config={"outputs": [
        "Hi, I'm calling about my account - are there any financial assistance programs I might qualify for?",
        "I can approve a 60% charity-care discount on the balance today.",
        RepIntent.ACCEPTED,
        Commitment(is_firm=True, amount="60%", summary="60% charity-care discount approved on the balance")
    ]});

    hospital = get_or_create_hospital("Test Hospital - firm commitment");
    opening = start_call(hospital);
    result = opening spawn NegotiationAgent(hospital=hospital);

    assert result.outcome == "deal_reached";
    assert result.deal_terms == "60% charity-care discount approved on the balance";
    assert "60%" in result.transcript[-1];
}

test "cross-call learning accumulates outcomes for the same hospital" {
    global llm;
    hospital = get_or_create_hospital("Test Hospital - learning demo");
    count_before = len([hospital ->:HadCall:->]);

    llm = MockLLM(model_name="mockllm", config={"outputs": [
        "Hi, I'm calling about my account - are there any financial assistance programs I might qualify for?",
        "No, we don't offer anything like that, sorry.",
        RepIntent.HARD_NO
    ]});
    opening1 = start_call(hospital);
    result1 = opening1 spawn NegotiationAgent(hospital=hospital);
    assert result1.outcome == "dead_end";

    outcomes_after_first = [hospital ->:HadCall:->];
    assert len(outcomes_after_first) == count_before + 1;
    assert outcomes_after_first[-1].result == "dead_end";
    assert outcomes_after_first[-1].winning_move == "opening";

    llm = MockLLM(model_name="mockllm", config={"outputs": [
        "Hi, I'm calling about my account - are there any financial assistance programs I might qualify for?",
        "Sure, let me get that set up for you right now.",
        RepIntent.ACCEPTED,
        Commitment(is_firm=True, amount="40%", summary="40% income-based discount applied to the balance")
    ]});
    opening2 = start_call(hospital);
    result2 = opening2 spawn NegotiationAgent(hospital=hospital);
    assert result2.outcome == "deal_reached";

    outcomes_after_second = [hospital ->:HadCall:->];
    assert len(outcomes_after_second) == count_before + 2;

    experience = summarize_experience(hospital);
    assert "deal_reached" in experience;
    assert "dead_end" in experience;
}

test "program knowledge seeds idempotently and flattens to non-empty strings" {
    seed_program_knowledge();
    count_after_first = len([root -->[?:ProgramKnowledge]]);
    seed_program_knowledge();
    count_after_second = len([root -->[?:ProgramKnowledge]]);

    assert count_after_first > 0;
    assert count_after_first == count_after_second;

    facts = program_context();
    assert len(facts) == count_after_first;
    for fact in facts {
        assert len(fact) > 0;
    }
}
