#!/bin/sh
# nix-direnv-kit install hook. Runs once at sandbox create.
#   setup.sh system   (as root)  hook env.sh into /etc/sandbox-persistent.sh
#   setup.sh user     (as agent) direnv config + interactive shell hooks
# Every step is idempotent: re-running leaves the same result.
set -eu

MARK='# nix-direnv-kit'

append_once() { # file line
  [ -f "$1" ] && grep -qF "$MARK" "$1" && return 0
  printf '\n%s\n%s\n' "$MARK" "$2" >>"$1"
}

system() {
  persist=/etc/sandbox-persistent.sh
  if [ ! -e "$persist" ]; then
    install -m 0644 -o 1000 -g 1000 /dev/null "$persist"
  fi
  append_once "$persist" \
    'if [ -f /usr/local/share/nix-direnv-kit/env.sh ]; then . /usr/local/share/nix-direnv-kit/env.sh; fi'

  # Optional host-side binary cache, included from /etc/nix/nix.conf.
  # priority=10 puts it before cache.nixos.org (40), which stays as the
  # fallback for anything the cache doesn't have or when it is down.
  # A short connect timeout keeps an unreachable cache from stalling Nix.
  cache_conf=/etc/nix/nix-direnv-kit.conf
  if [ -n "${NIX_DIRENV_KIT_LOCAL_CACHE:-}" ]; then
    printf '%s\n%s\n%s\n' "$MARK" \
      "substituters = ${NIX_DIRENV_KIT_LOCAL_CACHE}?priority=10 https://cache.nixos.org" \
      'connect-timeout = 5' >"$cache_conf"
    chmod 0644 "$cache_conf"
  else
    rm -f "$cache_conf"
  fi
}

user() {
  conf="${XDG_CONFIG_HOME:-$HOME/.config}/direnv"
  mkdir -p "$conf"

  # nix-direnv, plus a layout dir outside the workspace: the workspace is
  # shared with the host, and a host running nix-direnv itself would
  # otherwise read this sandbox's (Linux) cache and vice versa.
  if [ ! -e "$conf/direnvrc" ] || grep -qF "$MARK" "$conf/direnvrc"; then
    cat >"$conf/direnvrc" <<'EOF'
# nix-direnv-kit
source /nix/var/nix/profiles/default/share/nix-direnv/direnvrc

: "${XDG_CACHE_HOME:="${HOME}/.cache"}"
declare -A direnv_layout_dirs
direnv_layout_dir() {
  local hash path
  echo "${direnv_layout_dirs[$PWD]:=$(
    hash="$(sha1sum - <<<"$PWD" | head -c40)"
    path="${PWD//[^a-zA-Z0-9]/-}"
    echo "${XDG_CACHE_HOME}/direnv/layouts/${hash}${path}"
  )}"
}
EOF
  fi

  if [ ! -e "$conf/direnv.toml" ] || grep -qF "$MARK" "$conf/direnv.toml"; then
    {
      echo "$MARK"
      echo '[global]'
      echo 'hide_env_diff = true'
      if [ "${NIX_DIRENV_KIT_AUTO_ALLOW:-true}" = true ] && [ -n "${WORKSPACE_DIR:-}" ]; then
        ws=$(printf '%s' "$WORKSPACE_DIR" | sed 's/\\/\\\\/g; s/"/\\"/g')
        echo
        echo '[whitelist]'
        echo "prefix = [ \"$ws\" ]"
      fi
    } >"$conf/direnv.toml"
  fi

  # Interactive shells: direnv's prompt hook reloads on every cd.
  append_once "$HOME/.bashrc" \
    'if command -v direnv >/dev/null 2>&1; then eval "$(direnv hook bash)"; fi'
  if [ -e "$HOME/.zshrc" ]; then
    append_once "$HOME/.zshrc" \
      'if command -v direnv >/dev/null 2>&1; then eval "$(direnv hook zsh)"; fi'
  fi
}

case "${1:-}" in
  system) system ;;
  user) user ;;
  *) echo "usage: $0 system|user" >&2; exit 2 ;;
esac
