#!/usr/bin/env python3
"""Kommentar-Werkzeug: findet, entfernt und begrenzt Code-Kommentare.

    python3 scripts/comments.py check            # Ratchet-Lint (CI)
    python3 scripts/comments.py baseline         # Baseline auf den Ist-Stand senken
    python3 scripts/comments.py stats [PFAD…]    # Kommentarzeilen je Datei
    python3 scripts/comments.py extract [PFAD…]  # Kommentarblöcke als JSON
    python3 scripts/comments.py delete IDS.json  # Blöcke nach ID entfernen

Begründung und Regel: docs/adr/0001-keine-code-kommentare.md.
"""

import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BASELINE = ROOT / "scripts" / "comment-baseline.json"
EXCLUDE = ("docs/references/",)
EXEMPT = re.compile(r"^#!|swift-tools-version|shellcheck|SPDX-License-Identifier|Copyright \(c\)|^# v\d+(\.\d+)*$")

LANG = {
    ".swift": "swift", ".gd": "gd", ".gdshader": "c", ".gdshaderinc": "c",
    ".glsl": "c", ".sh": "sh", ".py": "py", ".yml": "yml", ".yaml": "yml",
}


def tracked_files(paths=()):
    out = subprocess.run(["git", "ls-files", "-z", "--", *paths], cwd=ROOT,
                         capture_output=True, check=True).stdout.decode()
    return sorted(p for p in out.split("\0") if p and Path(p).suffix in LANG
                  and not p.startswith(EXCLUDE) and (ROOT / p).is_file())


class Lexer:
    def __init__(self, s):
        self.s, self.n, self.spans = s, len(s), []

    def at(self, i, t):
        return self.s.startswith(t, i)

    def eol(self, i):
        j = self.s.find("\n", i)
        return self.n if j < 0 else j

    def line_comment(self, i):
        j = self.eol(i)
        self.spans.append((i, j))
        return j


class SwiftLexer(Lexer):
    OPEN = re.compile(r'(#*)("""|")')

    def run(self):
        self.code(0, False)
        return self.spans

    def code(self, i, interp):
        depth = 0
        while i < self.n:
            c = self.s[i]
            if self.at(i, "//"):
                i = self.line_comment(i)
                continue
            if self.at(i, "/*"):
                j, d = i + 2, 1
                while j < self.n and d:
                    if self.at(j, "/*"):
                        d, j = d + 1, j + 2
                    elif self.at(j, "*/"):
                        d, j = d - 1, j + 2
                    else:
                        j += 1
                self.spans.append((i, j))
                i = j
                continue
            if c in '#"':
                m = self.OPEN.match(self.s, i)
                if m and (c == '"' or m.group(1)):
                    i = self.string(m.end(), m.group(1), m.group(2) == '"""')
                    continue
            if interp:
                if c == "(":
                    depth += 1
                elif c == ")":
                    if depth == 0:
                        return i + 1
                    depth -= 1
            i += 1
        return i

    def string(self, i, hashes, multi):
        close, esc = ('"""' if multi else '"') + hashes, "\\" + hashes
        while i < self.n:
            if self.at(i, esc):
                k = i + len(esc)
                if k < self.n and self.s[k] == "(":
                    i = self.code(k + 1, True)
                else:
                    i = k + 1
                continue
            if self.at(i, close):
                return i + len(close)
            if not multi and self.s[i] == "\n":
                return i
            i += 1
        return i


class HashLexer(Lexer):
    """`#`-Kommentare mit Python-/GDScript-Zeichenketten."""

    def run(self):
        i = 0
        while i < self.n:
            c = self.s[i]
            if c == "#":
                i = self.line_comment(i)
            elif c in "\"'":
                q = c * 3 if self.at(i, c * 3) else c
                i += len(q)
                while i < self.n and not self.at(i, q):
                    if len(q) == 1 and self.s[i] == "\n":
                        break
                    i += 2 if self.s[i] == "\\" else 1
                i += len(q)
            else:
                i += 1
        return self.spans


class CLexer(Lexer):
    def run(self):
        i = 0
        while i < self.n:
            if self.at(i, "//"):
                i = self.line_comment(i)
            elif self.at(i, "/*"):
                j = self.s.find("*/", i + 2)
                j = self.n if j < 0 else j + 2
                self.spans.append((i, j))
                i = j
            elif self.s[i] == '"':
                i += 1
                while i < self.n and self.s[i] not in '"\n':
                    i += 2 if self.s[i] == "\\" else 1
                i += 1
            else:
                i += 1
        return self.spans


class ShellLexer(Lexer):
    WORD_START = " \t\n;|&()"
    HEREDOC = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")

    def run(self):
        self.pending = []
        self.code(0, False)
        return self.spans

    def newline(self, i):
        i += 1
        for tag in self.pending:
            while i < self.n:
                j = self.eol(i)
                done = self.s[i:j].strip() == tag
                i = j + 1
                if done:
                    break
        self.pending = []
        return i

    def code(self, i, sub):
        depth = 0
        while i < self.n:
            c = self.s[i]
            if c == "\\":
                i += 2
            elif c == "\n":
                i = self.newline(i)
            elif c == "#" and (i == 0 or self.s[i - 1] in self.WORD_START):
                i = self.line_comment(i)
            elif c == "'":
                j = self.s.find("'", i + 1)
                i = self.n if j < 0 else j + 1
            elif c == '"':
                i = self.dquote(i + 1)
            elif c == "<" and (m := self.HEREDOC.match(self.s, i)):
                self.pending.append(m.group(2))
                i = m.end()
            elif sub and c == "(":
                depth, i = depth + 1, i + 1
            elif sub and c == ")":
                if depth == 0:
                    return i + 1
                depth, i = depth - 1, i + 1
            else:
                i += 1
        return i

    def dquote(self, i):
        while i < self.n:
            c = self.s[i]
            if c == "\\":
                i += 2
            elif c == '"':
                return i + 1
            elif self.at(i, "$("):
                i = self.code(i + 2, True)
            else:
                i += 1
        return i


class YamlLexer(Lexer):
    BLOCK = re.compile(r":\s*[|>][-+0-9]*\s*(#.*)?$")

    def run(self):
        offset, block_indent = 0, None
        for line in self.s.splitlines(keepends=True):
            body = line.rstrip("\n")
            indent = len(body) - len(body.lstrip())
            if block_indent is not None and body.strip() and indent <= block_indent:
                block_indent = None
            if block_indent is not None:
                if body.lstrip().startswith("#"):
                    self.spans.append((offset + indent, offset + len(body)))
            else:
                self.scan(body, offset)
                if self.BLOCK.search(body):
                    block_indent = indent
            offset += len(line)
        return self.spans

    def scan(self, body, offset):
        i, quote = 0, None
        while i < len(body):
            c = body[i]
            if quote:
                if c == "\\" and quote == '"':
                    i += 1
                elif c == quote:
                    quote = None
            elif c in "\"'" and (i == 0 or body[i - 1] in " :[{,-"):
                quote = c
            elif c == "#" and (i == 0 or body[i - 1] in " \t"):
                self.spans.append((offset + i, offset + len(body)))
                return
            i += 1


LEXERS = {"swift": SwiftLexer, "gd": HashLexer, "py": HashLexer, "c": CLexer,
          "sh": ShellLexer, "yml": YamlLexer}


def comment_blocks(path):
    """Kommentarblöcke einer Datei: zusammenhängende Ganzzeilen-Kommentare
    bilden einen Block, Kommentare hinter Code je einen eigenen."""
    text = (ROOT / path).read_text(encoding="utf-8")
    lines = text.split("\n")
    starts, pos = [], 0
    for line in lines:
        starts.append(pos)
        pos += len(line) + 1

    def locate(off):
        lo, hi = 0, len(starts) - 1
        while lo < hi:
            mid = (lo + hi + 1) // 2
            if starts[mid] <= off:
                lo = mid
            else:
                hi = mid - 1
        return lo, off - starts[lo]

    spans = []
    for a, b in LEXERS[LANG[Path(path).suffix]](text).run():
        la, ca = locate(a)
        lb, cb = locate(b)
        content = text[a:b]
        if EXEMPT.search(content):
            continue
        full = not lines[la][:ca].strip() and not lines[lb][cb:].strip()
        spans.append({"l0": la, "c0": ca, "l1": lb, "c1": cb, "full": full})

    blocks = []
    for sp in spans:
        prev = blocks[-1] if blocks else None
        if sp["full"] and prev and prev["full"] and prev["l1"] + 1 == sp["l0"]:
            prev["l1"], prev["c1"] = sp["l1"], sp["c1"]
            prev["spans"].append(sp)
        else:
            blocks.append({"full": sp["full"], "l0": sp["l0"], "l1": sp["l1"],
                           "c1": sp["c1"], "spans": [sp]})
    for b in blocks:
        b["id"] = f"{path}:{b['l0'] + 1}"
        b["text"] = ("\n".join(lines[k].strip() for k in range(b["l0"], b["l1"] + 1))
                     if b["full"] else _span_text(lines, b["spans"][0]))
    return lines, blocks


def _span_text(lines, sp):
    if sp["l0"] == sp["l1"]:
        return lines[sp["l0"]][sp["c0"]:sp["c1"]]
    return "\n".join([lines[sp["l0"]][sp["c0"]:], *lines[sp["l0"] + 1:sp["l1"]],
                      lines[sp["l1"]][:sp["c1"]]])


def comment_line_count(blocks):
    seen = set()
    for b in blocks:
        for sp in b["spans"]:
            seen.update(range(sp["l0"], sp["l1"] + 1))
    return len(seen)


def counts(paths=()):
    result = {}
    for p in tracked_files(paths):
        c = comment_line_count(comment_blocks(p)[1])
        if c:
            result[p] = c
    return result


def cmd_stats(args):
    c = counts(args)
    for p, k in sorted(c.items(), key=lambda kv: -kv[1]):
        print(f"{k:6d}  {p}")
    print(f"{sum(c.values()):6d}  gesamt in {len(c)} Dateien")


def cmd_baseline(args):
    c = counts()
    BASELINE.write_text(json.dumps(c, indent=1, sort_keys=True) + "\n")
    print(f"Baseline: {sum(c.values())} Kommentarzeilen in {len(c)} Dateien")


def cmd_check(args):
    base = json.loads(BASELINE.read_text()) if BASELINE.exists() else {}
    cur = counts()
    grown = {p: (base.get(p, 0), k) for p, k in cur.items() if k > base.get(p, 0)}
    shrunk = {p: (k, cur.get(p, 0)) for p, k in base.items() if cur.get(p, 0) < k}
    for p, (old, new) in sorted(grown.items()):
        print(f"FAIL: {p}: {new} Kommentarzeilen, erlaubt {old}")
    for p, (old, new) in sorted(shrunk.items()):
        print(f"FAIL: {p}: nur noch {new} Kommentarzeilen, Baseline sagt {old}")
    if grown:
        print("Keine neuen Kommentare: Begründungen gehören nach docs/adr/, "
              "s. docs/adr/0001-keine-code-kommentare.md.")
    if shrunk:
        print("Baseline nachziehen: python3 scripts/comments.py baseline")
    if grown or shrunk:
        sys.exit(1)
    print(f"COMMENTS_OK {sum(cur.values())} Kommentarzeilen (Baseline)")


def cmd_extract(args):
    out = []
    for p in tracked_files(args):
        lines, blocks = comment_blocks(p)
        for b in blocks:
            after = lines[b["l1"] + 1:b["l1"] + 7] if b["full"] else []
            out.append({"id": b["id"], "file": p, "lines": [b["l0"] + 1, b["l1"] + 1],
                        "trailing": not b["full"],
                        "code": lines[b["l0"]] if not b["full"] else None,
                        "text": b["text"], "next_code": after})
    json.dump(out, sys.stdout, ensure_ascii=False, indent=1)
    print()


def delete_blocks(path, ids):
    lines, blocks = comment_blocks(path)
    drop, cut = set(), {}
    for b in blocks:
        if b["id"] not in ids:
            continue
        if b["full"]:
            drop.update(range(b["l0"], b["l1"] + 1))
        else:
            for sp in b["spans"]:
                cut.setdefault(sp["l0"], []).append(sp)
    for ln, sps in cut.items():
        for sp in sorted(sps, key=lambda s: -s["c0"]):
            if sp["l0"] == sp["l1"]:
                lines[ln] = (lines[ln][:sp["c0"]] + lines[ln][sp["c1"]:]).rstrip()
            else:
                lines[ln] = lines[ln][:sp["c0"]].rstrip()
                rest = lines[sp["l1"]][sp["c1"]:]
                lines[sp["l1"]] = rest
                drop.update(range(sp["l0"] + 1, sp["l1"]))
                if not rest.strip():
                    drop.add(sp["l1"])
            if not lines[ln].strip():
                drop.add(ln)
    if not drop and not cut:
        return 0
    marked = []
    for k, line in enumerate(lines):
        if k not in drop:
            marked.append(line)
        elif not marked or marked[-1] is not None:
            marked.append(None)
    out = []
    for k, line in enumerate(marked):
        if line is not None:
            out.append(line)
            continue
        nxt = next((x for x in marked[k + 1:] if x is not None), "")
        prev = out[-1] if out else ""
        if out and not prev.strip() and (not nxt.strip() or nxt.lstrip().startswith(("}", "]", ")"))):
            out.pop()
        elif (not out or prev.rstrip().endswith(("{", "[", "("))) and not nxt.strip() \
                and k + 1 < len(marked) and marked[k + 1] is not None:
            marked[k + 1] = None
    (ROOT / path).write_text("\n".join(out), encoding="utf-8")
    return len(lines) - len(out)


def cmd_delete(args):
    ids = set(json.loads(Path(args[0]).read_text()))
    by_file = {}
    for i in ids:
        by_file.setdefault(i.rsplit(":", 1)[0], set()).add(i)
    shed = sum(delete_blocks(p, s) for p, s in sorted(by_file.items()))
    print(f"{len(ids)} Blöcke in {len(by_file)} Dateien entfernt, {shed} Zeilen weniger")


def main():
    cmds = {"check": cmd_check, "baseline": cmd_baseline, "stats": cmd_stats,
            "extract": cmd_extract, "delete": cmd_delete}
    if len(sys.argv) < 2 or sys.argv[1] not in cmds:
        sys.exit(__doc__)
    cmds[sys.argv[1]](sys.argv[2:])


if __name__ == "__main__":
    main()
