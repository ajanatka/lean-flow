#!/usr/bin/env python3
"""Generate deterministic Codex custom-agent TOML from Lean Flow sources.

The generator is intentionally standard-library only. It writes exclusively to
the required ``--output`` directory and refuses live Claude/Codex home targets.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import re
import sys
from typing import Iterable


MODEL_MAP = {
    "haiku": "gpt-5.6-luna",
    "sonnet": "gpt-5.6-terra",
    "opus": "gpt-5.6-sol",
}

SEMANTIC_TIER_MAP = {
    "haiku": "fast",
    "sonnet": "balanced",
    "opus": "frontier",
}

SUPPORTED_EFFORTS = {"low", "medium", "high"}
AGENT_NAME_PATTERN = re.compile(r"^lf-[a-z0-9]+(?:-[a-z0-9]+)*$")
REVIEW_ARTIFACT_AGENT_NAMES = {
    "lf-data-integrity-guardian",
    "lf-learnings-researcher",
}

LANE_NAMES = {
    "advisor": "lf-advisor",
    "alert-writer": "lf-alert-writer",
    "docs-writer": "lf-docs-writer",
    "learning-writer": "lf-learning-writer",
    "linear-worker": "lf-linear-worker",
    "scan-worker": "lf-scan-worker",
    "sonnet-worker": "lf-implementation-worker",
}

LANE_CONTRACTS = {
    "advisor": ("read", ["read", "search", "shell-read"]),
    "alert-writer": (
        "external-write",
        ["read", "search", "workspace-edit", "shell", "observability-write"],
    ),
    "docs-writer": ("workspace-write", ["read", "search", "workspace-edit", "shell"]),
    "learning-writer": ("workspace-write", ["read", "search", "workspace-edit", "shell"]),
    "linear-worker": ("external-write", ["read", "search", "issue-tracker-write"]),
    "scan-worker": ("read", ["read", "search", "shell-read"]),
    "sonnet-worker": ("workspace-write", ["read", "search", "workspace-edit", "shell"]),
}

CONTRACT_VERSION = 1


@dataclass(frozen=True)
class Agent:
    codex_name: str
    claude_name: str
    description: str
    instructions: str
    source: str
    source_sha256: str
    source_kind: str
    claude_model: str
    semantic_tier: str
    codex_model: str
    effort: str
    permission_class: str
    tool_classes: tuple[str, ...]


def _parse_scalar(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] == '"':
        return json.loads(value)
    if len(value) >= 2 and value[0] == value[-1] == "'":
        return value[1:-1].replace("''", "'")
    return value


def _parse_prompt_bytes(path: Path, content: bytes) -> tuple[dict[str, str], str]:
    """Parse the flat YAML frontmatter subset used by canonical prompts."""
    text = content.decode("utf-8")
    if not text.startswith("---\n"):
        raise ValueError(f"{path}: missing YAML frontmatter")
    try:
        raw_frontmatter, body = text[4:].split("\n---", 1)
    except ValueError as exc:
        raise ValueError(f"{path}: unterminated YAML frontmatter") from exc
    body = body.removeprefix("\n").rstrip() + "\n"
    fields: dict[str, str] = {}
    for line_number, line in enumerate(raw_frontmatter.splitlines(), start=2):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if ":" not in line or line.startswith((" ", "\t")):
            raise ValueError(f"{path}:{line_number}: unsupported frontmatter shape")
        key, value = line.split(":", 1)
        key = key.strip()
        if key in fields:
            raise ValueError(f"{path}:{line_number}: duplicate frontmatter field {key!r}")
        fields[key] = _parse_scalar(value)
    required = {"name", "description", "model", "effort"}
    missing = required - fields.keys()
    if missing:
        raise ValueError(f"{path}: missing frontmatter fields: {', '.join(sorted(missing))}")
    if fields["model"] not in MODEL_MAP:
        raise ValueError(f"{path}: unsupported model tier {fields['model']!r}")
    if fields["effort"] not in SUPPORTED_EFFORTS:
        raise ValueError(f"{path}: unsupported effort {fields['effort']!r}")
    return fields, body


def parse_prompt(path: Path) -> tuple[dict[str, str], str]:
    return _parse_prompt_bytes(path, path.read_bytes())


def _is_review_artifact_agent(name: str) -> bool:
    return name.endswith("-reviewer") or name in REVIEW_ARTIFACT_AGENT_NAMES


def _persona_tool_classes(name: str, tools: str) -> tuple[str, ...]:
    classes = {"read", "search"}
    if _is_review_artifact_agent(name):
        classes.add("review-artifact-write")
    if "Bash" in tools:
        classes.add("shell-read")
    if "Web" in tools or "context7" in tools:
        classes.add("web")
    if "ToolSearch" in tools:
        classes.add("tool-discovery")
    return tuple(sorted(classes))


def validate_canonical_layout(root: Path) -> None:
    persona_paths = list((root / "plugins" / "lean-flow" / "agents").glob("*.agent.md"))
    lane_paths = list((root / "harness" / "agents").glob("*.md"))
    skill_dirs = [
        path
        for path in (root / "plugins" / "lean-flow" / "skills").iterdir()
        if path.is_dir()
    ]
    if len(persona_paths) != 31:
        raise ValueError(f"expected 31 canonical personas, found {len(persona_paths)}")
    if len(lane_paths) != 7:
        raise ValueError(f"expected 7 canonical lanes, found {len(lane_paths)}")
    if len(skill_dirs) != 16:
        raise ValueError(f"expected 16 canonical skills, found {len(skill_dirs)}")
    missing_skills = sorted(
        path.relative_to(root).as_posix()
        for path in skill_dirs
        if not (path / "SKILL.md").is_file()
    )
    if missing_skills:
        raise ValueError(f"canonical skills missing SKILL.md: {', '.join(missing_skills)}")


def build_catalog(root: Path) -> list[Agent]:
    root = root.resolve()
    validate_canonical_layout(root)
    agents: list[Agent] = []

    persona_dir = root / "plugins" / "lean-flow" / "agents"
    for path in sorted(persona_dir.glob("*.agent.md")):
        content = path.read_bytes()
        fields, body = _parse_prompt_bytes(path, content)
        name = fields["name"]
        if not AGENT_NAME_PATTERN.fullmatch(name):
            raise ValueError(f"{path}: invalid namespaced persona name {name!r}")
        agents.append(
            Agent(
                codex_name=name,
                claude_name=name,
                description=fields["description"],
                instructions=body,
                source=path.relative_to(root).as_posix(),
                source_sha256=hashlib.sha256(content).hexdigest(),
                source_kind="persona",
                claude_model=fields["model"],
                semantic_tier=SEMANTIC_TIER_MAP[fields["model"]],
                codex_model=MODEL_MAP[fields["model"]],
                effort=fields["effort"],
                permission_class=(
                    "read-with-run-artifact-write" if _is_review_artifact_agent(name) else "read"
                ),
                tool_classes=_persona_tool_classes(name, fields.get("tools", "")),
            )
        )

    lane_dir = root / "harness" / "agents"
    for path in sorted(lane_dir.glob("*.md")):
        content = path.read_bytes()
        fields, body = _parse_prompt_bytes(path, content)
        claude_name = fields["name"]
        try:
            codex_name = LANE_NAMES[claude_name]
            permission_class, tool_classes = LANE_CONTRACTS[claude_name]
        except KeyError as exc:
            raise ValueError(f"{path}: lane needs an explicit cross-client mapping") from exc
        agents.append(
            Agent(
                codex_name=codex_name,
                claude_name=claude_name,
                description=fields["description"],
                instructions=body,
                source=path.relative_to(root).as_posix(),
                source_sha256=hashlib.sha256(content).hexdigest(),
                source_kind="lane",
                claude_model=fields["model"],
                semantic_tier=SEMANTIC_TIER_MAP[fields["model"]],
                codex_model=MODEL_MAP[fields["model"]],
                effort=fields["effort"],
                permission_class=permission_class,
                tool_classes=tuple(tool_classes),
            )
        )

    agents.sort(key=lambda agent: agent.codex_name)
    names = [agent.codex_name for agent in agents]
    if len(names) != len(set(names)):
        raise ValueError("generated Codex agent names are not unique")
    if len(agents) != 38:
        raise ValueError(f"expected 38 canonical agents, found {len(agents)}")
    return agents


def normalize_codex_instructions(instructions: str) -> str:
    """Translate exact Claude web-tool names into Codex-native capabilities."""
    return instructions.replace("WebSearch", "native web search").replace(
        "WebFetch", "native web fetch/open"
    )


def _execution_contract(agent: Agent) -> str:
    tools = ", ".join(agent.tool_classes)
    artifact_boundary = ""
    if agent.permission_class == "read-with-run-artifact-write":
        artifact_boundary = (
            "- The only permitted project write is the explicitly assigned, run-scoped "
            "review artifact. Do not edit source files or write anywhere else.\n"
        )
    return (
        "\n## Codex execution contract\n\n"
        f"- Semantic model tier: `{agent.semantic_tier}`; route to `{agent.codex_model}` "
        f"with `{agent.effort}` reasoning effort when the runtime supports per-agent routing.\n"
        f"- Tool classes: {tools}. Map these semantic classes to the native tools available "
        "in the current Codex runtime; do not assume Claude tool names exist.\n"
        f"- Permission class: `{agent.permission_class}`. Stay within this boundary even if "
        "the surrounding session has broader permissions. External writes require explicit "
        "task authority and the runtime's normal confirmation policy.\n"
        f"{artifact_boundary}"
        "- Follow repository instructions and return bounded evidence. Stop and ask rather "
        "than inventing unavailable tools, permissions, requirements, or external state.\n"
        f"- Canonical source: `{agent.source}` (`sha256:{agent.source_sha256}`).\n"
    )


def _toml_string(value: str) -> str:
    # JSON basic strings and TOML basic strings share the escapes used here.
    # Keep non-ASCII code points literal: JSON's surrogate-pair \u escapes are
    # not valid TOML Unicode scalar escapes for characters outside the BMP.
    return json.dumps(value, ensure_ascii=False)


def render_agent(agent: Agent) -> bytes:
    instructions = normalize_codex_instructions(agent.instructions).rstrip() + "\n" + _execution_contract(agent)
    text = (
        f"name = {_toml_string(agent.codex_name)}\n"
        f"description = {_toml_string(agent.description)}\n"
        f"developer_instructions = {_toml_string(instructions)}\n"
    )
    return text.encode("utf-8")


def render_manifest(agents: Iterable[Agent]) -> bytes:
    entries = []
    for agent in agents:
        entries.append(
            {
                "claude_name": agent.claude_name,
                "claude_model": agent.claude_model,
                "codex_name": agent.codex_name,
                "codex_model": agent.codex_model,
                "effort": agent.effort,
                "permission_class": agent.permission_class,
                "semantic_tier": agent.semantic_tier,
                "source": agent.source,
                "source_kind": agent.source_kind,
                "source_sha256": agent.source_sha256,
                "tool_classes": list(agent.tool_classes),
            }
        )
    document = {
        "schema_version": CONTRACT_VERSION,
        "generated_by": "tools/generate_codex_agents.py",
        "generated_count": len(entries),
        "model_mapping": MODEL_MAP,
        "semantic_tier_mapping": SEMANTIC_TIER_MAP,
        "agents": entries,
    }
    return (json.dumps(document, indent=2, sort_keys=True) + "\n").encode("utf-8")


def desired_files(root: Path) -> dict[Path, bytes]:
    agents = build_catalog(root)
    files = {
        Path("agents") / "lean-flow" / f"{agent.codex_name}.toml": render_agent(agent)
        for agent in agents
    }
    files[Path("lean-flow-routing.json")] = render_manifest(agents)
    return files


def validate_output_target(output: Path) -> Path:
    output = output.expanduser().resolve()
    home = Path.home().resolve()
    live_homes = {home / ".claude", home / ".codex"}
    if codex_home := os.environ.get("CODEX_HOME"):
        live_homes.add(Path(codex_home).expanduser().resolve())
    for live_home in live_homes:
        if output.is_relative_to(live_home):
            raise ValueError(
                f"refusing live runtime target {output}; generate in a disposable directory and install explicitly"
            )
    return output


def managed_path(output: Path, relative_path: Path) -> Path:
    """Resolve one managed path without permitting traversal or child symlinks."""
    if relative_path.is_absolute() or ".." in relative_path.parts:
        raise ValueError(f"managed path escapes output root: {relative_path}")
    current = output
    for part in relative_path.parts:
        current /= part
        if current.is_symlink():
            raise ValueError(f"managed path contains symlink: {current}")
    if not current.resolve().is_relative_to(output):
        raise ValueError(f"managed path escapes output root: {relative_path}")
    return current


def check_output(output: Path, expected: dict[Path, bytes]) -> list[str]:
    drift: list[str] = []
    managed_dir = managed_path(output, Path("agents/lean-flow"))
    actual_paths = {
        path.relative_to(output)
        for path in managed_dir.glob("*.toml")
        if path.is_file()
    }
    manifest = managed_path(output, Path("lean-flow-routing.json"))
    if manifest.is_file():
        actual_paths.add(manifest.relative_to(output))
    expected_paths = set(expected)
    for path in sorted(expected_paths - actual_paths):
        drift.append(f"missing: {path}")
    for path in sorted(actual_paths - expected_paths):
        drift.append(f"unexpected: {path}")
    for path in sorted(expected_paths & actual_paths):
        if managed_path(output, path).read_bytes() != expected[path]:
            drift.append(f"changed: {path}")
    return drift


def write_output(output: Path, expected: dict[Path, bytes]) -> None:
    managed_dir = managed_path(output, Path("agents/lean-flow"))
    managed_dir.mkdir(parents=True, exist_ok=True)
    expected_agent_paths = {
        managed_path(output, path)
        for path in expected
        if path.parent == Path("agents/lean-flow")
    }
    for stale in managed_dir.glob("*.toml"):
        managed_path(output, stale.relative_to(output))
        if stale not in expected_agent_paths:
            stale.unlink()
    for relative_path, content in expected.items():
        destination = managed_path(output, relative_path)
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(content)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path, help="disposable generated-layout directory")
    parser.add_argument("--check", action="store_true", help="verify output matches canonical sources")
    args = parser.parse_args(argv)

    root = Path(__file__).resolve().parents[1]
    try:
        output = validate_output_target(args.output)
        expected = desired_files(root)
        if args.check:
            drift = check_output(output, expected)
            if drift:
                print("generated adapter drift detected:", file=sys.stderr)
                for finding in drift:
                    print(f"  {finding}", file=sys.stderr)
                return 1
            print(f"OK: {len(expected) - 1} agents match canonical sources")
            return 0

        write_output(output, expected)
        print(f"Generated {len(expected) - 1} Codex agents in {output}")
        return 0
    except (OSError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
