"""Codex transport, isolated configuration, stage roles, and capture accounting."""

import functools
import hashlib
import json
import os
import re
from pathlib import Path
import shutil
import subprocess
import tempfile

from ...arm_exec import DispatchFailure, SubprocessDispatcher
from ...stage_table import STAGE_CONTRACTS as STAGE_TABLE
from ...stage_usage import StageUsage
from ...source import source_digest
from ..claude.usage_limit import UsageLimit
from . import capture

def runtime_contract(root):
    source = (Path(root) / "skills/shared/codex-runtime.md").read_text()
    marker = "```text runtime-capabilities\n"
    if source.count(marker) != 1:
        raise ValueError("canonical runtime capability contract missing or ambiguous")
    block, separator, _ = source.split(marker, 1)[1].partition("\n```")
    if not separator or not block.strip():
        raise ValueError("canonical runtime capability contract is incomplete")
    return " ".join(block.split()) + " "


HEADLESS_RUNTIME_CONTRACT = runtime_contract(Path(__file__).resolve().parents[5])


@functools.lru_cache(maxsize=None)
def model_for_tier(root, tier):
    result = subprocess.run(
        ["bash", "-c", '. "$1"; corpflow_codex_model "$2"', "resolver",
         str(Path(root) / "skills/shared/lib/codex-runtime.sh"), tier],
        capture_output=True, text=True, timeout=30, check=True)
    return result.stdout.strip()


def digest_tree(root):
    digest = hashlib.sha256()
    for path in sorted(Path(root).rglob("*")):
        if path.is_symlink():
            raise ValueError("plugin snapshots cannot contain symlinks")
        if path.is_file() and "__pycache__" not in path.parts:
            digest.update(str(path.relative_to(root)).encode() + b"\0")
            digest.update(path.read_bytes() + b"\0")
    return digest.hexdigest()


class CodexDispatcher(SubprocessDispatcher):
    def run(self, argv, prompt_text):
        stdout = super().run(argv, prompt_text)
        try:
            failed = any(e.get("type") in ("error", "turn.failed")
                         for e in capture.events(stdout))
        except capture.AccountingError:
            failed = True
        if failed:
            raise DispatchFailure("Codex emitted a failure", stdout=stdout)
        return stdout


class Provider:
    name = "codex"

    def __init__(self, plugin_root):
        self.root = Path(plugin_root)
        self.pricing = capture.load_pricing()
        self.models = {stage: model_for_tier(str(self.root), tier)
                       for stage, (_role, tier, _effort) in STAGE_TABLE.items()}
        for model in self.models.values():
            capture.price(model, 0, 0, 0, self.pricing)
        self.homes = {}
        self.snapshot = None
        self.snapshot_digest = None
        self.source_digest = None
        self.config_root = None
        self.owner_home = Path.home()
        self.arm_cwds = {}
        self.runtime_isolation = {}
        self.auth_source = None
        self.instruction_sets = {}
        self.stage_specs = {}
        self.task_skills = {}
        self.task_references = {}
        self.initial_runtime_isolation = None

    def prepare(self, arms_root, source_env=None, config_dir=None, login_runner=None):
        source_env = source_env if source_env is not None else os.environ
        source_home = Path(config_dir or source_env.get("CODEX_HOME", self.owner_home / ".codex"))
        self.auth_source = source_home.resolve()
        probe_env = {**os.environ, "CODEX_HOME": str(source_home)}
        if login_runner is None:
            result = subprocess.run(["codex", "login", "status"], env=probe_env,
                                    capture_output=True, text=True, timeout=30)
            status = result.stdout + result.stderr if result.returncode == 0 else ""
        else:
            status = login_runner()
        if "Logged in using ChatGPT" not in status:
            raise ValueError("Codex benchmark requires an existing ChatGPT login")
        auth = source_home / "auth.json"
        if not auth.is_file():
            raise ValueError("isolated Codex authentication requires file-backed ChatGPT login")
        self.config_root = Path(tempfile.mkdtemp(prefix="corpflow-codex-auth-"))
        self.snapshot = Path(arms_root) / "plugin-snapshot"
        self.snapshot.mkdir(parents=True, exist_ok=False)
        for name in ("skills", "agents", "hooks", "lib", "commands", ".claude-plugin"):
            src = self.root / name
            if src.exists():
                if any(p.is_symlink() and not p.resolve().is_relative_to(self.root.resolve())
                       for p in src.rglob("*")):
                    raise ValueError("plugin source contains an external symlink")
                shutil.copytree(src, self.snapshot / name,
                                copy_function=shutil.copy,
                                ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
        self.snapshot_digest = digest_tree(self.snapshot)
        self.source_digest = source_digest(self.root)
        for arm in ("with", "without"):
            self.arm_cwds[arm] = Path(arms_root) / arm
            home = self.config_root / arm
            home.mkdir(mode=0o700)
            target = home / "auth.json"
            target.write_bytes(auth.read_bytes())
            target.chmod(0o600)
            (self.arm_cwds[arm] / ".benchmark-home").mkdir()
            self.homes[arm] = home
            if arm == "with":
                self.select_catalogue("PL")

    def close(self):
        if self.config_root is not None:
            shutil.rmtree(self.config_root)
            self.config_root = None

    def instruction_set(self, stage, skills=None):
        skills = self.task_skills.get(stage, ()) if skills is None else skills
        references = self.task_references.get(stage, ())
        key = (stage, tuple(sorted(set(skills))), tuple(sorted(set(references))))
        if key not in self.instruction_sets:
            argv = ["bash", str(self.snapshot / "skills/worktask/scripts/brief-compose.sh"),
                    "--instruction-set", stage]
            for name in key[1]:
                argv += ["--skill", name]
            for reference in key[2]:
                argv += ["--reference", reference]
            result = subprocess.run(argv, capture_output=True, text=True, timeout=60)
            if result.returncode:
                raise ValueError("canonical stage instruction composition failed: " + result.stderr[:1000])
            self.instruction_sets[key] = json.loads(result.stdout)
        return self.instruction_sets[key]

    def select_catalogue(self, stage, skills=None):
        selected = self.instruction_set(stage, skills)
        home = self.homes["with"]
        catalogue = home / "catalogues" / (stage + "-" + selected["fingerprint"].split(":")[1][:12])
        catalogue.mkdir(parents=True, exist_ok=True)
        for name in selected["skills"]:
            target = catalogue / name
            if not target.exists():
                target.symlink_to(self.snapshot / "skills" / name, target_is_directory=True)
        link = home / "skills.next"
        if link.is_symlink():
            link.unlink()
        link.symlink_to(catalogue, target_is_directory=True)
        os.replace(link, home / "skills")
        return selected

    def verify_runtime(self, specs):
        for spec in specs.values():
            self.verify_stage(spec, "PL")
        self.initial_runtime_isolation = json.loads(json.dumps(self.runtime_isolation))

    def verify_stage(self, arm, stage):
        if isinstance(arm, str):
            if arm not in self.stage_specs:
                raise ValueError("Codex effective configuration has no registered arm")
            arm = self.stage_specs[arm]
        argv = self.build_argv(arm, stage)
        configs = []
        for index, value in enumerate(argv):
            if value == "-c":
                configs.extend(["-c", argv[index + 1]])
        result = subprocess.run(
            ["codex", "--no-daemon", "debug", "prompt-input", "-c", f'model="{self.models[stage]}"',
             *configs], env=self.env(arm.name), cwd=arm.cwd,
            capture_output=True, text=True, timeout=60)
        if result.returncode:
            raise ValueError("Codex effective configuration could not be verified")
        items = json.loads(result.stdout)
        text = "\n".join(c.get("text", "") for i in items for c in i.get("content", []))
        tools = [t.get("name") for i in items for t in i.get("tools", [])]
        count = text.count("(file: r0/")
        has_role = "Plugin root:" in text
        if any(t not in ("functions", "clock") for t in tools):
            raise ValueError("Codex runtime role, skill, or tool isolation failed")
        if "Denied filesystem reads" not in text or "Network access is restricted" not in text:
            raise ValueError("Codex filesystem or network restrictions were not applied")
        expected_skills = set(self.instruction_set(stage)["skills"]) if arm.bind_agent else set()
        observed_skills = set(re.findall(r"\(file: r0/([^/]+)/SKILL\.md\)", text))
        if count != len(expected_skills) or observed_skills != expected_skills or has_role != arm.bind_agent:
            raise ValueError("Codex runtime role, skill, or tool isolation failed")
        self.runtime_isolation.setdefault(arm.name, {})[stage] = {
            "skill_count": count, "canonical_role": has_role,
            "tools": tools, "restrictions_verified": True,
            "model_requested": self.models[stage], "effort_requested": STAGE_TABLE[stage][2]}
        context = Path(arm.cwd) / ".context"
        context.mkdir(exist_ok=True)
        (context / f"runtime-{stage}.json").write_text(
            json.dumps(self.runtime_isolation[arm.name][stage], indent=2) + "\n")

    def compose_prompt(self, arm, stage, prompt):
        if not arm.bind_agent:
            return prompt
        from ... import preamble
        import re
        task_refs = prompt
        ledger_path = Path(arm.cwd) / ".context/state.json"
        ledger = json.loads(ledger_path.read_text())
        task_refs += json.dumps((ledger.get("tasks", {}).get(stage + "0", {}).get("metadata", {})
                                 .get("context_refs", [])))
        self.task_references[stage] = tuple(sorted(set(re.findall(
            r"skills/[a-z][a-z0-9-]*/[A-Za-z0-9_./-]+(?:#[A-Za-z0-9_-]+)?", task_refs))))
        self.task_skills[stage] = tuple(sorted(set(
            re.findall(r"skills/([a-z][a-z0-9-]*)/", task_refs)
            + re.findall(r"(?:skill:\s*|\$)corpflow:([a-z][a-z0-9-]*)", task_refs))))
        self.task_skills[stage] = tuple(name for name in self.task_skills[stage] if name != "shared")
        selected = self.instruction_set(stage)
        digest = subprocess.run(
            ["bash", str(self.snapshot / "skills/worktask/scripts/ledger-digest.sh"),
             "--state", str(Path(arm.cwd) / ".context/state.json")],
            capture_output=True, text=True, timeout=30)
        if digest.returncode:
            raise ValueError("canonical ledger digest unavailable before dispatch")
        return preamble.assemble_canonical_stage_prompt(prompt, selected, digest.stdout)

    def env(self, arm):
        home = self.homes[arm]
        env = {key: os.environ[key] for key in ("PATH", "TMPDIR", "LANG", "DEVELOPER_DIR")
               if key in os.environ}
        env.update(CODEX_HOME=str(home), HOME=str(self.arm_cwds[arm] / ".benchmark-home"),
                   GIT_CONFIG_NOSYSTEM="1",
                   GIT_CONFIG_GLOBAL=os.devnull)
        if arm == "with":
            env.update(CLAUDE_PLUGIN_ROOT=str(self.snapshot), PLUGIN_ROOT=str(self.snapshot))
        return env

    def estimate(self, stage):
        from ...budget import expected_tokens
        tokens = expected_tokens(stage)
        return capture.price(self.models[stage], tokens, 0, tokens // 4, self.pricing)

    def build_argv(self, arm, stage):
        self.validate_snapshot()
        self.stage_specs[arm.name] = arm
        selected = self.select_catalogue(stage) if arm.bind_agent else None
        if selected is not None:
            context = Path(arm.cwd) / ".context"
            context.mkdir(exist_ok=True)
            manifest = {key: selected[key] for key in ("stage", "fingerprint", "references")}
            manifest["skills"] = sorted(selected["skills"])
            (context / f"instructions-{stage}.json").write_text(json.dumps(manifest, indent=2) + "\n")
        overrides = {
            "approval_policy": "never", "default_permissions": "benchmark",
            "permissions": {"benchmark": {
                "extends": ":workspace", "network": {"enabled": False},
                "filesystem": {
                    str(self.root): "deny", str(self.owner_home): "deny",
                    str(self.auth_source): "deny",
                    str(self.config_root): "deny",
                    str(Path(arm.cwd).parent / (
                        "without" if arm.name == "with" else "with")): "deny",
                    str(self.snapshot): "read" if arm.bind_agent else "deny"}}},
            "model_reasoning_effort": STAGE_TABLE[stage][2],
            "model_context_window": 200000,
            "model_auto_compact_token_limit": 180000,
            "service_tier": "default", "web_search": "disabled",
            "plugins._default.enabled": False, "skills.bundled.enabled": False,
            "agents.enabled": False, "features.apps": False, "features.multi_agent": False,
            "features.memories": False, "features.shell_snapshot": False,
            "features.plugins": False, "features.plugin_discovery_prefetch": False,
            "features.remote_plugin": False, "features.skill_mcp_dependency_install": False,
            "features.hooks": False, "features.browser_use": False,
            "features.computer_use": False, "features.image_generation": False,
            "features.unbounded_connection_retries": False,
            "analytics.enabled": False, "check_for_update_on_startup": False,
            "shell_environment_policy.inherit": "none",
            "shell_environment_policy.set": self.env(arm.name),
            "shell_environment_policy.experimental_use_profile": False,
            "allow_login_shell": False, "project_doc_max_bytes": 0,
            "developer_instructions": runtime_contract(self.snapshot),
        }
        if arm.bind_agent:
            overrides["developer_instructions"] = (
                selected["instructions"].removeprefix(selected["contract_reminder"] + "\n\n")
                + f"\nPlugin root: {self.snapshot}\n"
                + "Execute only this stage in this workspace. Use local tools directly. "
                "Do not launch nested agents or request external services. "
                "Keep the pinned model and effort. The benchmark owns stage dispatch. "
                "Do not read credentials. Never use the network, git push, or gh.\n")
            overrides["developer_instructions"] += runtime_contract(self.snapshot)
        argv = ["codex", "--no-daemon", "exec", "--json", "--ephemeral", "--ignore-user-config",
                "--strict-config", "--model", self.models[stage], "--cd", arm.cwd]
        for key, value in overrides.items():
            argv += ["-c", f"{key}={toml_value(value)}"]
        return argv + ["-"]

    def validate_snapshot(self):
        if self.snapshot is None or digest_tree(self.snapshot) != self.snapshot_digest:
            raise ValueError("Codex plugin snapshot changed")

    def parse(self, stdout, stage):
        if any(e.get("type") == "error" for e in capture.events(stdout)):
            raise capture.AccountingError("transport errors prevent complete accounting")
        return capture.parse(stdout, self.models[stage], self.pricing)

    def usage(self, stdout, stage):
        parsed = self.parse(stdout, stage)
        return StageUsage(input_tokens=parsed.input_tokens, output_tokens=parsed.output_tokens,
                          cache_read=parsed.cache_read, cache_creation=parsed.cache_creation,
                          cost_usd=parsed.cost_usd, capture_layer=1, coverage=parsed.coverage)

    def detect_limit(self, stdout, now):
        for event in capture.events(stdout):
            if event.get("type") not in ("error", "turn.failed"):
                continue
            message = str(event.get("message") or event.get("error") or "")
            if any(s in message.lower() for s in ("usage limit", "rate limit", "quota", "429")):
                return UsageLimit(message=message)
        return None

    def metadata(self):
        result = subprocess.run(["codex", "--version"], capture_output=True, text=True, timeout=30)
        if result.returncode != 0:
            raise ValueError("Codex CLI version unavailable")
        return {
            "provider": self.name, "model_pins": self.models,
            "efforts": {s: row[2] for s, row in STAGE_TABLE.items()},
            "cli_version": result.stdout.strip(), "pricing": self.pricing,
            "authentication": "chatgpt", "source_digest": self.source_digest,
            "plugin_snapshot_digest": self.snapshot_digest,
            "plugin_version": json.loads(
                (self.snapshot / ".claude-plugin/plugin.json").read_text())["version"],
            "plugin_loading": "stage-specific-skills-and-canonical-stage-contracts",
            "context_window": 200000, "nested_agents": "disabled-in-both-arms",
            "transport_retries": "CLI defaults; emitted errors stop accounting",
            "runtime_isolation": json.loads(json.dumps(self.initial_runtime_isolation
                                                       or self.runtime_isolation)),
            "native_validation": "trusted-host-after-dispatch",
        }


def toml_value(value):
    if isinstance(value, dict):
        return "{" + ",".join(f"{json.dumps(k)}={toml_value(v)}" for k, v in value.items()) + "}"
    return json.dumps(value, ensure_ascii=False)
