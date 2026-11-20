#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""check-scope.py — a Fieldkit tool can do nothing the goat-processors CLI cannot.

Copied from goatcore ops/ci/check-fieldkit-scope.py (commit e6d72562), with
this repo's paths: tools are runner/fieldkit/*.html, the allow list is
runner/fieldkit/cli-allowlist.txt, and (4) reads the CLI's own usage text
(`goat-processors help`) in place of `goat docs --markdown`.

THE RULE (docs/design/fieldkit-and-bleating-edge.md §1, §3, §5). A Fieldkit tool
is a small page over the same API the `goat` CLI calls: a fixed list of at most
eight actions, each equal to a CLI command, and no authority of its own. This
guard fails the build when a tool gains an action with no CLI equivalent.

WHAT IT CHECKS, for every tool page runner/fieldkit/*.html (the tool name is
the file name; the design system and node_modules are not tools):
  1. every element with `data-action` also has `data-cli` (the goat verb) and
     `data-api` ("METHOD /route"), and that (tool, verb, method, route) is a row
     in runner/fieldkit/cli-allowlist.txt;
  2. a tool declares at most eight actions;
  3. outside the inlined Bleating Edge script, the page has no other way to
     reach a network: no fetch, XMLHttpRequest, WebSocket, EventSource,
     sendBeacon or dynamic import, and no API route written anywhere except in
     a `data-api` attribute. Bleating Edge's BE.call reaches only routes that an
     action declares, so (1) covers every request the page can make;
  4. with --usage FILE (the output of `goat-processors help`), every verb on
     the allow list is a command in it.

Exit 0 when every tool is in scope, 1 when one is not (each problem is named).

Usage:
  runner/fieldkit/check-scope.py [--root DIR] [--allowlist FILE] [--usage FILE]
  runner/fieldkit/check-scope.py --self-test
"""
from __future__ import annotations

import argparse
import re
import sys
import tempfile
from html.parser import HTMLParser
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
TOOLS = ("runner", "fieldkit")
PROGRAM = "goat-processors"
MAX_ACTIONS = 8
NOT_TOOLS = {"bleating-edge", "e2e", "node_modules"}
BE_SCRIPT = re.compile(r"<script data-bleating-edge>.*?</script>", re.S)
DATA_API_ATTR = re.compile(r"""data-api\s*=\s*("[^"]*"|'[^']*')""")
NETWORK = re.compile(r"\bfetch\s*\(|XMLHttpRequest|\bWebSocket\b|\bEventSource\b|sendBeacon|\bimport\s*\(")
ROUTE = re.compile(r"""["'`]\s*/(v\d+|api)/""")


def load_allowlist(path: Path) -> set[tuple[str, str, str, str]]:
    rows = set()
    for n, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        parts = [p.strip() for p in line.split("|")]
        if len(parts) != 4 or not all(parts):
            raise SystemExit(f"{path}:{n}: expected 'tool | verb | METHOD | /route'")
        tool, verb, method, route = parts
        rows.add((tool, " ".join(verb.split()), method.upper(), route))
    return rows


class Actions(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.found: list[tuple[int, dict]] = []

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if "data-action" in a or "data-api" in a or "data-cli" in a:
            self.found.append((self.getpos()[0], a))

    handle_startendtag = handle_starttag


def tool_pages(root: Path) -> list[Path]:
    base = root.joinpath(*TOOLS)
    if not base.is_dir():
        return []
    return sorted(p for p in base.rglob("*.html")
                  if p.relative_to(base).parts[0] not in NOT_TOOLS and not NOT_TOOLS & set(p.parts))


def tool_name(base: Path, page: Path) -> str:
    rel = page.relative_to(base)
    return rel.parts[0] if len(rel.parts) > 1 else page.stem


def check_page(page: Path, tool: str, allow: set, rel: str) -> list[str]:
    problems = []
    text = page.read_text(encoding="utf-8")
    parser = Actions()
    parser.feed(text)
    names = set()
    for line, a in parser.found:
        where = f"{rel}:{line}"
        name = a.get("data-action")
        if not name:
            problems.append(f"{where}: data-api or data-cli without data-action; declare it as an action")
            continue
        names.add(name)
        verb = " ".join((a.get("data-cli") or "").split())
        api = (a.get("data-api") or "").split()
        if not verb:
            problems.append(f"{where}: action '{name}' has no data-cli; every action names the {PROGRAM} command it equals")
            continue
        if len(api) != 2:
            problems.append(f"{where}: action '{name}' needs data-api=\"METHOD /route\"")
            continue
        row = (tool, verb, api[0].upper(), api[1])
        if row not in allow:
            problems.append(f"{where}: action '{name}' = `{PROGRAM} {verb}` {api[0]} {api[1]} is not on "
                            f"runner/fieldkit/cli-allowlist.txt for tool '{tool}'. A tool may only do what a CLI verb does")
    if len(names) > MAX_ACTIONS:
        problems.append(f"{rel}: {len(names)} actions; a Fieldkit tool has at most {MAX_ACTIONS}")
    rest = DATA_API_ATTR.sub("", BE_SCRIPT.sub("", text))
    for n, line in enumerate(rest.splitlines(), 1):
        if NETWORK.search(line):
            problems.append(f"{rel}: line {n} of the page outside Bleating Edge reaches the network directly; "
                            f"call a declared action with BE.call instead")
        if ROUTE.search(line):
            problems.append(f"{rel}: line {n} writes an API route outside a data-api attribute; "
                            f"declare it on an action instead")
    return problems


def check_docs(allow: set, docs: Path) -> list[str]:
    """Every allowed verb is a command in the CLI's usage text: some line reads
    `goat-processors VERB` followed by an argument, an option or the end."""
    text = docs.read_text(encoding="utf-8")
    problems = []
    for tool, verb, _, _ in sorted(allow):
        # A word may be written as one of alternatives: `approve|reject|revert`.
        word = lambda w: r"(?:[\w-]+\|)*" + re.escape(w) + r"(?:\|[\w-]+)*"  # noqa: E731
        pat = re.compile(r"^\s*" + re.escape(PROGRAM) + r"\s+" + r"\s+".join(map(word, verb.split())) + r"(\s|$)", re.M)
        if not pat.search(text):
            problems.append(f"allow list: `{PROGRAM} {verb}` (tool {tool}) is not a command in {docs}")
    return problems


def run(root: Path, allowlist: Path, docs: Path | None) -> list[str]:
    allow = load_allowlist(allowlist)
    problems = []
    base = root.joinpath(*TOOLS)
    for page in tool_pages(root):
        tool = tool_name(base, page)
        problems += check_page(page, tool, allow, str(page.relative_to(root)))
    if docs:
        problems += check_docs(allow, docs)
    return problems


GOOD = """<nav>
<button data-action="status" data-cli="status" data-api="GET /v1/status">Status</button>
</nav>
<script data-bleating-edge>function call(){ return fetch("/v1/" + x); }</script>
<script>BE.call("status");</script>"""


def self_test() -> int:
    allow_text = "t | status | GET | /v1/status\n"
    cases = [
        ("in scope", GOOD, 0),
        ("verb not on the list", GOOD.replace('"status" data-api', '"nuke" data-api'), 1),
        ("route not on the list", GOOD.replace("GET /v1/status", "POST /v1/status"), 1),
        ("no data-cli", GOOD.replace(' data-cli="status"', ""), 1),
        ("no data-api", GOOD.replace(' data-api="GET /v1/status"', ""), 1),
        ("data-api without action", GOOD + '<a data-api="GET /v1/status">x</a>', 1),
        ("direct fetch", GOOD + "<script>fetch('/v1/rules', {method: 'DELETE'})</script>", 1),
        ("route literal", GOOD + "<script>var r = \"/v1/rules\";</script>", 1),
        ("xhr", GOOD + "<script>new XMLHttpRequest()</script>", 1),
        ("nine actions", "".join(f'<b data-action="a{i}" data-cli="status" data-api="GET /v1/status"></b>'
                                 for i in range(9)), 1),
    ]
    failed = 0
    with tempfile.TemporaryDirectory() as d:
        root = Path(d)
        (root / "runner/fieldkit/bleating-edge").mkdir(parents=True)
        (root / "runner/fieldkit/bleating-edge/starter.html").write_text('<b data-action="x"></b>')
        allow = root / "allow.txt"
        allow.write_text(allow_text)
        for name, html, want in cases:
            (root / "runner/fieldkit/t.html").write_text(html)
            got = 1 if run(root, allow, None) else 0
            if got != want:
                failed += 1
                print(f"FAIL {name}: want exit {want}, got {got}: {run(root, allow, None)}")
        docs = root / "docs.md"
        (root / "runner/fieldkit/t.html").write_text(GOOD)
        docs.write_text("  goat-processors status            state\n")
        if run(root, allow, docs):
            failed += 1
            print("FAIL docs: a listed verb present in the CLI was refused")
        docs.write_text("  goat-processors statusx           state\n")
        if not run(root, allow, docs):
            failed += 1
            print("FAIL docs: a listed verb missing from the CLI was accepted")
    print(f"check-scope self-test: {len(cases) + 2 - failed}/{len(cases) + 2} passed")
    return 1 if failed else 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--root", type=Path, default=REPO)
    ap.add_argument("--allowlist", type=Path, default=None)
    ap.add_argument("--usage", dest="docs", type=Path, default=None, help="output of `goat-processors help`")
    ap.add_argument("--self-test", action="store_true")
    a = ap.parse_args()
    if a.self_test:
        return self_test()
    allowlist = a.allowlist or a.root.joinpath(*TOOLS, "cli-allowlist.txt")
    problems = run(a.root, allowlist, a.docs)
    for p in problems:
        print(f"FAIL {p}")
    pages = tool_pages(a.root)
    if not problems:
        print(f"check-scope: {len(pages)} tool page(s); every action equals an allowed {PROGRAM} command")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
