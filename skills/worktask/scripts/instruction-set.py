#!/usr/bin/env python3
"""Compose stage instructions from canonical sources without loading a full catalogue."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess


ROOT = Path(__file__).resolve().parents[3]
SKILL_REF = re.compile(r"skills/([a-z][a-z0-9-]*)/")
NAMED_SKILL = re.compile(r"(?:skill:\s*|skill[=:\"]+\s*|\$)corpflow:([a-z][a-z0-9-]*)")
BASE_SKILLS = ("writing-style", "context-compression", "cost-optimization", "code-comment-standard")


def read(root, relative):
    path = root / relative
    if not path.resolve().is_relative_to(root.resolve()) or not path.is_file():
        raise ValueError(f"canonical instruction reference missing or off-root: {relative}")
    return path.read_text(encoding="utf-8")


def frontmatter(text):
    if not text.startswith("---\n") or "\n---" not in text[4:]:
        raise ValueError("skill frontmatter missing")
    return text.split("---", 2)[1]


def field(text, name):
    found = re.search(r"^" + re.escape(name) + r":\s*(.+)$", frontmatter(text), re.MULTILINE)
    if not found:
        raise ValueError(f"skill {name} missing")
    value = found[1].strip()
    if value.startswith('"'):
        return json.loads(value)
    if value.startswith("'") and value.endswith("'"):
        return value[1:-1].replace("''", "'")
    return value


def section(text, heading):
    found = re.search(r"^(#{1,6}) " + re.escape(heading) + r"\s*$", text, re.MULTILINE)
    if not found:
        raise ValueError(f"canonical section missing: {heading}")
    rest = text[found.end():]
    end = re.search(r"^#{1," + str(len(found[1])) + r"} ", rest, re.MULTILINE)
    return text[found.start():found.end()] + (rest[:end.start()] if end else rest)


def resolve_reference(root, reference):
    path, _, anchor = reference.partition("#")
    if not path.startswith("skills/") or ".." in Path(path).parts:
        raise ValueError("task reference must stay in canonical skills")
    text = read(root, path)
    if anchor:
        found = set(re.findall(r'<a id="([^"]+)"', text))
        fenced = False
        for line in text.splitlines():
            if line.lstrip().startswith("```"):
                fenced = not fenced
                continue
            heading = re.match(r"^#{1,6} (.+)$", line)
            if heading and not fenced:
                found.add(re.sub(r"[^\w -]", "", heading[1].lower()).replace(" ", "-"))
        if anchor not in found:
            raise ValueError(f"canonical anchor missing: {reference}")
    return text


def compose(root, stage, skills=(), role=None, task_text="", references=()):
    result = subprocess.run(["bash", str(root / "skills/worktask/scripts/cache-lint.sh"),
                             "--allow-list", "--stage", stage],
                            capture_output=True, text=True, check=True)
    rows = result.stdout.splitlines()
    if not rows or rows[0].split("\t")[0] != stage:
        raise ValueError(f"unknown instruction stage: {stage}")
    role = role or rows[0].split("\t")[1]
    if not re.fullmatch(r"[a-z][a-z0-9-]*", role):
        raise ValueError("role must name a canonical local agent")
    role_path = f"agents/{role}.md"
    role_text = read(root, role_path)
    requested = set(BASE_SKILLS) | set(SKILL_REF.findall(role_text)) | set(NAMED_SKILL.findall(role_text))
    for reference in references:
        resolve_reference(root, reference)
        requested.update(SKILL_REF.findall(reference))
    requested.update(SKILL_REF.findall(task_text))
    requested.update(NAMED_SKILL.findall(task_text))
    requested.discard("shared")
    for name in skills:
        if not re.fullmatch(r"[a-z][a-z0-9-]*", name):
            raise ValueError("task skill must name a canonical skill")
        requested.add(name)
    selected = {}
    pending = sorted(requested)
    while pending:
        name = pending.pop(0)
        if name in selected:
            continue
        relative = f"skills/{name}/SKILL.md"
        text = read(root, relative)
        description = field(text, "description")
        selected[name] = {"name": field(text, "name"), "description": description, "path": relative}
        for dependency in sorted(set(SKILL_REF.findall(text)) | set(NAMED_SKILL.findall(text))):
            if dependency != "shared" and dependency not in selected:
                pending.append(dependency)
    reminder = read(root, "skills/worktask/references/contract-reminder.md")
    match = re.search(r"^```text\n(.*?)\n```", reminder, re.MULTILINE | re.DOTALL)
    if not match:
        raise ValueError("canonical contract reminder missing")
    prefix = match[1] + "\n"
    mandatory_paths = ["skills/worktask/references/contracts/stage-inputs.md",
                       "skills/worktask/references/contracts/stage-outputs.md",
                       "skills/worktask/references/contracts/completion.md",
                       "skills/worktask/references/contracts/frontmatter.md",
                       "skills/worktask/references/contracts/required-fields.md",
                       "skills/worktask/references/completion-boundary.md",
                       "skills/shared/codex-runtime.md"]
    mandatory = [read(root, path) for path in mandatory_paths]
    template_path = f"skills/worktask/assets/templates/template-{stage.lower()}.md"
    template = read(root, template_path)
    match = re.search(r"^### #tpl-" + stage.lower() + r" .+$", template, re.MULTILINE)
    if not match:
        raise ValueError("canonical stage template section missing")
    rest = template[match.end():]
    end = re.search(r"^#{2,3} ", rest, re.MULTILINE)
    template = template[match.start():match.end()] + (rest[:end.start()] if end else rest)
    catalogue = "\n".join(f"- {name}: {item['description']} (file: {item['path']})"
                            for name, item in sorted(selected.items()))
    required_refs = "\n".join("- " + path for path in mandatory_paths)
    instructions = (prefix + "\n" + role_text
                    + "\nRequired contracts: resolve these canonical sources before acting; missing references block dependent checks.\n"
                    + required_refs + "\n")
    references = ["skills/worktask/references/contract-reminder.md", *mandatory_paths,
                  template_path, role_path, *[item["path"] for _, item in sorted(selected.items())], *references]
    digest = hashlib.sha256()
    for path in references:
        digest.update(path.encode() + b"\0" + read(root, path.split("#")[0]).encode() + b"\0")
    return {"stage": stage, "role": role, "contract_reminder": prefix.rstrip("\n"),
            "stage_contract": template, "catalogue": catalogue, "skills": selected,
            "references": references, "instructions": instructions,
            "fingerprint": "sha256:" + digest.hexdigest()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stage", nargs="?")
    parser.add_argument("--skill", action="append", default=[])
    parser.add_argument("--catalogue-only", action="store_true")
    parser.add_argument("--role")
    parser.add_argument("--task-text", default="")
    parser.add_argument("--reference", action="append", default=[])
    parser.add_argument("--check-reference")
    args = parser.parse_args()
    try:
        if args.check_reference:
            resolve_reference(ROOT, args.check_reference)
            print("reference=ok")
            return
        if not args.stage:
            parser.error("stage is required")
        result = compose(ROOT, args.stage, args.skill, args.role, args.task_text, args.reference)
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        parser.exit(2, f"instruction-set: {exc}\n")
    print(result["catalogue"] if args.catalogue_only else json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()
