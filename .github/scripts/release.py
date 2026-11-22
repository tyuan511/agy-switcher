import argparse
import json
import re
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
VERSION = r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
INITIAL_VERSION = (0, 1, 0)
PRODUCT_PATHS = ("App", "Sources", "Package.swift", "AGYSwitcher.xcodeproj")


def git(*args):
    return subprocess.check_output(("git", *args), cwd=ROOT, text=True).strip()


def version_tuple(version):
    match = re.fullmatch(VERSION, version)
    if not match:
        raise ValueError(f"Expected a version in X.Y.Z format, got {version!r}")
    return tuple(map(int, match.groups()))


def infer_bump(previous_tag):
    commits = git(
        "log", "--format=%s%x00%b%x00", f"{previous_tag}..HEAD", "--", *PRODUCT_PATHS
    ).split("\0")
    subjects = [subject.strip() for subject in commits[::2]]
    bodies = commits[1::2]
    if any(re.match(r"\w+(?:\([^)]+\))?!:", subject) for subject in subjects) or any(
        re.search(r"^BREAKING[ -]CHANGE:", body, re.MULTILINE) for body in bodies
    ):
        return "major"
    if any(re.match(r"feat(?:\([^)]+\))?:", subject) for subject in subjects):
        return "minor"
    return "patch"


def plan(args):
    git("rev-parse", "--verify", "HEAD")
    tags = {
        version_tuple(tag[1:]): tag
        for tag in git("tag", "--list").splitlines()
        if re.fullmatch("v" + VERSION, tag)
    }
    last_version = max(tags, default=None)
    previous_tag = tags.get(last_version)
    if previous_tag and previous_tag not in git("tag", "--merged", "HEAD").splitlines():
        raise ValueError(f"{previous_tag} is outside HEAD history. Check the release branch and tags.")

    if args.version is not None:
        version = version_tuple(args.version.removeprefix("v"))
    elif last_version is None and args.bump is None:
        version = INITIAL_VERSION
    else:
        major, minor, patch = last_version or INITIAL_VERSION
        bump = args.bump or infer_bump(previous_tag)
        version = {
            "major": (major + 1, 0, 0),
            "minor": (major, minor + 1, 0),
            "patch": (major, minor, patch + 1),
        }[bump]

    if last_version is not None and version <= last_version:
        raise ValueError(f"The next version must be higher than {previous_tag}.")
    number = ".".join(map(str, version))
    print(json.dumps({"previous_tag": previous_tag, "version": number, "tag": f"v{number}"}))


def check_notes(args):
    tag = args.tag
    if not re.fullmatch("v" + VERSION, tag):
        raise ValueError(f"Expected a release tag in vX.Y.Z format, got {tag!r}")

    notes = f"docs/release/{tag}.md"
    translated = f"docs/release/{tag}_zh-CN.md"
    release_url = f"https://github.com/{args.repository}/blob/{tag}"
    for path, language_switch in (
        (notes, f"**English** | [简体中文]({release_url}/{translated})"),
        (translated, f"[English]({release_url}/{notes}) | **简体中文**"),
    ):
        lines = (ROOT / path).read_text(encoding="utf-8").strip().splitlines()
        if not lines or lines[0] != language_switch:
            raise ValueError(f"{path} must start with: {language_switch}")
        if not any(line.strip() and not line.startswith("**Full Changelog**") for line in lines[1:]):
            raise ValueError(f"{path} is missing release notes.")


def main():
    parser = argparse.ArgumentParser(description="Plan an AGY Switcher release or check its notes.")
    commands = parser.add_subparsers(required=True)
    plan_parser = commands.add_parser("plan")
    selection = plan_parser.add_mutually_exclusive_group()
    selection.add_argument("--version", help="Explicit version in X.Y.Z or vX.Y.Z format.")
    selection.add_argument("--bump", choices=("major", "minor", "patch"))
    plan_parser.set_defaults(run=plan)
    check_parser = commands.add_parser("check-notes")
    check_parser.add_argument("tag")
    check_parser.add_argument("--repository", required=True, help="GitHub owner/repo.")
    check_parser.set_defaults(run=check_notes)
    args = parser.parse_args()
    try:
        args.run(args)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"release: {error}\n")


if __name__ == "__main__":
    main()
