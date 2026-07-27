"""Run the real telephony server with a scripted MockLLM conversation loaded -
lets you test /live end-to-end with no ANTHROPIC_API_KEY, no Twilio, no network.

Terminal 1:
    jac run telephony/demo_mock_server.jac
    # then open http://localhost:8080/live in a browser

Terminal 2 - drive it one turn at a time, watching /live update after each:
    curl -X POST http://localhost:8080/twiml/start -d "CallSid=demo1"
    curl -X POST http://localhost:8080/twiml/turn -d "CallSid=demo1&SpeechResult=Let me see what I can find, I'm not sure what applies here."
    curl -X POST http://localhost:8080/twiml/turn -d "CallSid=demo1&SpeechResult=I don't have the authority to approve a discount myself."
    curl -X POST http://localhost:8080/twiml/turn -d "CallSid=demo1&SpeechResult=Okay, let me pull up the financial assistance policy for this."
    curl -X POST http://localhost:8080/twiml/turn -d "CallSid=demo1&SpeechResult=My supervisor approved a 60%% discount and paused collections."

The actual SpeechResult text you send doesn't matter to the outcome - it's
cosmetic (shown in the transcript) - the scripted outputs below are what
actually drive classify_response/choose_next_tactic/generate_line in order.
Send fewer or more turns and it'll just run out of scripted outputs and error;
restart this process to reset it.
"""
import from telephony.core { use_mock_llm }
import agent;

with entry:__main__ {
    use_mock_llm([
        "Hi, I'm calling on behalf of Jordan Rivera about their account - are there any financial assistance programs they might qualify for?",
        agent.RepIntent.SOFT_NO,
        agent.TacticMove.OFFER_INCOME_DISCOUNT,
        "Given their income is around 150% of the federal poverty level, could we apply an income-based discount to the $4,200 balance?",
        agent.RepIntent.STONEWALLING,
        agent.TacticMove.CITE_501R,
        "As a nonprofit hospital, you're required under IRS 501(r) to maintain a financial assistance policy and check eligibility before collections - could we pause collections while that's reviewed?",
        agent.RepIntent.NEEDS_ESCALATION,
        agent.TacticMove.ESCALATE,
        "Thank you - could I speak with a supervisor about setting up the assistance review?",
        agent.RepIntent.ACCEPTED,
        agent.Commitment(is_firm=True, amount="60%",
                         summary="60% discount approved and collections paused pending the assistance review")
    ]);

    # Imported here, after use_mock_llm, so the server module picks up the
    # mocked agent.llm at import time instead of the real byllm client.
    import from telephony.server { app }
    import uvicorn;
    uvicorn.run(app, host="0.0.0.0", port=8080);
}
