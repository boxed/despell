#!/bin/bash
# Runs every tests/test_*.mojo (test_e2e.mojo needs build/despell: `pixi run test` builds it first).
set -u
cd "$(dirname "$0")/.."
failed=0
for f in tests/test_*.mojo; do
    if ! mojo run -I src "$f"; then
        failed=$((failed + 1))
    fi
done
if [ $failed -ne 0 ]; then
    echo "==> $failed test files failed"
    exit 1
fi
echo "==> all test files passed"
