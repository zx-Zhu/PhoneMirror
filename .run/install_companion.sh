#!/bin/zsh
set -euo pipefail

RUN_DIR="${0:A:h}"
PROJECT_DIR="${RUN_DIR:h}"
COMPANION_DIR="$PROJECT_DIR/companion"
SIGNED="$COMPANION_DIR/entry/build/default/outputs/default/entry-default-signed.hap"
UNSIGNED="$COMPANION_DIR/entry/build/default/outputs/default/entry-default-unsigned.hap"

if [[ -f "$SIGNED" ]]; then
  HAP="$SIGNED"
elif [[ -f "$UNSIGNED" ]]; then
  echo "只找到 unsigned HAP，HarmonyOS 真机会拒绝安装。" >&2
  echo "请先在 DevEco Studio 为 com.zhuzhanxuan.phonemirror.companion 配置自动签名，再执行 ./.run/build_companion.sh。" >&2
  exit 2
else
  echo "Companion HAP 不存在，请先执行 ./.run/build_companion.sh" >&2
  exit 1
fi

hdc install -r "$HAP"
