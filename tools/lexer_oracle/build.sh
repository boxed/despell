#!/bin/bash
# Builds build/lexer_oracle/dump: Mojo's own lexer (from Modular's open
# source compiler, at COMMIT) with stand-ins for the compiler parts it
# doesn't need for lexing (stubs/). Needs Homebrew's llvm@22 (or LLVM_CONFIG).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
out="$root/build/lexer_oracle"
commit="$(cat "$here/COMMIT")"
llvm_config="${LLVM_CONFIG:-/opt/homebrew/opt/llvm@22/bin/llvm-config}"
mkdir -p "$out/upstream"
for f in Mojo/lib/MojoParser/Lexer.cpp Mojo/include/Mojo/MojoParser/Lexer.h \
         Mojo/include/Mojo/MojoParser/TokenKinds.def; do
  if [ ! -f "$out/upstream/$f" ]; then
    mkdir -p "$out/upstream/$(dirname "$f")"
    curl -sfL "https://raw.githubusercontent.com/modular/modular/$commit/$f" -o "$out/upstream/$f"
  fi
done
# The crash reporter at the end of Lexer.cpp needs the whole parser state;
# lexing doesn't use it.
sed '/^\/\/ CrashReporter$/,$d' "$out/upstream/Mojo/lib/MojoParser/Lexer.cpp" > "$out/Lexer.cpp"
"$(dirname "$llvm_config")/clang++" -std=c++20 -O1 -w \
  -I "$here/stubs" -I "$out/upstream/Mojo/include" \
  $("$llvm_config" --cxxflags | sed 's/-std=c++[0-9]*//; s/-fno-exceptions//') \
  "$here/dump.cpp" "$out/Lexer.cpp" -o "$out/dump" \
  $("$llvm_config" --ldflags --libs support --system-libs)
echo "built $out/dump (Mojo's lexer at $commit)"
