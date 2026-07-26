"""Telephony transport for the jaul negotiation agent.

The negotiation logic lives in Jac (graph.jac / agent.jac). This package is a
thin transport layer that carries a live phone call to and from that Jac core -
and is itself written entirely in Jac (core.jac, transport.jac, server.jac,
voice.jac, dial.jac). This file stays .py only because Python's package system
looks for that exact filename to mark a directory importable; it has no logic
of its own.

- core.jac      NegotiationSession - drives the Jac walker per turn, natively
                (spawn/root/++> work directly here - no Python bridge needed).
- transport.jac Transport interface; TurnBasedTransport (Twilio Say+Gather) now,
                StreamingTransport (Media Streams) documented as a swap-in later.
- server.jac    FastAPI webhook app Twilio calls into (third-party @app.post(...)
                decorators work directly on Jac async functions).
- voice.jac     ElevenLabs TTS - opt-in, never on the critical path.
- dial.jac      Places the outbound call (real Twilio; behind env config).

Everything except dial.jac runs offline with no Twilio account or network, so
the whole conversation flow is unit-testable (see test_flow.jac / test_voice.jac).
"""
