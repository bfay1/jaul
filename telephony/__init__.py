"""Telephony transport for the jaul negotiation agent.

The negotiation logic lives in Jac (graph.jac / agent.jac). This package is a
thin transport layer that carries a live phone call to and from that Jac core:

- core.py      NegotiationSession — drives the Jac single-turn walker per turn.
- transport.py Transport interface; TurnBasedTransport (Twilio Say+Gather) now,
               StreamingTransport (Media Streams) documented as a swap-in later.
- server.py    FastAPI webhook app Twilio calls into.
- dial.py      Places the outbound call (real Twilio; behind env config).

Everything except dial.py runs offline with no Twilio account or network, so
the whole conversation flow is unit-testable (see test_flow.py).
"""
