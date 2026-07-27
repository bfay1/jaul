"""jaul - offline demo entry point.

Server half: the frozen call's graph, its walker, and its metadata endpoint.
Client half: the replay page.
"""

import from calltrace { ReplayCall, call_meta, TurnView, CallMeta, Tactic, Terminal }

cl {
    import ".app.css";
    import from .replay { app as ReplayApp }

    def:pub app -> JsxElement {
        return <ReplayApp />;
    }
}
