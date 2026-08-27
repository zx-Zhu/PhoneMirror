#!/bin/zsh
set -euo pipefail

RUN_DIR="${0:A:h}"
PROJECT_DIR="${RUN_DIR:h}"
cd "$PROJECT_DIR"
swift test "$@"
