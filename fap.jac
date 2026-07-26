"""Real hospital financial-assistance facts, for grounding what the agent says.

US nonprofit hospitals must publish a Financial Assistance Policy under IRS
501(r), so their eligibility thresholds are public. `data/fap_corpus.json`
holds the ones we've read from primary sources, plus the federal poverty
guidelines that convert a threshold like "300% FPL" into a dollar figure for
a specific household.

The point is the difference between these two lines:

    "Are there any financial assistance programs I might qualify for?"
    "At a household of three on $48,000 we're at about 176% of the federal
     poverty level. Your published policy discounts bills by 60% or more
     under 300%, so I'd like to apply."

The second is checkable, and a rep cannot deflect it with "we don't have
anything like that." Everything here exists to produce the second line.
"""

import json;
import os;

glob CORPUS_PATH: str = os.path.join(os.path.dirname(__file__), "data", "fap_corpus.json");

glob _corpus: dict = {};


"""Load the corpus once, cached. Returns an empty dict if the file is absent."""
def corpus() -> dict {
    if _corpus {
        return _corpus;
    }
    if not os.path.exists(CORPUS_PATH) {
        return {};
    }
    with open(CORPUS_PATH) as f {
        loaded = json.load(f);
    }
    for (k, v) in loaded.items() {
        _corpus[k] = v;
    }
    return _corpus;
}


"""The 100%-of-poverty income line for a household, in dollars."""
def poverty_line(household_size: int, state: str = "") -> int {
    data: dict = dict(corpus().get("federal_poverty_guidelines", {}));
    if not data {
        return 0;
    }
    key = "contiguous_48_and_dc";
    if state.upper() in ["AK", "ALASKA"] {
        key = "alaska";
    } elif state.upper() in ["HI", "HAWAII"] {
        key = "hawaii";
    }
    table: dict = dict(data.get(key, {}));
    if not table {
        return 0;
    }
    if str(household_size) in table {
        return int(table[str(household_size)]);
    }
    # Above the tabulated sizes: extend by the per-person increment.
    base_size = 8;
    if "8" not in table {
        # AK/HI tables list size 1 plus an increment, not a full column.
        base_size = 1;
    }
    base = int(table.get(str(base_size), 0));
    extra = int(table.get("each_additional", 0));
    return base + extra * max(0, household_size - base_size);
}


"""Where this household sits as a percentage of the poverty line."""
def fpl_percent(annual_income: float, household_size: int, state: str = "") -> int {
    line = poverty_line(household_size, state);
    if line <= 0 {
        return 0;
    }
    return int(round(annual_income / line * 100.0));
}


obj AssistanceContext {
    has fpl_pct: int = 0;
    has poverty_line: int = 0;
    has hospital: str = "";
    has qualifies_hint: str = "";
    has hardship_hint: str = "";
    has quotable: str = "";
    has levers: list[str] = [];
}


"""Assemble what the agent should know before it opens its mouth.

`hospital_key` selects a verified policy when we have one; otherwise the
national priors are used, which still let the agent name a typical threshold
and ask the rep to confirm their own.
"""
def assistance_context(
    annual_income: float,
    household_size: int,
    bill_amount: float = 0.0,
    hospital_key: str = "",
    state: str = ""
) -> AssistanceContext {
    c = corpus();
    ctx = AssistanceContext();
    ctx.poverty_line = poverty_line(household_size, state);
    ctx.fpl_pct = fpl_percent(annual_income, household_size, state);
    ctx.levers = list(dict(c.get("levers", {})).get("items", []));

    policy: dict = {};
    for h in list(c.get("hospitals", [])) {
        entry: dict = dict(h);
        if entry.get("key") == hospital_key {
            policy = entry;
        }
    }

    if policy {
        ctx.hospital = str(policy.get("name", ""));
        ctx.quotable = str(policy.get("quotable", ""));
        threshold = policy.get("discount_fpl_pct");
        if threshold is not None and ctx.fpl_pct > 0 {
            if ctx.fpl_pct < int(threshold) {
                ctx.qualifies_hint = f"At {ctx.fpl_pct}% of the federal poverty level this household is under {threshold}%, the published threshold for assistance at {ctx.hospital}.";
            } else {
                ctx.qualifies_hint = f"At {ctx.fpl_pct}% of the federal poverty level this household is above the {threshold}% income threshold, so lead with the hardship provision rather than income.";
            }
        }
        hardship_pct = policy.get("hardship_bills_pct_of_income");
        if hardship_pct is not None and annual_income > 0 and bill_amount > 0 {
            share = int(round(bill_amount / annual_income * 100.0));
            if share >= int(hardship_pct) {
                ctx.hardship_hint = f"This bill is about {share}% of annual income, at or over the {hardship_pct}% hardship threshold - that route applies regardless of income.";
            }
        }
    } else {
        priors: dict = dict(c.get("national_priors", {}));
        common = priors.get("most_common_free_care_fpl_pct");
        ceiling = priors.get("common_discount_ceiling_fpl_pct");
        if common is not None and ctx.fpl_pct > 0 {
            ctx.qualifies_hint = f"No published policy on file for this hospital. Nationally the most common free-care threshold is {common}% of the federal poverty level and discounts commonly extend to {ceiling}%. This household is at {ctx.fpl_pct}% - name those figures and ask the rep to confirm the hospital's own.";
        }
    }
    return ctx;
}


# --- Tests -------------------------------------------------------------------

test "poverty line matches the published 2026 table" {
    assert poverty_line(1) == 15960;
    assert poverty_line(3) == 27320;
    assert poverty_line(8) == 55720;
    # Size 9 extends size 8 by the per-person increment.
    assert poverty_line(9) == 55720 + 5680;
    assert poverty_line(1, "AK") == 19950;
    assert poverty_line(1, "HI") == 18360;
}

test "fpl percent places a household against the poverty line" {
    # $48,000 for a household of three against a $27,320 line.
    assert fpl_percent(48000.0, 3) == 176;
    assert fpl_percent(27320.0, 3) == 100;
}

test "a verified policy produces a quotable, checkable claim" {
    ctx = assistance_context(48000.0, 3, 9000.0, "mass_general_brigham");
    assert ctx.hospital == "Mass General Brigham";
    assert ctx.fpl_pct == 176;
    assert "under 300%" in ctx.qualifies_hint;
    assert "60% or more" in ctx.quotable;
}

test "the hardship route fires when the bill is large relative to income" {
    # $30k of bills on $60k income is 50%, over MGB's 40% hardship threshold.
    ctx = assistance_context(60000.0, 2, 30000.0, "mass_general_brigham");
    assert "hardship" in ctx.hardship_hint;
    assert "50%" in ctx.hardship_hint;
}

test "an unknown hospital falls back to national priors" {
    ctx = assistance_context(48000.0, 3, 5000.0, "some_hospital_we_have_not_read");
    assert ctx.hospital == "";
    assert "most common free-care threshold is 200%" in ctx.qualifies_hint;
    assert len(ctx.levers) > 0;
}
