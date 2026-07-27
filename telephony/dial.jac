"""Place the outbound negotiation call via Twilio.

This is the ONLY part that needs a Twilio account, credentials, and network.
Everything else (core, transport, server) runs and tests offline.

Required env (see .env.example):
  TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, TWILIO_FROM_NUMBER, TWILIO_TO_NUMBER

PUBLIC_BASE_URL is OPTIONAL - unset, it defaults to the deployed Render server
below, so a call needs no local server or ngrok tunnel running. Set it only to
point at a local/alternate deployment instead.

DEMO SAFELY: point TWILIO_TO_NUMBER at your OWN phone and role-play the billing
rep. Do not autodial a real hospital billing line without consent - recording
and robocall rules vary by jurisdiction.

Usage:  jac run telephony/dial.jac
"""
import os;
import sys;

# The persistent Render deployment of telephony/server.jac (see render.yaml /
# README "Deploying"). Used as the default so `jaul` works with zero server
# setup; override by setting PUBLIC_BASE_URL if you're running your own.
glob DEFAULT_PUBLIC_BASE_URL: str = "https://jaul-telephony.onrender.com";


def place_call() -> str {
    import from twilio.rest { Client }  # lazy import: only needed for real dialing

    try {
        sid = os.environ["TWILIO_ACCOUNT_SID"];
        token = os.environ["TWILIO_AUTH_TOKEN"];
        from_number = os.environ["TWILIO_FROM_NUMBER"];
        to_number = os.environ["TWILIO_TO_NUMBER"];
    } except KeyError as missing {
        raise SystemExit(
            f"Missing required env var {missing}. Copy .env.example to .env, fill "
            "in your Twilio credentials, and load it into the shell."
        );
    }
    base = os.environ.get("PUBLIC_BASE_URL", DEFAULT_PUBLIC_BASE_URL).rstrip("/");

    client = Client(sid, token);
    call = client.calls.create(
        to=to_number,
        from_=from_number,
        url=f"{base}/twiml/start",
        method="POST"
    );
    return call.sid as str;
}


with entry:__main__ {
    call_sid = place_call();
    print(f"Placed call {call_sid} -> {os.environ.get('TWILIO_TO_NUMBER')}");
    print("Watch the server logs; the agent will speak first when you answer.");
    sys.exit(0);
}
