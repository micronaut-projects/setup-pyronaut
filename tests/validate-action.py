#!/usr/bin/env python3
"""Static checks for action.yml that a YAML parser alone will not catch.

A composite action fails at run time, in someone else's workflow, when it
references a step output that does not exist or has not run yet — the
expression just resolves to the empty string and the failure surfaces much
later as a missing path or an empty cache key. These checks catch that here.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
ACTION = ROOT / "action.yml"

EXPRESSION = re.compile(r"\$\{\{\s*(.*?)\s*\}\}", re.DOTALL)
STEP_REFERENCE = re.compile(r"steps\.([A-Za-z0-9_-]+)\.outputs\.([A-Za-z0-9_-]+)")
INPUT_REFERENCE = re.compile(r"inputs\.([A-Za-z0-9_-]+)")

# Outputs set by the third-party actions this composite uses.
EXTERNAL_STEP_OUTPUTS = {"cache-hit"}

errors: list[str] = []


def error(message: str) -> None:
    errors.append(message)


def walk(node: object, path: str = "") -> list[tuple[str, str]]:
    """Yield every (yaml-path, string) pair in the document."""
    found: list[tuple[str, str]] = []
    if isinstance(node, dict):
        for key, value in node.items():
            found.extend(walk(value, f"{path}.{key}"))
    elif isinstance(node, list):
        for index, value in enumerate(node):
            found.extend(walk(value, f"{path}[{index}]"))
    elif isinstance(node, str):
        found.append((path, node))
    return found


def outputs_produced_by(script: Path) -> set[str]:
    """The output names a step script sets, read from its `set_output` calls."""
    if not script.is_file():
        return set()
    return set(re.findall(r'set_output\s+"([A-Za-z0-9_-]+)"', script.read_text(encoding="utf-8")))


def main() -> int:
    action = yaml.safe_load(ACTION.read_text(encoding="utf-8"))

    declared_inputs = set(action.get("inputs") or {})
    steps = action["runs"]["steps"]

    # Every step's declared id, in order, so a reference can be checked against
    # the steps that precede it.
    step_ids: list[str] = []
    step_scripts: dict[str, Path] = {}
    seen_ids: set[str] = set()

    for index, step in enumerate(steps):
        step_id = step.get("id")
        if step_id is None:
            continue
        if step_id in seen_ids:
            error(f"step {index} reuses the id {step_id!r}")
        seen_ids.add(step_id)
        step_ids.append(step_id)
        run = step.get("run", "")
        match = re.search(r"scripts/([A-Za-z0-9_.-]+\.sh)", run)
        if match:
            step_scripts[step_id] = ROOT / "scripts" / match.group(1)

    # -- references resolve, and only backwards ------------------------------
    available: set[str] = set()
    for index, step in enumerate(steps):
        label = step.get("name") or step.get("id") or f"step {index}"
        for yaml_path, value in walk(step, f"steps[{index}]"):
            for expression in EXPRESSION.findall(value):
                for referenced_id, output in STEP_REFERENCE.findall(expression):
                    if referenced_id not in seen_ids:
                        error(f"{label}: references unknown step id {referenced_id!r} at {yaml_path}")
                    elif referenced_id not in available:
                        error(
                            f"{label}: references steps.{referenced_id}.outputs.{output} "
                            f"before that step runs ({yaml_path})"
                        )
                    elif referenced_id in step_scripts:
                        produced = outputs_produced_by(step_scripts[referenced_id])
                        if produced and output not in produced:
                            error(
                                f"{label}: steps.{referenced_id}.outputs.{output} is never set by "
                                f"{step_scripts[referenced_id].name} ({yaml_path})"
                            )
                    elif output not in EXTERNAL_STEP_OUTPUTS:
                        error(f"{label}: unknown output {output!r} on external step {referenced_id!r}")
                for name in INPUT_REFERENCE.findall(expression):
                    if name not in declared_inputs:
                        error(f"{label}: references undeclared input {name!r} at {yaml_path}")
        if step.get("id"):
            available.add(step["id"])

    # -- the action's own outputs --------------------------------------------
    for name, definition in (action.get("outputs") or {}).items():
        for expression in EXPRESSION.findall(definition.get("value", "")):
            for referenced_id, output in STEP_REFERENCE.findall(expression):
                if referenced_id not in seen_ids:
                    error(f"output {name!r}: references unknown step id {referenced_id!r}")
                elif referenced_id in step_scripts:
                    produced = outputs_produced_by(step_scripts[referenced_id])
                    if produced and output not in produced:
                        error(
                            f"output {name!r}: steps.{referenced_id}.outputs.{output} is never set by "
                            f"{step_scripts[referenced_id].name}"
                        )

    # -- every step script exists and is executable --------------------------
    for step_id, script in step_scripts.items():
        if not script.is_file():
            error(f"step {step_id!r} runs {script.name}, which does not exist")
        elif not script.stat().st_mode & 0o111:
            error(f"{script.name} is not executable")

    # -- inputs are documented ------------------------------------------------
    readme = (ROOT / "README.md").read_text(encoding="utf-8")
    for name in sorted(declared_inputs):
        if f"`{name}`" not in readme:
            error(f"input {name!r} is not documented in README.md")
    for name in sorted(action.get("outputs") or {}):
        if f"`{name}`" not in readme:
            error(f"output {name!r} is not documented in README.md")

    # -- third-party actions are pinned to a commit ---------------------------
    for index, step in enumerate(steps):
        uses = step.get("uses")
        if uses and not re.search(r"@[0-9a-f]{40}$", uses):
            error(f"step {index} uses {uses!r}, which is not pinned to a full commit sha")

    if errors:
        for message in errors:
            print(f"action.yml: {message}", file=sys.stderr)
        print(f"\n{len(errors)} problem(s) found.", file=sys.stderr)
        return 1

    print(
        f"action.yml is consistent: {len(declared_inputs)} inputs, "
        f"{len(action.get('outputs') or {})} outputs, {len(steps)} steps."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
