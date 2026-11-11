#!/bin/sh
# nix-direnv-kit startup hook: build the workspace dev shell in the
# background so the agent's first command finds a warm nix-direnv cache.
# Never fails the boot; output goes to a log for debugging.
[ "${NIX_DIRENV_KIT_PREWARM:-true}" = true ] || exit 0
[ -n "${WORKSPACE_DIR:-}" ] && [ -f "$WORKSPACE_DIR/.envrc" ] || exit 0

log="${XDG_CACHE_HOME:-$HOME/.cache}/nix-direnv-kit/prewarm.log"
mkdir -p "$(dirname "$log")"
{
  echo "== $(date -u +%FT%TZ) prewarm $WORKSPACE_DIR"
  cd "$WORKSPACE_DIR" && direnv exec . true
  echo "== exit $?"
} >"$log" 2>&1
exit 0
