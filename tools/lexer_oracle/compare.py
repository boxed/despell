"""Compare despell's tokenizer with Mojo's own lexer on Mojo files.

Usage: python3 compare.py <file or directory> ...

Runs build/lexer_oracle/dump (Mojo's lexer, see build.sh) and
build/lexer_oracle/despell_tokens on each file, and reports where they
disagree: a token's kind or extent, or which tokens start a line and how far
they're indented. Files Mojo's lexer rejects are counted, not compared.
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
BUILD = os.path.join(HERE, "..", "..", "build", "lexer_oracle")
KINDS = {
    "identifier": "name", "escaped_identifier": "name", "keyword": "name",
    "integer": "number", "float_num": "number",
    "string": "string", "t_string": "string",
}
OPEN = {"l_paren", "l_square", "l_brace"}
CLOSE = {"r_paren", "r_square", "r_brace"}


def tokens(tool, path):
    """(kind, start, end, indentation of a logical line's first token or -1)
    per token. Mojo's lexer gives every physical line's first token its
    indentation; one inside brackets doesn't start a logical line."""
    out = subprocess.run([os.path.join(BUILD, tool), path], capture_output=True, text=True, errors="replace")
    toks, errors = [], []
    depth = 0
    for line in out.stdout.splitlines():
        parts = line.split(" ", 4)
        if parts[0] == "error":
            errors.append(line)
            continue
        indent = int(parts[3])
        if tool == "dump":
            if depth > 0:
                indent = -1
            if parts[0] in OPEN:
                depth += 1
            elif parts[0] in CLOSE:
                depth = max(0, depth - 1)
            kind = KINDS.get(parts[0], "op")
        else:
            kind = parts[0]
        start, end = int(parts[1]), int(parts[2])
        if parts[0] == "escaped_identifier":
            # Mojo's spelling leaves out the backticks
            start, end = start - 1, end + 1
            indent = indent if indent < 0 else indent - 1
        toks.append((kind, start, end, indent))
    if out.returncode != 0:
        errors.append(out.stderr.strip()[:200])
    return toks, errors


def files(args):
    for a in args:
        if os.path.isdir(a):
            for d, _, names in os.walk(a):
                for n in sorted(names):
                    if n.endswith(".mojo") or n.endswith(".🔥"):
                        yield os.path.join(d, n)
        else:
            yield a


def where(source, offset):
    line = source.count(b"\n", 0, offset) + 1
    col = offset - (source.rfind(b"\n", 0, offset) + 1) + 1
    return f"{line}:{col}"


def main():
    compared = differ = rejected = 0
    for path in files(sys.argv[1:]):
        mojo, errors = tokens("dump", path)
        if errors:
            rejected += 1
            continue
        ours, crash = tokens("despell_tokens", path)
        compared += 1
        if crash:
            differ += 1
            print(f"{path}: despell's tokenizer failed: {crash[0]}")
            continue
        source = open(path, "rb").read()
        for a, b in zip(mojo, ours):
            if a != b:
                differ += 1
                text = source[a[1]:max(a[2], b[2])].decode(errors="replace")
                print(f"{path}:{where(source, min(a[1], b[1]))}: mojo {a} despell {b} {text!r:.60}")
                break
        else:
            if len(mojo) != len(ours):
                differ += 1
                print(f"{path}: mojo has {len(mojo)} tokens, despell {len(ours)}")
    print(f"{compared} files compared, {differ} differ, {rejected} rejected by Mojo's lexer")
    return 1 if differ else 0


if __name__ == "__main__":
    sys.exit(main())
