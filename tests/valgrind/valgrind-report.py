#!/usr/bin/env python3
"""Turn a directory of Valgrind memcheck XML logs into a readable report.

Reads every ``*.xml`` written by ``valgrind --xml=yes --xml-file=DIR/%p.xml``
(one file per PostgreSQL process), groups the errors by their signature
(error kind plus the top of the stack), tells errors in spock's own code
from errors elsewhere, and writes:

    report.md     full report, GitHub-flavoured Markdown
    report.html   the same, self-contained HTML
    summary.md    the headline tables only, for a CI step summary
    summary.json  counts, for scripts

A log cut short by an immediate shutdown (SIGQUIT) is still read: the
errors it did manage to write are kept and the file is counted as
truncated.  Only the Python standard library is used.

Usage:
    valgrind-report.py --raw DIR --out DIR [--title TEXT]
                       [--meta KEY=VALUE ...] [--source-root DIR]
                       [--fail-on-errors]

Exit status: 0, or 3 with --fail-on-errors when at least one error was
found.  Bad input is 2.
"""

import argparse
import collections
import datetime
import glob
import html
import json
import os
import re
import sys
import xml.etree.ElementTree as ET

# Error kinds, most serious first.  Anything unknown sorts after these.
KIND_ORDER = [
    "InvalidWrite",
    "InvalidRead",
    "InvalidFree",
    "MismatchedFree",
    "InvalidJump",
    "InvalidMemPool",
    "Overlap",
    "UninitCondition",
    "UninitValue",
    "SyscallParam",
    "ClientCheck",
    "FishyValue",
    "Leak_DefinitelyLost",
    "Leak_IndirectlyLost",
    "Leak_PossiblyLost",
    "Leak_StillReachable",
]

KIND_HELP = {
    "InvalidWrite": "write to memory that is not allocated or already freed",
    "InvalidRead": "read of memory that is not allocated or already freed",
    "InvalidFree": "free() of an address that was not returned by an allocator",
    "MismatchedFree": "allocation and deallocation functions do not match",
    "InvalidJump": "jump to an invalid address",
    "InvalidMemPool": "bad memory pool request",
    "Overlap": "source and destination of a copy overlap",
    "UninitCondition": "a branch or condition depends on an uninitialised value",
    "UninitValue": "an uninitialised value is used",
    "SyscallParam": "a system call is passed uninitialised or unaddressable memory",
    "ClientCheck": "a VALGRIND_CHECK_* client request failed",
    "FishyValue": "a suspicious (probably negative) size argument",
    "Leak_DefinitelyLost": "memory that is no longer reachable",
    "Leak_IndirectlyLost": "memory reachable only from lost memory",
    "Leak_PossiblyLost": "memory reachable only through interior pointers",
    "Leak_StillReachable": "memory still reachable at exit",
}

# How many frames of the primary stack make up an error's signature.
SIGNATURE_DEPTH = 6

# An error counts as "in spock code" only when a spock frame is this close
# to the top of the stack.  spock is a hook on almost every backend's stack
# (ProcessUtility, the bgworker entry point), so a spock frame twenty
# levels down says nothing about who caused a relcache allocation.
ATTRIBUTION_DEPTH = 6

# How many frames a generated suppression keeps before "..." takes over.
# Valgrind emits one line per frame of a 30-deep stack, which only ever
# matches that exact call path.
SUPPRESSION_FRAMES = 8

# Frames in these objects or files are "spock's own code".
SPOCK_OBJ_RE = re.compile(r"(^|/)(spock|spock_output)[^/]*\.so$")
SPOCK_FILE_RE = re.compile(r"(^|/)spock[^/]*\.c$")


# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------

class Frame(object):
    __slots__ = ("ip", "obj", "fn", "file", "line", "dir")

    def __init__(self, el):
        self.ip = _text(el, "ip")
        self.obj = _text(el, "obj")
        self.fn = _text(el, "fn")
        self.file = _text(el, "file")
        self.line = _text(el, "line")
        self.dir = _text(el, "dir")

    @property
    def is_spock(self):
        return bool(SPOCK_OBJ_RE.search(self.obj) or SPOCK_FILE_RE.search(self.file))

    @property
    def location(self):
        if self.file:
            loc = self.file
            if self.line:
                loc += ":" + self.line
            return loc
        return ""

    def render(self):
        fn = self.fn or "???"
        loc = self.location
        obj = os.path.basename(self.obj) if self.obj else ""
        parts = [fn]
        if loc:
            parts.append("(" + loc + ")")
        if obj:
            parts.append("[" + obj + "]")
        return " ".join(parts)


class VgError(object):
    def __init__(self, el, pid, args):
        self.pid = pid
        self.args = args
        self.kind = _text(el, "kind") or "Unknown"
        self.what = _text(el, "what") or _text(el, "xwhat/text") or ""
        # The first stack is where it happened.  Later <auxwhat>/<stack>
        # pairs explain the address or where an uninitialised value came
        # from.  Children come in document order, so walk them.
        self.stack = []
        self.aux = []          # list of (text, [Frame])
        pending_text = None
        for child in el:
            if child.tag == "stack":
                frames = [Frame(f) for f in child.findall("frame")]
                if not self.stack:
                    self.stack = frames
                else:
                    self.aux.append((pending_text or "", frames))
                    pending_text = None
            elif child.tag == "auxwhat":
                pending_text = (child.text or "").strip()
            elif child.tag == "xauxwhat":
                pending_text = (_text(child, "text") or "").strip()
        if pending_text:
            self.aux.append((pending_text, []))
        self.suppression = clean_suppression(
            _text(el, "suppression/rawtext"), self)

    @property
    def is_leak(self):
        return self.kind.startswith("Leak_")

    @property
    def signature(self):
        top = [f.fn or f.ip for f in self.stack[:SIGNATURE_DEPTH]]
        return (self.kind,) + tuple(top)

    @property
    def spock_frame(self):
        for f in self.stack[:ATTRIBUTION_DEPTH]:
            if f.is_spock:
                return f
        return None

    @property
    def in_spock(self):
        return self.spock_frame is not None

    @property
    def top_frame(self):
        return self.stack[0] if self.stack else None


def clean_suppression(raw, err):
    """Give valgrind's generated suppression a name and a shorter stack.

    The placeholder name would clash with every other pasted block, and
    thirty ``fun:`` lines only ever match one exact call path, so keep the
    first few and let ``...`` match the rest.
    """
    raw = raw.strip()
    if not raw:
        return ""
    fn = ""
    f = err.spock_frame or err.top_frame
    if f is not None and f.fn:
        fn = re.sub(r"[^A-Za-z0-9_]", "_", f.fn)
    name = "spock_%s%s" % (err.kind.lower(), ("_" + fn) if fn else "")
    out = []
    frames = 0
    truncated = False
    for line in raw.splitlines():
        s = line.strip()
        if s == "<insert_a_suppression_name_here>":
            out.append("   " + name)
        elif s.startswith("fun:") or s.startswith("obj:"):
            if frames < SUPPRESSION_FRAMES:
                out.append(line)
                frames += 1
            elif not truncated:
                out.append("   ...")
                truncated = True
        else:
            out.append(line)
    return "\n".join(out)


class ProcessLog(object):
    def __init__(self, path):
        self.path = path
        self.pid = None
        self.ppid = None
        self.args = ""
        self.truncated = False
        self.errors = []
        self.parse_failed = False


def _text(el, path):
    found = el.find(path)
    if found is None or found.text is None:
        return ""
    return found.text.strip()


def _first(pattern, text, default=""):
    m = re.search(pattern, text, re.S)
    return m.group(1).strip() if m else default


def parse_log(path):
    log = ProcessLog(path)
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            text = f.read()
    except OSError as e:
        print("warning: cannot read %s: %s" % (path, e), file=sys.stderr)
        log.parse_failed = True
        return log

    # The file is named <start-time>-<pid>.xml by the shim.
    log.pid = (_first(r"<pid>(\d+)</pid>", text)
               or os.path.basename(path).split(".")[0].split("-")[-1])
    log.ppid = _first(r"<ppid>(\d+)</ppid>", text)
    argv = re.search(r"<argv>(.*?)</argv>", text, re.S)
    if argv:
        exe = _first(r"<exe>(.*?)</exe>", argv.group(1))
        args = re.findall(r"<arg>(.*?)</arg>", argv.group(1), re.S)
        log.args = " ".join([os.path.basename(html.unescape(exe))] +
                            [html.unescape(a) for a in args])
    log.truncated = "</valgrindoutput>" not in text

    # Parse each <error> on its own, so one damaged element (or a file cut
    # short mid-element) does not cost the others.
    for m in re.finditer(r"<error>.*?</error>", text, re.S):
        try:
            el = ET.fromstring(m.group(0))
        except ET.ParseError:
            log.parse_failed = True
            continue
        log.errors.append(VgError(el, log.pid, log.args))
    return log


# ---------------------------------------------------------------------------
# Grouping
# ---------------------------------------------------------------------------

class Group(object):
    def __init__(self, example):
        self.example = example
        self.kind = example.kind
        self.count = 0
        self.pids = set()

    def add(self, err):
        self.count += 1
        self.pids.add(err.pid)

    @property
    def in_spock(self):
        return self.example.in_spock

    @property
    def sort_key(self):
        try:
            k = KIND_ORDER.index(self.kind)
        except ValueError:
            k = len(KIND_ORDER)
        return (0 if self.in_spock else 1, k, -self.count)


def group_errors(logs):
    groups = collections.OrderedDict()
    for log in logs:
        for err in log.errors:
            g = groups.get(err.signature)
            if g is None:
                g = groups[err.signature] = Group(err)
            g.add(err)
    return sorted(groups.values(), key=lambda g: g.sort_key)


# ---------------------------------------------------------------------------
# Rendering helpers
# ---------------------------------------------------------------------------

def short_location(err, source_root):
    f = err.spock_frame or (err.stack[0] if err.stack else None)
    if f is None:
        return ""
    loc = f.location
    if source_root and f.dir and f.file:
        full = os.path.join(f.dir, f.file)
        if full.startswith(source_root):
            loc = os.path.relpath(full, source_root)
            if f.line:
                loc += ":" + f.line
    return loc


def where_parts(err, source_root):
    """(function, location, top-of-stack function) for the tables.

    The function is the spock frame when there is one, else the top frame.
    The third item is the top frame's function when it differs, so a leak
    attributed to spock still says which allocator path it came through.
    """
    f = err.spock_frame or err.top_frame
    if f is None:
        return "", "", ""
    top = err.top_frame
    top_fn = top.fn if (top is not None and top is not f and top.fn) else ""
    return f.fn, short_location(err, source_root), top_fn


def md_escape(s):
    return s.replace("|", "\\|").replace("\n", " ")


def render_stack(frames, limit=30):
    lines = []
    for i, f in enumerate(frames[:limit]):
        lines.append("  #%-2d %s" % (i, f.render()))
    if len(frames) > limit:
        lines.append("  ... %d more" % (len(frames) - limit))
    return "\n".join(lines) if lines else "  (no stack)"


def group_title(g, source_root):
    loc = short_location(g.example, source_root)
    fn = g.example.spock_frame.fn if g.example.spock_frame else (
        g.example.stack[0].fn if g.example.stack else "")
    bits = [g.kind]
    if fn:
        bits.append("in " + fn)
    if loc:
        bits.append("at " + loc)
    return " ".join(bits)


# ---------------------------------------------------------------------------
# Markdown
# ---------------------------------------------------------------------------

def summary_markdown(title, meta, logs, groups, source_root):
    total = sum(len(l.errors) for l in logs)
    spock_groups = [g for g in groups if g.in_spock]
    other_groups = [g for g in groups if not g.in_spock]
    truncated = sum(1 for l in logs if l.truncated)
    failed = sum(1 for l in logs if l.parse_failed)

    out = []
    out.append("# " + title)
    out.append("")
    if total == 0:
        out.append("**No errors.** Valgrind reported nothing that the "
                   "suppressions did not cover.")
    else:
        out.append("**%d error(s) in %d unique place(s)**, %d of them in "
                   "spock's own code." % (total, len(groups), len(spock_groups)))
    out.append("")

    out.append("## Run")
    out.append("")
    out.append("| | |")
    out.append("|---|---|")
    for k, v in meta:
        out.append("| %s | %s |" % (md_escape(k), md_escape(v)))
    out.append("| processes analysed | %d |" % len(logs))
    if truncated:
        out.append("| logs cut short by shutdown | %d |" % truncated)
    if failed:
        out.append("| logs that could not be parsed in full | %d |" % failed)
    out.append("")

    if total:
        by_kind = collections.Counter()
        uniq_by_kind = collections.Counter()
        for g in groups:
            by_kind[g.kind] += g.count
            uniq_by_kind[g.kind] += 1
        out.append("## By kind")
        out.append("")
        out.append("| kind | meaning | occurrences | unique |")
        out.append("|---|---|---:|---:|")
        for kind in sorted(by_kind, key=lambda k: (KIND_ORDER.index(k)
                                                  if k in KIND_ORDER
                                                  else len(KIND_ORDER))):
            out.append("| %s | %s | %d | %d |" % (
                kind, KIND_HELP.get(kind, ""), by_kind[kind], uniq_by_kind[kind]))
        out.append("")

    def table(heading, items, note, offset):
        out.append("## " + heading)
        out.append("")
        if note:
            out.append(note)
            out.append("")
        if not items:
            out.append("None.")
            out.append("")
            return
        out.append("| # | kind | where | what | occurrences | processes |")
        out.append("|---:|---|---|---|---:|---:|")
        for i, g in enumerate(items, offset):
            e = g.example
            fn, loc, top_fn = where_parts(e, source_root)
            where = ("`%s` %s" % (fn, loc)) if fn else loc
            if top_fn:
                where += " (top of stack: `%s`)" % top_fn
            out.append("| %d | %s | %s | %s | %d | %d |" % (
                i, g.kind, md_escape(where), md_escape(e.what), g.count, len(g.pids)))
        out.append("")

    table("Errors in spock code", spock_groups,
          "At least one frame of the stack is in spock.so, spock_output.so "
          "or a spock source file.", 1)
    table("Errors elsewhere", other_groups,
          "No spock frame on the stack: PostgreSQL itself, libc or another "
          "library.  Worth a suppression in spock.supp or an upstream report.",
          len(spock_groups) + 1)
    return "\n".join(out), spock_groups, other_groups


def details_markdown(spock_groups, other_groups, source_root):
    out = []
    out.append("## Details")
    out.append("")
    n = 0
    for heading, items in (("spock", spock_groups), ("elsewhere", other_groups)):
        if not items:
            continue
        for g in items:
            n += 1
            e = g.example
            out.append("### %d. %s" % (n, group_title(g, source_root)))
            out.append("")
            out.append("%s. Seen %d time(s) in %d process(es)%s." % (
                e.what, g.count, len(g.pids),
                "" if heading == "spock" else ", no spock frame"))
            if e.args:
                out.append("")
                out.append("First seen in: `%s` (pid %s)" % (md_escape(e.args), e.pid))
            out.append("")
            out.append("```")
            out.append(render_stack(e.stack))
            for text, frames in e.aux:
                out.append("")
                out.append(text)
                if frames:
                    out.append(render_stack(frames))
            out.append("```")
            out.append("")
            if e.suppression:
                out.append("<details><summary>Suppression (for spock.supp)</summary>")
                out.append("")
                out.append("```")
                out.append(e.suppression)
                out.append("```")
                out.append("")
                out.append("</details>")
                out.append("")
    return "\n".join(out)


# ---------------------------------------------------------------------------
# HTML
# ---------------------------------------------------------------------------

HTML_HEAD = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>%(title)s</title>
<style>
:root { --bg:#fff; --fg:#1b1f23; --muted:#57606a; --line:#d0d7de; --head:#f6f8fa;
        --bad:#cf222e; --warn:#9a6700; --ok:#1a7f37; --code:#f6f8fa; }
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) { --bg:#0d1117; --fg:#e6edf3; --muted:#8b949e;
        --line:#30363d; --head:#161b22; --bad:#ff7b72; --warn:#d29922; --ok:#3fb950;
        --code:#161b22; }
}
body { margin:0; padding:24px 16px; background:var(--bg); color:var(--fg);
       font:15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif; }
main { max-width:1100px; margin:0 auto; }
h1 { font-size:1.6em; margin:0 0 .3em; }
h2 { font-size:1.25em; margin:1.8em 0 .5em; border-bottom:1px solid var(--line); padding-bottom:.2em; }
h3 { font-size:1.05em; margin:1.4em 0 .4em; }
p.lead { font-size:1.1em; }
.ok { color:var(--ok); font-weight:600; } .bad { color:var(--bad); font-weight:600; }
table { border-collapse:collapse; width:100%%; margin:.5em 0 1em; font-size:.93em; }
th, td { border:1px solid var(--line); padding:5px 8px; text-align:left; vertical-align:top; }
th { background:var(--head); } td.num, th.num { text-align:right; white-space:nowrap; }
code, pre { font:13px/1.45 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace; }
pre { background:var(--code); border:1px solid var(--line); border-radius:6px;
      padding:10px 12px; overflow-x:auto; }
code { background:var(--code); padding:1px 4px; border-radius:4px; }
details { margin:.4em 0 1em; } summary { cursor:pointer; color:var(--muted); }
.kind { display:inline-block; padding:0 6px; border-radius:10px; font-size:.85em;
        border:1px solid var(--line); background:var(--head); white-space:nowrap; }
.muted { color:var(--muted); }
</style>
</head>
<body><main>
"""

HTML_FOOT = "</main></body></html>\n"


def h(s):
    return html.escape(s, quote=True)


def html_report(title, meta, logs, groups, source_root):
    total = sum(len(l.errors) for l in logs)
    spock_groups = [g for g in groups if g.in_spock]
    other_groups = [g for g in groups if not g.in_spock]
    truncated = sum(1 for l in logs if l.truncated)

    out = [HTML_HEAD % {"title": h(title)}]
    out.append("<h1>%s</h1>" % h(title))
    if total == 0:
        out.append('<p class="lead"><span class="ok">No errors.</span> '
                   "Valgrind reported nothing that the suppressions did not cover.</p>")
    else:
        out.append('<p class="lead"><span class="bad">%d error(s) in %d unique '
                   "place(s)</span>, %d of them in spock's own code.</p>"
                   % (total, len(groups), len(spock_groups)))

    out.append("<h2>Run</h2><table>")
    for k, v in meta:
        out.append("<tr><th>%s</th><td>%s</td></tr>" % (h(k), h(v)))
    out.append("<tr><th>processes analysed</th><td>%d</td></tr>" % len(logs))
    if truncated:
        out.append("<tr><th>logs cut short by shutdown</th><td>%d</td></tr>" % truncated)
    out.append("</table>")

    if total:
        by_kind = collections.Counter()
        uniq = collections.Counter()
        for g in groups:
            by_kind[g.kind] += g.count
            uniq[g.kind] += 1
        out.append("<h2>By kind</h2><table><tr><th>kind</th><th>meaning</th>"
                   '<th class="num">occurrences</th><th class="num">unique</th></tr>')
        for kind in sorted(by_kind, key=lambda k: (KIND_ORDER.index(k)
                                                  if k in KIND_ORDER else len(KIND_ORDER))):
            out.append('<tr><td><span class="kind">%s</span></td><td>%s</td>'
                       '<td class="num">%d</td><td class="num">%d</td></tr>'
                       % (h(kind), h(KIND_HELP.get(kind, "")), by_kind[kind], uniq[kind]))
        out.append("</table>")

    def table(heading, items, note, offset):
        out.append("<h2>%s</h2>" % h(heading))
        out.append('<p class="muted">%s</p>' % h(note))
        if not items:
            out.append("<p>None.</p>")
            return
        out.append('<table><tr><th class="num">#</th><th>kind</th><th>where</th>'
                   '<th>what</th><th class="num">occurrences</th>'
                   '<th class="num">processes</th></tr>')
        for i, g in enumerate(items, offset):
            e = g.example
            fn, loc, top_fn = where_parts(e, source_root)
            cell = ("<code>%s</code> %s" % (h(fn), h(loc))) if fn else h(loc)
            if top_fn:
                cell += ' <span class="muted">(top of stack: <code>%s</code>)</span>' % h(top_fn)
            out.append('<tr><td class="num"><a href="#err-%d">%d</a></td>'
                       '<td><span class="kind">%s</span></td><td>%s</td><td>%s</td>'
                       '<td class="num">%d</td><td class="num">%d</td></tr>'
                       % (i, i, h(g.kind), cell, h(e.what), g.count, len(g.pids)))
        out.append("</table>")

    table("Errors in spock code", spock_groups,
          "At least one frame of the stack is in spock.so, spock_output.so "
          "or a spock source file.", 1)
    table("Errors elsewhere", other_groups,
          "No spock frame on the stack: PostgreSQL itself, libc or another "
          "library.  Worth a suppression in spock.supp or an upstream report.",
          len(spock_groups) + 1)

    if groups:
        out.append("<h2>Details</h2>")
        for i, g in enumerate(spock_groups + other_groups, 1):
            e = g.example
            out.append('<h3 id="err-%d">%d. %s</h3>' % (i, i, h(group_title(g, source_root))))
            out.append("<p>%s. Seen %d time(s) in %d process(es)." % (
                h(e.what), g.count, len(g.pids)))
            if e.args:
                out.append(' <span class="muted">First seen in <code>%s</code> (pid %s).</span>'
                           % (h(e.args), h(str(e.pid))))
            out.append("</p>")
            body = [render_stack(e.stack)]
            for text, frames in e.aux:
                body.append("")
                body.append(text)
                if frames:
                    body.append(render_stack(frames))
            out.append("<pre>%s</pre>" % h("\n".join(body)))
            if e.suppression:
                out.append("<details><summary>Suppression (for spock.supp)</summary>"
                           "<pre>%s</pre></details>" % h(e.suppression))
    out.append(HTML_FOOT)
    return "\n".join(out)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--raw", required=True, help="directory of valgrind XML files")
    ap.add_argument("--out", required=True, help="where to write the report files")
    ap.add_argument("--title", default="Valgrind report")
    ap.add_argument("--meta", action="append", default=[],
                    help="KEY=VALUE shown in the Run table; repeatable")
    ap.add_argument("--source-root", default="",
                    help="strip this prefix from source paths")
    ap.add_argument("--fail-on-errors", action="store_true",
                    help="exit 3 when any error was found")
    ap.add_argument("--ignore-leaks", action="store_true",
                    help="drop Leak_* records (the run had leak checking off)")
    args = ap.parse_args(argv)

    if not os.path.isdir(args.raw):
        print("valgrind-report: not a directory: %s" % args.raw, file=sys.stderr)
        return 2
    os.makedirs(args.out, exist_ok=True)

    meta = []
    for m in args.meta:
        k, _, v = m.partition("=")
        meta.append((k.strip(), v.strip()))

    paths = sorted(glob.glob(os.path.join(args.raw, "*.xml")))
    logs = [parse_log(p) for p in paths]
    ignored_leaks = 0
    if args.ignore_leaks:
        for log in logs:
            kept = [e for e in log.errors if not e.is_leak]
            ignored_leaks += len(log.errors) - len(kept)
            log.errors = kept
        if ignored_leaks:
            meta.append(("leak records ignored (leak-check=no)", str(ignored_leaks)))
    groups = group_errors(logs)
    source_root = os.path.abspath(args.source_root) if args.source_root else ""

    summary_md, spock_groups, other_groups = summary_markdown(
        args.title, meta, logs, groups, source_root)
    details_md = details_markdown(spock_groups, other_groups, source_root)
    full_md = summary_md + "\n" + details_md if groups else summary_md
    generated = "\n\n<sub>Generated %s by tests/valgrind/valgrind-report.py</sub>\n" % (
        datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M UTC"))

    with open(os.path.join(args.out, "report.md"), "w", encoding="utf-8") as f:
        f.write(full_md + generated)
    with open(os.path.join(args.out, "summary.md"), "w", encoding="utf-8") as f:
        f.write(summary_md + "\n")
    with open(os.path.join(args.out, "report.html"), "w", encoding="utf-8") as f:
        f.write(html_report(args.title, meta, logs, groups, source_root))

    total = sum(len(l.errors) for l in logs)
    summary = {
        "title": args.title,
        "processes": len(logs),
        "truncated_logs": sum(1 for l in logs if l.truncated),
        "unparsed_logs": sum(1 for l in logs if l.parse_failed),
        "errors": total,
        "unique_errors": len(groups),
        "spock_unique_errors": len(spock_groups),
        "other_unique_errors": len(other_groups),
        "ignored_leaks": ignored_leaks,
        "by_kind": dict(collections.Counter(
            k for l in logs for k in (e.kind for e in l.errors))),
        "meta": dict(meta),
    }
    with open(os.path.join(args.out, "summary.json"), "w", encoding="utf-8") as f:
        json.dump(summary, f, indent=2, sort_keys=True)
        f.write("\n")

    print("valgrind-report: %d process log(s), %d error(s), %d unique "
          "(%d in spock code, %d elsewhere)" % (
              len(logs), total, len(groups), len(spock_groups), len(other_groups)))
    if args.fail_on_errors and total:
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
