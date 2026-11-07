#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BREW="${BREW_PREFIX:-$(brew --prefix)}"
mkdir -p .build
for test in image_formats frame_completion; do
    clang -fobjc-arc -Wall -Wextra -Werror -I"$BREW/include" "tests/$test.m" \
        -framework Foundation -framework ImageIO -framework CoreGraphics -o ".build/$test-tests"
    ".build/$test-tests"
done
