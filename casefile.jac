"""Load a patient case file (a single markdown document) into agent context.

A case file describes one patient's situation in prose - bill, income, insurance,
hardship, goals. Its full text is passed to the agent so it argues from real
specifics. Used by main.jac (via --case) and by the telephony layer.
"""
import argparse;
import os;
import sys;

import from agent { PatientCase }

glob _ROOT: str = os.path.dirname(os.path.abspath(__file__));
glob DEFAULT_CASE: str = os.path.join(_ROOT, "cases", "jordan-rivera.md");


"""Use the first level-1 markdown heading (`# Name`) as the display name."""
def _name_from_markdown(text: str, fallback: str = "the patient") -> str {
    for line in text.splitlines() {
        stripped = line.strip();
        if stripped.startswith("# ") {
            return stripped[2:].strip() or fallback;
        }
    }
    return fallback;
}


"""Read a markdown case file into a PatientCase."""
def load_case(path: str) -> PatientCase {
    with open(path, "r", encoding="utf-8") as f {
        text = f.read();
    }
    return PatientCase(name=_name_from_markdown(text), notes=text);
}


"""Build a PatientCase from --case on the command line (defaults bundled)."""
def case_from_argv() -> PatientCase {
    p = argparse.ArgumentParser(
        prog="jac run main.jac --",
        description="Run a negotiation for the patient described in a markdown case file."
    );
    p.add_argument(
        "--case",
        default=DEFAULT_CASE,
        help=f"Path to a markdown case file (default: {os.path.relpath(DEFAULT_CASE, _ROOT)})."
    );
    p.add_argument(
        "--hospital",
        default="Bay Area General",
        help="Hospital name to negotiate against (default: Bay Area General, matching the bundled demo case). "
             "Run with the same name repeatedly to see cross-call learning in action."
    );
    # jac leaves sys.argv as [script, *user_args]; argparse reads [1:] by default.
    # argparse.Namespace attribute access is untyped (any) - cast at the boundary.
    a = p.parse_args();
    case_path = a.case as str;
    if not os.path.exists(case_path) {
        raise SystemExit(f"Case file not found: {case_path}");
    }
    return load_case(case_path);
}


"""Read --hospital from the command line (see case_from_argv's --hospital)."""
def hospital_from_argv() -> str {
    p = argparse.ArgumentParser(add_help=False);
    p.add_argument("--hospital", default="Bay Area General");
    # parse_known_args ignores --case (and anything else) rather than erroring on it -
    # this parser only cares about --hospital.
    (a, _rest) = p.parse_known_args();
    return a.hospital as str;
}
