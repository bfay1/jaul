"""Transport interface + the two implementations (one real, one seam).

A Transport turns a negotiation turn (the agent's line + call status) into
whatever the phone layer needs to send back. Keeping this behind an interface
is the whole point of the design: the turn-based demo and a future real-time
streaming implementation share the same NegotiationSession core and differ only
here.
"""
from abc import ABC, abstractmethod
from xml.sax.saxutils import escape


class Transport(ABC):
    @abstractmethod
    def render(
        self,
        agent_line: str,
        status: str,
        turn_action_url: str,
        audio_url: str | None = None,
    ) -> tuple[str, str]:
        """Return (content_type, body) to send back for this turn.

        `audio_url`, if given, is pre-synthesized audio (e.g. ElevenLabs) that
        should be played instead of speaking `agent_line` via the built-in
        voice. Optional and defaulted so existing callers are unaffected.
        """
        ...


class TurnBasedTransport(Transport):
    """Twilio <Say> + <Gather input="speech"> — one rep turn per webhook.

    This is option 1: the agent speaks a line, Twilio transcribes the rep's
    spoken reply and POSTs it to the turn URL, and we advance one hop. TwiML is
    hand-rolled XML on purpose so this path carries NO `twilio` SDK dependency
    and stays unit-testable offline; the SDK is only needed to place the
    outbound call (see telephony.dial).
    """

    def __init__(
        self,
        voice: str = "Polly.Joanna",
        speech_timeout: str = "auto",
        language: str = "en-US",
    ) -> None:
        self.voice = voice
        self.speech_timeout = speech_timeout
        self.language = language

    def render(
        self,
        agent_line: str,
        status: str,
        turn_action_url: str,
        audio_url: str | None = None,
    ) -> tuple[str, str]:
        if audio_url is not None:
            voice_element = f"<Play>{escape(audio_url)}</Play>"
        else:
            voice_element = f'<Say voice="{escape(self.voice, {chr(34): "&quot;"})}">{escape(agent_line)}</Say>'
        url = escape(turn_action_url, {chr(34): "&quot;"})
        if status == "in_progress":
            body = (
                '<?xml version="1.0" encoding="UTF-8"?>'
                "<Response>"
                # voice_element plays to completion BEFORE Gather starts listening
                # (siblings, not nested) - on speakerphone, a nested <Gather> starts
                # listening the instant playback begins and the mic picks up the
                # phone's own speaker output, feeding Twilio's STT garbage. A
                # handset's earpiece has no such acoustic coupling, which is why
                # this only broke on speaker.
                f"{voice_element}"
                f'<Gather input="speech" action="{url}" method="POST" '
                f'speechTimeout="{self.speech_timeout}" language="{self.language}"/>'
                # Rep said nothing within the gather: bounce back to reprompt.
                f'<Redirect method="POST">{url}</Redirect>'
                "</Response>"
            )
        else:
            body = (
                '<?xml version="1.0" encoding="UTF-8"?>'
                f"<Response>{voice_element}<Hangup/></Response>"
            )
        return "application/xml", body


class StreamingTransport(Transport):
    """PLACEHOLDER for real-time Twilio Media Streams — option 2.

    Media Streams opens a bidirectional WebSocket carrying raw call audio; you
    pair it with a streaming STT (rep audio -> text) and streaming TTS (agent
    text -> audio). Crucially, the negotiation core (NegotiationSession) does
    NOT change: you still call session.advance(transcribed_text) and speak
    session's returned line — only the transport differs. To wire it up:

      1. Return `<Connect><Stream url="wss://.../media"/></Connect>` from the
         initial TwiML instead of <Gather>.
      2. Add a WebSocket route in server.py that receives audio frames, runs
         STT, calls session.advance(...), runs TTS, and streams frames back.
      3. Implement render() here for any mid-stream TwiML you need.

    Left unimplemented so the turn-based demo ships first; this class marks the
    exact seam to fill when time permits.
    """

    def render(
        self,
        agent_line: str,
        status: str,
        turn_action_url: str,
        audio_url: str | None = None,
    ) -> tuple[str, str]:
        raise NotImplementedError(
            "StreamingTransport is the documented Media Streams seam (option 2); "
            "the working demo uses TurnBasedTransport."
        )
