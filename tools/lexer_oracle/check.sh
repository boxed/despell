#!/bin/bash
# Compares despell's tokenizer with Mojo's own lexer: on Modular's Mojo
# sources (the stdlib, and the compiler's parser tests) at COMMIT, despell's
# own sources, and any files or directories given as arguments.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
out="$root/build/lexer_oracle"
commit="$(cat "$here/COMMIT")"
"$here/build.sh"
(cd "$root" && pixi run mojo build -I src "$here/despell_tokens.mojo" -o "$out/despell_tokens")
if [ ! -d "$out/modular/.git" ] || [ "$(git -C "$out/modular" rev-parse HEAD)" != "$commit" ]; then
  rm -rf "$out/modular"
  git clone -q --filter=blob:none --no-checkout https://github.com/modular/modular.git "$out/modular"
  git -C "$out/modular" sparse-checkout set Mojo/stdlib Mojo/test/mojo-parser Mojo/examples
  git -C "$out/modular" checkout -q "$commit"
fi
python3 "$here/compare.py" "$out/modular/Mojo" "$root/src" "$root/e2e_projects" "$@"
