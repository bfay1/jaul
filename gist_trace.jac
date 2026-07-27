"""Add an ultra-short gist of each rep reply to the captured trace.

The demo graph shows one row per hop; the rep's actual reply is several
sentences, far too long to sit on that row. This adds a `gist` field - a few
words capturing what the rep actually did - so the graph reads at a glance
without opening the transcript.

Generated, not hand-written, so the demo's "every word came from the model"
claim stays true.

    source jac-env/bin/activate
    jac run gist_trace.jac        # needs ANTHROPIC_API_KEY; rewrites demo/trace.json
"""

import json;
import os;

import from byllm.lib { Model }

glob llm: Model = Model(model_name="claude-sonnet-4-6");

glob TRACE_PATH: str = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "demo", "trace.json"
);

def gist_of(rep_line: str) -> str by llm();
sem gist_of = "Summarize what a hospital billing representative just did, in at most six words, as a terse lowercase fragment with no trailing period. Describe the ACTION, not the topic - e.g. 'asks for date of birth', 'transfers to financial counseling', 'approves 85% discount', 'refuses without verification'. No pronouns for the rep, start with the verb.";
sem gist_of.rep_line = "The billing representative's spoken line.";


with entry:__main__ {
    with open(TRACE_PATH) as f {
        trace: dict = dict(json.load(f));
    }

    # dict(t) COPIES, so mutating the copy and writing the original list back
    # silently drops every gist. Collect the copies instead.
    updated: list = [];
    for t in list(trace["turns"]) {
        turn: dict = dict(t);
        g: str = gist_of(turn["rep"] as str) as str;
        turn["gist"] = g.strip().lower().rstrip(".");
        print(str(turn["turn"]) + ". " + (turn["gist"] as str));
        updated.append(turn);
    }
    trace["turns"] = updated;

    with open(TRACE_PATH, "w") as f {
        json.dump(trace, f, indent=2);
    }
    print("--- updated " + TRACE_PATH + " ---");
}
