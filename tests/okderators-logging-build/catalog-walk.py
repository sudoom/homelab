#!/usr/bin/env python3
"""Upgrade-graph checks for one channel of a File-Based Catalog, for catalog-edit.sh.

Input: the JSON stream that `opm render <dir|image> -o json` prints (olm.package, olm.channel
and olm.bundle documents, concatenated). Standard library only; run it with `python3 -I`.

  catalog-walk.py heads RENDER PACKAGE CHANNEL
      Print the channel's heads, one per line: the entries that no other entry names in
      `replaces` or `skips`. That is operator-registry's model.Channel.Head(), the rule
      behind `opm validate`'s "multiple channel heads"; skipRange does not count there.

  catalog-walk.py walk RENDER PACKAGE CHANNEL HEAD [--installed CSV ...]
      Start from every channel entry and from every --installed CSV (a CSV a cluster may run
      that can be absent from this channel; its version is read from its name,
      <name>.v<version>) and follow OLM v0 upgrade edges forward: X -> Y when Y `replaces`
      X, Y `skips` X, or X's version is inside Y's `skipRange`. Y == X is never an edge: an
      entry whose own version is inside its own skipRange (6.6.0-<DATE> is a prerelease
      below 6.6.0) does not upgrade to itself.
      PASS when HEAD is the channel's only head, HEAD has the highest version in the
      channel, and from every start the only dead end (an entry with no outgoing edge) that
      can be reached is HEAD. Then OLM ends at HEAD whichever edge it takes at each step.
      Prints INFO lines (one shortest path per start) and a last line `PASS <detail>` or
      `FAIL <detail>`. Exit 0 on PASS, 1 on FAIL or bad input, 2 on wrong usage.

Versions and ranges follow blang/semver v4, the library OLM uses: semver 2.0.0 ordering
(a prerelease sorts below its release, numeric identifiers below alphanumeric ones), ranges
are comparators (<, <=, >, >=, =, ==, !=, !) joined by spaces (AND) and "||" (OR). A range
this script cannot parse is a FAIL, never a silent "no edge".
"""

import json
import re
import sys
from collections import deque

SEMVER = re.compile(
    r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
    r"(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?"
    r"(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$"
)
COMPARATOR = re.compile(r"^(>=|<=|!=|==|>|<|=|!)?(.+)$")
OPS = {
    ">=": lambda c: c >= 0,
    "<=": lambda c: c <= 0,
    ">": lambda c: c > 0,
    "<": lambda c: c < 0,
    "=": lambda c: c == 0,
    "==": lambda c: c == 0,
    "!=": lambda c: c != 0,
    "!": lambda c: c != 0,
}
NAME_VERSION = re.compile(r"\.v([0-9]+\.[0-9]+\.[0-9]+.*)$")


class BadInput(Exception):
    pass


def parse_version(text):
    m = SEMVER.match(text)
    if not m:
        raise BadInput("not a semver version: %r" % text)
    pre = tuple(m.group(4).split(".")) if m.group(4) else ()
    for ident in pre:
        if ident.isdigit() and len(ident) > 1 and ident[0] == "0":
            raise BadInput("numeric prerelease identifier with a leading zero: %r" % text)
    return (int(m.group(1)), int(m.group(2)), int(m.group(3)), pre)


def compare_prerelease(a, b):
    if a == b:
        return 0
    if not a:  # a release ranks above any of its prereleases
        return 1
    if not b:
        return -1
    for x, y in zip(a, b):
        if x == y:
            continue
        x_num, y_num = x.isdigit(), y.isdigit()
        if x_num and y_num:
            return -1 if int(x) < int(y) else 1
        if x_num:
            return -1
        if y_num:
            return 1
        return -1 if x < y else 1
    return -1 if len(a) < len(b) else 1


def compare(a, b):
    if a[:3] != b[:3]:
        return -1 if a[:3] < b[:3] else 1
    return compare_prerelease(a[3], b[3])


def parse_range(text):
    alternatives = []
    for alternative in text.split("||"):
        parts = alternative.split()
        if not parts:
            raise BadInput("empty alternative in range %r" % text)
        conditions = []
        for part in parts:
            m = COMPARATOR.match(part)
            op = m.group(1) or "="
            conditions.append((op, parse_version(m.group(2))))
        alternatives.append(conditions)
    return alternatives


def in_range(version, alternatives):
    return any(
        all(OPS[op](compare(version, bound)) for op, bound in conditions)
        for conditions in alternatives
    )


def load(render_path):
    with open(render_path) as f:
        text = f.read()
    decoder = json.JSONDecoder()
    docs, i = [], 0
    while True:
        while i < len(text) and text[i].isspace():
            i += 1
        if i >= len(text):
            return docs
        doc, i = decoder.raw_decode(text, i)
        docs.append(doc)


class Channel:
    def __init__(self, docs, package, channel):
        channels = [
            d for d in docs
            if d.get("schema") == "olm.channel" and d.get("package") == package
            and d.get("name") == channel
        ]
        if len(channels) != 1:
            raise BadInput("%d olm.channel documents for %s/%s" % (len(channels), package, channel))
        self.entries = channels[0].get("entries") or []
        if not self.entries:
            raise BadInput("channel %s/%s has no entries" % (package, channel))
        self.names = [e["name"] for e in self.entries]
        self.raw_version, self.version = {}, {}
        for d in docs:
            if d.get("schema") != "olm.bundle" or d.get("package") != package:
                continue
            found = [p["value"]["version"] for p in d.get("properties") or []
                     if p.get("type") == "olm.package"]
            if len(found) != 1:
                raise BadInput("bundle %s has %d olm.package properties" % (d.get("name"), len(found)))
            self.raw_version[d["name"]] = found[0]
            self.version[d["name"]] = parse_version(found[0])
        missing = [n for n in self.names if n not in self.version]
        if missing:
            raise BadInput("channel entries without a bundle: %s" % ", ".join(missing))
        self.ranges = {}
        for e in self.entries:
            if e.get("skipRange"):
                try:
                    self.ranges[e["name"]] = parse_range(e["skipRange"])
                except BadInput as err:
                    raise BadInput("entry %s skipRange %r: %s" % (e["name"], e["skipRange"], err))

    def heads(self):
        incoming = set()
        for e in self.entries:
            if e.get("replaces"):
                incoming.add(e["replaces"])
            incoming.update(e.get("skips") or [])
        return sorted(n for n in self.names if n not in incoming)

    def successors(self, name, version):
        out = []
        for e in self.entries:
            if e["name"] == name:
                continue
            how = []
            if e.get("replaces") == name:
                how.append("replaces")
            if name in (e.get("skips") or []):
                how.append("skips")
            rng = self.ranges.get(e["name"])
            if rng is not None and in_range(version, rng):
                how.append("skipRange")
            if how:
                out.append((e["name"], "+".join(how)))
        return out

    def walk(self, start, start_version):
        """BFS from start; returns (predecessor map, dead ends reached)."""
        prev = {start: None}
        queue = deque([start])
        dead = []
        while queue:
            name = queue.popleft()
            version = start_version if name == start and name not in self.version else self.version[name]
            nexts = self.successors(name, version)
            if not nexts:
                dead.append(name)
            for nxt, how in nexts:
                if nxt not in prev:
                    prev[nxt] = (name, how)
                    queue.append(nxt)
        return prev, dead


def path_to(prev, target):
    steps, node = [], target
    while prev[node] is not None:
        parent, how = prev[node]
        steps.append((parent, how, node))
        node = parent
    steps.reverse()
    if not steps:
        return target
    text = steps[0][0]
    for _, how, node in steps:
        text += " -(%s)-> %s" % (how, node)
    return text


def cmd_heads(render, package, channel):
    ch = Channel(load(render), package, channel)
    for name in ch.heads():
        print(name)
    return 0


def cmd_walk(render, package, channel, head, installed):
    ch = Channel(load(render), package, channel)
    failures = []

    heads = ch.heads()
    if heads != [head]:
        failures.append("heads %s, want %s" % (", ".join(heads) or "none", head))
    if head not in ch.version:
        failures.append("%s is not in the channel" % head)
    else:
        higher = [n for n in ch.names if n != head and compare(ch.version[n], ch.version[head]) >= 0]
        if higher:
            failures.append("%s is not the highest version: %s" % (head, ", ".join(higher)))
        if head in ch.ranges and in_range(ch.version[head], ch.ranges[head]):
            print("INFO %s: own version %s is inside its own skipRange %r (not an edge)"
                  % (head, ch.raw_version[head], next(e["skipRange"] for e in ch.entries if e["name"] == head)))

    starts = [(n, ch.version[n], "") for n in ch.names]
    absent = 0
    for csv in installed:
        if csv in ch.version:
            print("INFO installed %s is a channel entry" % csv)
            continue
        m = NAME_VERSION.search(csv)
        if not m:
            raise BadInput("cannot read a version from installed CSV name %r" % csv)
        starts.append((csv, parse_version(m.group(1)), " (installed, absent from the channel)"))
        absent += 1

    stranded = []
    for name, version, note in starts:
        prev, dead = ch.walk(name, version)
        if dead == [head]:
            print("INFO walk %s%s" % (path_to(prev, head), note))
        else:
            stranded.append("%s%s dead ends: %s" % (name, note, ", ".join(dead) or "none (cycle)"))
            print("INFO stranded %s%s, dead ends: %s" % (name, note, ", ".join(dead) or "none (cycle)"))
    if stranded:
        failures.append("stranded: " + "; ".join(stranded))

    if failures:
        print("FAIL " + " | ".join(failures))
        return 1
    print("PASS %d entries%s reach %s" % (
        len(ch.names), " + %d installed CSV absent from the channel" % absent if absent else "", head))
    return 0


def main(argv):
    try:
        if len(argv) == 4 and argv[0] == "heads":
            return cmd_heads(*argv[1:])
        if len(argv) >= 5 and argv[0] == "walk":
            installed, rest = [], argv[5:]
            while rest:
                if rest[0] != "--installed" or len(rest) < 2:
                    break
                installed.append(rest[1])
                rest = rest[2:]
            if not rest:
                return cmd_walk(argv[1], argv[2], argv[3], argv[4], installed)
    except (BadInput, OSError, ValueError, KeyError) as err:
        print("FAIL bad input: %s" % err)
        return 1
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
