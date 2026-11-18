#!/usr/bin/env python3
"""Check that every literal UI string in the Swift sources is in the string catalog, with French.

Run from the repo root (python3, no dependencies):

    python3 Scripts/check-strings.py            # report, exit 1 when something is missing
    python3 Scripts/check-strings.py --list     # also print where each missing string is used

It scans Packages/FlightKit/Sources and Apps (tests, previews and `#if DEBUG` blocks are skipped) for
string literals passed to Text("..."), Text(ui: "..."), Label("...", Button("...", Toggle("...",
TextField("...", SecureField("...", Picker("...", Section("...", Menu("...", Link("...",
.accessibilityLabel("..."), .accessibilityHint("..."), .accessibilityValue("..."), DatePicker("...",
SharePreview("...", ContentUnavailableView("...", .navigationTitle("..."), .help("..."),
.alert("...", .confirmationDialog("...", String(localized: "..."), Format.words("...") and
UIText.localized("...") (looked up as written, so an interpolated one is skipped).

Interpolations follow Xcode: `\\(x)` becomes a format specifier. The type is not known here, so a key
matches when some choice of %@, %lld, %ld, %d, %lf or %f (positional or not) gives a catalog key. The
report proposes the %@ form.

A string is reported when it is missing from Apps/Shared/Localizable.xcstrings, or when its entry has
no French value. Strings meant to stay as written (codes, units, brand names) go in
Scripts/check-strings-ignore.txt, one per line, exactly as reported; lines starting with # are comments.
"""

import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG = os.path.join(ROOT, "Apps", "Shared", "Localizable.xcstrings")
IGNORE = os.path.join(ROOT, "Scripts", "check-strings-ignore.txt")
SCAN = [os.path.join(ROOT, "Packages", "FlightKit", "Sources"), os.path.join(ROOT, "Apps")]
SKIP_DIRS = {".build", "Tests", "iOSUITests", "Web", "node_modules"}

# Calls whose first string literal argument is shown or spoken through the catalog.
CALLS = [
    r"\bText\(\s*ui:\s*",
    r"\bText\(\s*",
    r"\bLabel\(\s*",
    r"\bButton\(\s*",
    r"\bToggle\(\s*",
    r"\bTextField\(\s*",
    r"\bSecureField\(\s*",
    r"\bPicker\(\s*",
    r"\bSection\(\s*",
    r"\bMenu\(\s*",
    r"\bLink\(\s*",
    r"\.accessibilityLabel\(\s*",
    r"\.accessibilityHint\(\s*",
    r"\.accessibilityValue\(\s*",
    r"\bDatePicker\(\s*",
    r"\bSharePreview\(\s*",
    r"\bContentUnavailableView\(\s*",
    r"\.navigationTitle\(\s*",
    r"\.help\(\s*",
    r"\.alert\(\s*",
    r"\.confirmationDialog\(\s*",
    r"\bString\(\s*localized:\s*",
    r"\bFormat\.words\(\s*",
    r"\bUIText\.localized\(\s*",
]
CALL_RE = re.compile("(" + "|".join(CALLS) + ")")
LABEL_RE = re.compile(r"[A-Za-z_]\w*\s*:(?!:)")
SPEC = r"%(?:\d+\$)?(?:@|lld|ld|d|lf|f|llu|lu|u)"


def strip_debug(src):
    """The source with `#if DEBUG` blocks and `#Preview { }` bodies blanked (line count kept)."""
    out, lines, i = [], src.split("\n"), 0
    while i < len(lines):
        line = lines[i]
        s = line.strip()
        if s.startswith("#if DEBUG"):
            depth = 1
            out.append("")
            i += 1
            while i < len(lines) and depth:
                t = lines[i].strip()
                if t.startswith("#if"):
                    depth += 1
                elif t.startswith("#endif"):
                    depth -= 1
                elif depth == 1 and t.startswith("#else"):
                    # Keep the release branch.
                    out.append("")
                    i += 1
                    while i < len(lines):
                        u = lines[i].strip()
                        if u.startswith("#if"):
                            depth += 1
                        elif u.startswith("#endif"):
                            depth -= 1
                            if depth == 0:
                                break
                        out.append(lines[i])
                        i += 1
                    continue
                out.append("")
                i += 1
            out.append("")
            i += 1
            continue
        if s.startswith("#Preview"):
            depth = 0
            started = False
            while i < len(lines):
                depth += lines[i].count("{") - lines[i].count("}")
                started = started or "{" in lines[i]
                out.append("")
                i += 1
                if started and depth <= 0:
                    break
            continue
        out.append(line)
        i += 1
    return "\n".join(out)


def read_literal(src, i):
    """Parse the Swift string literal whose opening quote is at src[i - 1].

    Returns (pieces, end) where pieces is a list of str (text) and None (an interpolation), or None
    when the literal is not a plain one-line string.
    """
    pieces, buf = [], []
    n = len(src)
    while i < n:
        c = src[i]
        if c == '"':
            pieces.append("".join(buf))
            return pieces, i + 1
        if c == "\n":
            return None
        if c == "\\":
            nxt = src[i + 1] if i + 1 < n else ""
            if nxt == "(":
                pieces.append("".join(buf))
                buf = []
                i = skip_interpolation(src, i + 2)
                if i < 0:
                    return None
                pieces.append(None)
                continue
            if nxt == "u" and i + 2 < n and src[i + 2] == "{":
                j = src.index("}", i)
                buf.append(chr(int(src[i + 3:j], 16)))
                i = j + 1
                continue
            buf.append({"n": "\n", "t": "\t", "0": "\0", '"': '"', "'": "'", "\\": "\\"}.get(nxt, nxt))
            i += 2
            continue
        buf.append(c)
        i += 1
    return None


def skip_interpolation(src, i):
    """Index just past the `)` closing an interpolation that starts at src[i]."""
    depth, n = 1, len(src)
    while i < n:
        c = src[i]
        if c == '"':
            r = read_literal(src, i + 1)
            if r is None:
                return -1
            i = r[1]
            continue
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return i + 1
        elif c == "\n":
            return -1
        i += 1
    return -1


def argument_literals(src, i, runtime=False):
    """The literals of the first argument starting at src[i] that SwiftUI looks up in the catalog.

    The argument runs to the first top-level comma or closing parenthesis. Its literals count when the
    argument is a localized key: a literal on its own, a ternary or `??` whose every branch is a literal
    (or a closure returning one, as in `x.map { "Gate \\($0)" } ?? "No gate"`). A branch that is a String
    value, a literal passed to another call (`f("x")`), joined to more text ("a" + b), followed by a
    member access ("x".uppercased()) or a closure chained on (`.map { }.joined()`) make the argument a
    String, which SwiftUI shows as is: those are not reported. With `runtime` (Text(ui:), which looks
    the built String up), every top-level literal counts.
    """
    out, paren, brace, n = [], 0, 0, len(src)
    if LABEL_RE.match(src, i):
        return out  # A labelled argument (verbatim:, action:, isPresented:) is not a catalog key.

    def next_char(j):
        while j < n and src[j].isspace():
            j += 1
        return src[j] if j < n else ""

    first = next_char(i)
    while i < n:
        c = src[i]
        if c == '"':
            if src.startswith('"""', i):
                return []
            r = read_literal(src, i + 1)
            if r is None:
                return []
            pieces, end = r
            if paren == 0:
                after = next_char(end)
                if not runtime and after in (".", "+", "["):
                    return []  # "x".uppercased(), "a" + b: a String.
                out.append((pieces, i))
            i = end
            continue
        if c in "([":
            paren += 1
        elif c in ")]":
            if paren == 0:
                break
            paren -= 1
        elif paren == 0 and c == "{":
            brace += 1
        elif paren == 0 and c == "}":
            brace -= 1
            if not runtime and brace == 0 and next_char(i + 1) in (".", "+"):
                return []  # x.map { "..." }.joined(): a String.
        elif paren == 0 and brace == 0 and runtime:
            if c == ",":
                break
        elif paren == 0 and brace == 0:
            if c == "," :
                break
            if c == "+" :
                return []
            if c == "?" and src.startswith("??", i):
                if next_char(i + 2) != '"' or not out:
                    return []  # a ?? b where a side is a String value.
                i += 2
                continue
            if c == "?" and src[i + 1:i + 2] not in (".", "") and src[i - 1:i].isspace():
                if next_char(i + 1) not in ('"', "{"):
                    return []  # cond ? value : ...: a String branch.
            if c == ":" and next_char(i + 1) not in ('"', "{"):
                return []
        i += 1
    if first != '"' and not any(True for _ in out):
        return []
    return out


def pieces_key(pieces):
    """The %@ form of the key, the regex matching any specifier choice, and the interpolation count."""
    interpolated = any(p is None for p in pieces)
    key, rx, count = "", "", 0
    for p in pieces:
        if p is None:
            count += 1
            key += "%@"
            rx += SPEC
        else:
            # Xcode doubles a literal % only in keys that also carry a format specifier.
            text = p.replace("%", "%%") if interpolated else p
            key += text
            rx += re.escape(text)
    return key, re.compile("^" + rx + "$"), count


def has_words(s):
    return re.search(r"[A-Za-z]{2,}", re.sub(SPEC, "", s)) is not None


def scan():
    found = {}  # key -> (regex, interpolations, [locations])
    for base in SCAN:
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS and not d.endswith("Tests")]
            for name in sorted(filenames):
                if not name.endswith(".swift"):
                    continue
                path = os.path.join(dirpath, name)
                with open(path, encoding="utf-8") as fh:
                    src = strip_debug(fh.read())
                # Blank line comments so commented-out code is not read.
                src = re.sub(r"(?m)^[ \t]*//.*$", "", src)
                for m in CALL_RE.finditer(src):
                    runtime = "ui:" in m.group(1) or "UIText" in m.group(1)
                    for pieces, at in argument_literals(src, m.end(1), runtime=runtime):
                        if runtime and None in pieces:
                            continue  # Text(ui:) of an interpolated String is looked up as built.
                        key, rx, count = pieces_key(pieces)
                        if not has_words(key):
                            continue
                        line = src.count("\n", 0, at) + 1
                        entry = found.setdefault(key, (rx, count, []))
                        entry[2].append("%s:%d" % (os.path.relpath(path, ROOT), line))
    return found


def main():
    with open(CATALOG, encoding="utf-8") as fh:
        strings = json.load(fh)["strings"]
    french = {}
    for k, v in strings.items():
        unit = v.get("localizations", {}).get("fr", {})
        value = unit.get("stringUnit", {}).get("value")
        if value is None and "variations" in unit:
            value = "variations"
        french[k] = value
    ignore = set()
    if os.path.exists(IGNORE):
        with open(IGNORE, encoding="utf-8") as fh:
            ignore = {l.rstrip("\n") for l in fh if l.strip() and not l.startswith("#")}

    missing, untranslated = [], []
    for key, (rx, count, where) in sorted(scan().items()):
        if key in ignore:
            continue
        if count:
            hits = [k for k in strings if rx.match(k)]
        else:
            hits = [key] if key in strings else []
        if not hits:
            missing.append((key, where))
        elif not any(french.get(h) for h in hits):
            untranslated.append((key, where))

    verbose = "--list" in sys.argv
    for title, rows in (("Missing from the catalog", missing), ("No French value", untranslated)):
        if not rows:
            continue
        print("%s (%d):" % (title, len(rows)))
        for key, where in rows:
            print("  " + json.dumps(key, ensure_ascii=False))
            if verbose:
                for w in where:
                    print("      " + w)
    total = len(missing) + len(untranslated)
    print("check-strings: %d missing, %d without French" % (len(missing), len(untranslated)))
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main())
