#!/bin/zsh
set -euo pipefail

DEVECO_ROOT="${DEVECO_ROOT:-/Applications/DevEco-Studio.app/Contents}"
export DEVECO_SDK_HOME="${DEVECO_SDK_HOME:-$DEVECO_ROOT/sdk}"
if [[ -z "${HOS_SDK_HOME:-}" ]]; then
  if [[ -d "$DEVECO_ROOT/sdk/default/openharmony" ]]; then
    export HOS_SDK_HOME="$DEVECO_ROOT/sdk/default/openharmony"
  else
    echo "请设置 HOS_SDK_HOME 指向 HarmonyOS SDK。" >&2
    exit 1
  fi
fi
export PATH="$DEVECO_ROOT/tools/node/bin:$DEVECO_ROOT/tools/ohpm/bin:$DEVECO_ROOT/tools/hvigor/bin:$PATH"

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
ohpm install
hvigorw --mode module -p product=default -p module=entry@default -p buildMode=debug assembleHap --no-daemon

SIGNED="$ROOT/entry/build/default/outputs/default/entry-default-signed.hap"
UNSIGNED="$ROOT/entry/build/default/outputs/default/entry-default-unsigned.hap"
[[ -f "$SIGNED" ]] && echo "$SIGNED" || echo "$UNSIGNED"
