"""Load a patient case file (a single markdown document) into agent context.

A case file describes one patient's situation in prose — bill, income, insurance,
hardship, goals. Its full text is passed to the agent so it argues from real
specifics. Used by main.jac (via --case) and by the telephony layer.
"""
import argparse
import os
import sys

# Make the .jac modules importable regardless of how this is launched.
_ROOT = os.path.dirname(os.path.abspath(__file__))
if _ROOT not in sys.path:
    sys.path.insert(0, _ROOT)

import jaclang  # noqa: F401 — registers the .jac import hook (dev install)
import agent

DEFAULT_CASE = os.path.join(_ROOT, "cases", "jordan-rivera.md")


def _name_from_markdown(text: str, fallback: str = "the patient") -> str:
    """Use the first level-1 markdown heading (`# Name`) as the display name."""
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("# "):
            return stripped[2:].strip() or fallback
    return fallback


def load_case(path: str):
    """Read a markdown case file into a PatientCase."""
    with open(path, "r", encoding="utf-8") as f:
        text = f.read()
    return agent.PatientCase(name=_name_from_markdown(text), notes=text)


def case_from_argv():
    """Build a PatientCase from --case on the command line (defaults bundled)."""
    p = argparse.ArgumentParser(
        prog="jac run main.jac --",
        description="Run a negotiation for the patient described in a markdown case file.",
    )
    p.add_argument(
        "--case",
        default=DEFAULT_CASE,
        help=f"Path to a markdown case file (default: {os.path.relpath(DEFAULT_CASE, _ROOT)}).",
    )
    # jac leaves sys.argv as [script, *user_args]; argparse reads [1:] by default.
    a = p.parse_args()
    if not os.path.exists(a.case):
        raise SystemExit(f"Case file not found: {a.case}")
    return load_case(a.case)
