#!/bin/zsh
set -euo pipefail

RUN_DIR="${0:A:h}"
PROJECT_DIR="${RUN_DIR:h}"
COMPANION_DIR="$PROJECT_DIR/companion"

chmod +x "$COMPANION_DIR/build_hap.sh"
"$COMPANION_DIR/build_hap.sh"
