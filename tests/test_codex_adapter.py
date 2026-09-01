#!/usr/bin/env python3
"""Contract tests for Lean Flow's generated Codex agent adapter."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import tomllib
import unittest


ROOT = Path(__file__).resolve().parents[1]
GENERATOR = ROOT / "tools" / "generate_codex_agents.py"
PERSONAS = ROOT / "plugins" / "lean-flow" / "agents"
SKILLS = ROOT / "plugins" / "lean-flow" / "skills"
LANES = ROOT / "harness" / "agents"
PLUGIN_MANIFEST = ROOT / "plugins" / "lean-flow" / ".codex-plugin" / "plugin.json"
PRIVATE_IDENTIFIERS = ("hano", "eamesly", "andrew")


def load_generator():
    spec = importlib.util.spec_from_file_location("generate_codex_agents", GENERATOR)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {GENERATOR}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class CodexAdapterContractTest(unittest.TestCase):
    def test_canonical_catalog_counts_and_resources(self) -> None:
        self.assertEqual(31, len(list(PERSONAS.glob("*.agent.md"))))
        skill_dirs = sorted(path for path in SKILLS.iterdir() if path.is_dir())
        self.assertEqual(16, len(skill_dirs))
        self.assertTrue(all((path / "SKILL.md").is_file() for path in skill_dirs))
        self.assertEqual(7, len(list(LANES.glob("*.md"))))

        manifest = json.loads(PLUGIN_MANIFEST.read_text(encoding="utf-8"))
        self.assertEqual("./skills/", manifest["skills"])
        claude_manifest = json.loads(
            (ROOT / "plugins" / "lean-flow" / ".claude-plugin" / "plugin.json").read_text(
                encoding="utf-8"
            )
        )
        marketplace = json.loads(
            (ROOT / ".claude-plugin" / "marketplace.json").read_text(encoding="utf-8")
        )
        self.assertEqual("1.3.1", manifest["version"])
        self.assertEqual(manifest["version"], claude_manifest["version"])
        self.assertEqual(manifest["version"], marketplace["plugins"][0]["version"])

    def test_generation_is_deterministic_and_portable(self) -> None:
        with tempfile.TemporaryDirectory() as first, tempfile.TemporaryDirectory() as second:
            for output in (first, second):
                result = subprocess.run(
                    [sys.executable, str(GENERATOR), "--output", output],
                    cwd=ROOT,
                    text=True,
                    capture_output=True,
                )
                self.assertEqual(0, result.returncode, result.stderr)

            first_root, second_root = Path(first), Path(second)
            first_files = sorted(path.relative_to(first_root) for path in first_root.rglob("*") if path.is_file())
            second_files = sorted(path.relative_to(second_root) for path in second_root.rglob("*") if path.is_file())
            self.assertEqual(first_files, second_files)
            self.assertEqual(
                [hashlib.sha256((first_root / path).read_bytes()).hexdigest() for path in first_files],
                [hashlib.sha256((second_root / path).read_bytes()).hexdigest() for path in second_files],
            )

    def test_generated_agents_and_routing_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as output:
            subprocess.run(
                [sys.executable, str(GENERATOR), "--output", output],
                cwd=ROOT,
                check=True,
                capture_output=True,
                text=True,
            )
            output_root = Path(output)
            agent_files = sorted((output_root / "agents" / "lean-flow").glob("*.toml"))
            self.assertEqual(38, len(agent_files))

            parsed = [tomllib.loads(path.read_text(encoding="utf-8")) for path in agent_files]
            names = [entry["name"] for entry in parsed]
            self.assertEqual(38, len(set(names)))
            self.assertTrue(all(name.startswith("lf-") for name in names))
            self.assertIn("lf-implementation-worker", names)
            self.assertNotIn("sonnet-worker", names)
            self.assertTrue(
                all(set(entry) == {"name", "description", "developer_instructions"} for entry in parsed)
            )

            routing = json.loads((output_root / "lean-flow-routing.json").read_text(encoding="utf-8"))
            self.assertEqual(38, len(routing["agents"]))
            by_alias = {entry["claude_name"]: entry for entry in routing["agents"]}
            self.assertEqual("lf-implementation-worker", by_alias["sonnet-worker"]["codex_name"])
            self.assertEqual("gpt-5.6-luna", by_alias["scan-worker"]["codex_model"])
            self.assertEqual("gpt-5.6-terra", by_alias["sonnet-worker"]["codex_model"])
            self.assertEqual("gpt-5.6-sol", by_alias["advisor"]["codex_model"])
            self.assertEqual("fast", by_alias["scan-worker"]["semantic_tier"])
            self.assertEqual("balanced", by_alias["sonnet-worker"]["semantic_tier"])
            self.assertEqual("frontier", by_alias["advisor"]["semantic_tier"])
            self.assertEqual("sonnet", by_alias["sonnet-worker"]["claude_model"])
            self.assertTrue(all(len(entry["source_sha256"]) == 64 for entry in routing["agents"]))
            expected_lanes = {
                "advisor": ("read", ["read", "search", "shell-read"]),
                "alert-writer": (
                    "external-write",
                    ["read", "search", "workspace-edit", "shell", "observability-write"],
                ),
                "docs-writer": (
                    "workspace-write",
                    ["read", "search", "workspace-edit", "shell"],
                ),
                "learning-writer": (
                    "workspace-write",
                    ["read", "search", "workspace-edit", "shell"],
                ),
                "linear-worker": ("external-write", ["read", "search", "issue-tracker-write"]),
                "scan-worker": ("read", ["read", "search", "shell-read"]),
                "sonnet-worker": (
                    "workspace-write",
                    ["read", "search", "workspace-edit", "shell"],
                ),
            }
            for name, (permission, tools) in expected_lanes.items():
                self.assertEqual(permission, by_alias[name]["permission_class"], name)
                self.assertEqual(tools, by_alias[name]["tool_classes"], name)

            artifact_agents = {"lf-data-integrity-guardian", "lf-learnings-researcher"}
            for path in sorted(PERSONAS.glob("*.agent.md")):
                fields, _ = load_generator().parse_prompt(path)
                name = fields["name"]
                expected_tools = {"read", "search"}
                if "Bash" in fields.get("tools", ""):
                    expected_tools.add("shell-read")
                if "Web" in fields.get("tools", "") or "context7" in fields.get("tools", ""):
                    expected_tools.add("web")
                if "ToolSearch" in fields.get("tools", ""):
                    expected_tools.add("tool-discovery")
                if name.endswith("-reviewer") or name in artifact_agents:
                    expected_permission = "read-with-run-artifact-write"
                    expected_tools.add("review-artifact-write")
                else:
                    expected_permission = "read"
                self.assertEqual(expected_permission, by_alias[name]["permission_class"], name)
                self.assertEqual(sorted(expected_tools), by_alias[name]["tool_classes"], name)

    def test_check_mode_detects_drift(self) -> None:
        with tempfile.TemporaryDirectory() as output:
            subprocess.run(
                [sys.executable, str(GENERATOR), "--output", output],
                cwd=ROOT,
                check=True,
            )
            clean = subprocess.run(
                [sys.executable, str(GENERATOR), "--output", output, "--check"],
                cwd=ROOT,
                text=True,
                capture_output=True,
            )
            self.assertEqual(0, clean.returncode, clean.stderr)
            generated = next((Path(output) / "agents" / "lean-flow").glob("*.toml"))
            generated.write_text(generated.read_text(encoding="utf-8") + "\n# drift\n", encoding="utf-8")
            drifted = subprocess.run(
                [sys.executable, str(GENERATOR), "--output", output, "--check"],
                cwd=ROOT,
                text=True,
                capture_output=True,
            )
            self.assertNotEqual(0, drifted.returncode)
            self.assertIn("drift", drifted.stderr.lower())

            generated.unlink()
            missing = subprocess.run(
                [sys.executable, str(GENERATOR), "--output", output, "--check"],
                cwd=ROOT,
                text=True,
                capture_output=True,
            )
            self.assertNotEqual(0, missing.returncode)
            self.assertIn("missing:", missing.stderr)

            unexpected = Path(output) / "agents" / "lean-flow" / "lf-unexpected.toml"
            unexpected.write_text('name = "lf-unexpected"\n', encoding="utf-8")
            extra = subprocess.run(
                [sys.executable, str(GENERATOR), "--output", output, "--check"],
                cwd=ROOT,
                text=True,
                capture_output=True,
            )
            self.assertNotEqual(0, extra.returncode)
            self.assertIn("unexpected:", extra.stderr)

    def test_source_hashes_match_canonical_bytes(self) -> None:
        module = load_generator()
        catalog = module.build_catalog(ROOT)
        self.assertEqual(38, len(catalog))
        for agent in catalog:
            source = ROOT / agent.source
            self.assertEqual(hashlib.sha256(source.read_bytes()).hexdigest(), agent.source_sha256)

    def test_generated_instructions_retain_normalized_canonical_body(self) -> None:
        module = load_generator()
        with tempfile.TemporaryDirectory() as output:
            subprocess.run(
                [sys.executable, str(GENERATOR), "--output", output],
                cwd=ROOT,
                check=True,
                capture_output=True,
                text=True,
            )
            for agent in module.build_catalog(ROOT):
                source_text = (ROOT / agent.source).read_text(encoding="utf-8")
                canonical_body = source_text[4:].split("\n---", 1)[1].removeprefix("\n").rstrip()
                expected_body = canonical_body.replace("WebSearch", "native web search").replace(
                    "WebFetch", "native web fetch/open"
                )
                generated = tomllib.loads(
                    (Path(output) / "agents" / "lean-flow" / f"{agent.codex_name}.toml").read_text(
                        encoding="utf-8"
                    )
                )["developer_instructions"]
                actual_body, marker = generated.split("\n## Codex execution contract\n", 1)
                self.assertEqual(expected_body, actual_body.rstrip(), agent.codex_name)
                self.assertIn(agent.source_sha256, marker)

    def test_public_cross_client_artifacts_have_no_private_identifiers(self) -> None:
        paths = [ROOT / "docs" / "cross-client-contract.md", GENERATOR, PLUGIN_MANIFEST]
        with tempfile.TemporaryDirectory() as output:
            subprocess.run(
                [sys.executable, str(GENERATOR), "--output", output],
                cwd=ROOT,
                check=True,
                capture_output=True,
                text=True,
            )
            paths.extend(path for path in Path(output).rglob("*") if path.is_file())
            findings = []
            for path in paths:
                lower = path.read_text(encoding="utf-8").lower()
                for identifier in PRIVATE_IDENTIFIERS:
                    if identifier in lower:
                        findings.append(f"{path} contains {identifier}")
            self.assertEqual([], findings)

    def test_generated_instructions_do_not_bind_to_claude_runtime_tools(self) -> None:
        forbidden = (
            "ToolSearch",
            "Skill tool",
            "WebSearch",
            "WebFetch",
            "mcp__plugin_",
            "CLAUDE_ALLOW_",
            "/Users/andrew",
        )
        with tempfile.TemporaryDirectory() as output:
            subprocess.run(
                [sys.executable, str(GENERATOR), "--output", output],
                cwd=ROOT,
                check=True,
                capture_output=True,
                text=True,
            )
            findings = []
            for path in sorted((Path(output) / "agents" / "lean-flow").glob("*.toml")):
                instructions = tomllib.loads(path.read_text(encoding="utf-8"))["developer_instructions"]
                for marker in forbidden:
                    if marker in instructions:
                        findings.append(f"{path.name} contains {marker}")
            self.assertEqual([], findings)

    def test_skills_use_portable_references_and_current_model_tiers(self) -> None:
        skill_text = "\n".join(
            path.read_text(encoding="utf-8")
            for path in sorted(SKILLS.rglob("*.md"))
        )
        self.assertNotIn("@./", skill_text)
        self.assertNotIn("gpt-5.4-mini", skill_text)
        self.assertNotIn("gpt-5.4-nano", skill_text)
        self.assertIn("Claude Code uses Opus and Codex uses GPT-5.6 Sol", skill_text)
        self.assertIn("request_user_input", skill_text)

        for relative_path in (
            "lf-doc-review/references/subagent-template.md",
            "lf-doc-review/references/findings-schema.json",
            "lf-code-review/references/persona-catalog.md",
            "lf-code-review/references/subagent-template.md",
            "lf-code-review/references/diff-scope.md",
            "lf-code-review/references/findings-schema.json",
            "lf-code-review/references/review-output-template.md",
        ):
            self.assertTrue((SKILLS / relative_path).is_file(), relative_path)

    def test_disposable_generation_never_mutates_live_homes(self) -> None:
        with tempfile.TemporaryDirectory() as fake_home, tempfile.TemporaryDirectory() as output:
            env = {**os.environ, "HOME": fake_home, "CODEX_HOME": str(Path(fake_home) / ".codex")}
            subprocess.run(
                [sys.executable, str(GENERATOR), "--output", output],
                cwd=ROOT,
                env=env,
                check=True,
            )
            self.assertFalse((Path(fake_home) / ".claude").exists())
            self.assertFalse((Path(fake_home) / ".codex").exists())
            self.assertTrue((Path(output) / "agents" / "lean-flow").is_dir())

    def test_live_and_custom_codex_homes_are_refused(self) -> None:
        with tempfile.TemporaryDirectory() as fake_home, tempfile.TemporaryDirectory() as custom_home:
            env = {**os.environ, "HOME": fake_home, "CODEX_HOME": custom_home}
            for target in (Path(fake_home) / ".codex" / "generated", Path(custom_home) / "generated"):
                result = subprocess.run(
                    [sys.executable, str(GENERATOR), "--output", str(target)],
                    cwd=ROOT,
                    env=env,
                    text=True,
                    capture_output=True,
                )
                self.assertEqual(2, result.returncode)
                self.assertIn("refusing live runtime target", result.stderr)
                self.assertFalse(target.exists())

    def test_child_symlink_and_invalid_agent_name_fail_closed(self) -> None:
        module = load_generator()
        with tempfile.TemporaryDirectory() as output, tempfile.TemporaryDirectory() as sentinel:
            output_root = Path(output)
            (output_root / "agents").symlink_to(sentinel, target_is_directory=True)
            result = subprocess.run(
                [sys.executable, str(GENERATOR), "--output", output],
                cwd=ROOT,
                text=True,
                capture_output=True,
            )
            self.assertEqual(2, result.returncode)
            self.assertIn("symlink", result.stderr)
            self.assertEqual([], list(Path(sentinel).rglob("*")))

        persona = next(PERSONAS.glob("*.agent.md"))
        fields, _ = module.parse_prompt(persona)
        bad_name = "lf-/../../escape"
        with tempfile.TemporaryDirectory() as fixture:
            root = Path(fixture)
            source = root / "plugins" / "lean-flow" / "agents"
            lanes = root / "harness" / "agents"
            skills = root / "plugins" / "lean-flow" / "skills"
            source.mkdir(parents=True)
            lanes.mkdir(parents=True)
            skills.mkdir(parents=True)
            for path in PERSONAS.glob("*.agent.md"):
                target = source / path.name
                target.write_bytes(path.read_bytes())
            for path in LANES.glob("*.md"):
                (lanes / path.name).write_bytes(path.read_bytes())
            for path in SKILLS.iterdir():
                target = skills / path.name
                target.mkdir()
                (target / "SKILL.md").write_text("fixture\n", encoding="utf-8")
            bad_source = source / persona.name
            original = bad_source.read_text(encoding="utf-8")
            bad_source.write_text(original.replace(f"name: {fields['name']}", f"name: {bad_name}", 1))
            with self.assertRaisesRegex(ValueError, "invalid namespaced persona name"):
                module.build_catalog(root)

    def test_invalid_effort_and_duplicate_frontmatter_are_rejected(self) -> None:
        module = load_generator()
        with tempfile.TemporaryDirectory() as fixture:
            path = Path(fixture) / "agent.md"
            path.write_text(
                "---\nname: lf-fixture\ndescription: fixture\nmodel: sonnet\neffort: typo\n---\nbody\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ValueError, "unsupported effort"):
                module.parse_prompt(path)
            path.write_text(
                "---\nname: lf-fixture\nname: lf-duplicate\ndescription: fixture\nmodel: sonnet\neffort: medium\n---\nbody\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ValueError, "duplicate frontmatter field"):
                module.parse_prompt(path)


if __name__ == "__main__":
    unittest.main()
