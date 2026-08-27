#!/bin/zsh
set -euo pipefail

RUN_DIR="${0:A:h}"
PROJECT_DIR="${RUN_DIR:h}"
"$PROJECT_DIR/scripts/build_app.sh"
open "$PROJECT_DIR/dist/PhoneMirror.app"
