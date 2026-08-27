#!/bin/zsh
set -euo pipefail

RUN_DIR="${0:A:h}"
PROJECT_DIR="${RUN_DIR:h}"
COSIGN="$PROJECT_DIR/.hvigor/harmony-cosign"
SIGN_DIR="$PROJECT_DIR/companion/signature"
BUNDLE="com.zhuzhanxuan.phonemirror.companion"

mkdir -p "$PROJECT_DIR/.hvigor" "$SIGN_DIR"
if [[ ! -x "$COSIGN" ]]; then
  bash -c "$(curl -fsSL http://voffline.byted.org/download/tos/schedule/hopter/harmony-cosign/scripts/install.sh)" -- -b "$PROJECT_DIR/.hvigor"
fi

devices=$(hdc list targets 2>&1 | sed '/^[[:space:]]*$/d' | grep -v -E 'Connect server failed|List targets failed|\[Empty\]|Offline')
count=$(printf '%s\n' "$devices" | wc -l | tr -d ' ')
if [[ "$count" -ne 1 ]]; then
  echo "需要且只能连接一台在线鸿蒙设备，当前在线设备数：$count" >&2
  printf '%s\n' "$devices"
  exit 1
fi

"$COSIGN" update
"$COSIGN" sign -s Reading -p "$BUNDLE" -e "$SIGN_DIR" -o PhoneMirror_Companion_Debug
ls -lh "$SIGN_DIR"
