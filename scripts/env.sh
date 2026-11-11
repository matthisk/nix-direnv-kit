# nix-direnv-kit: load the working directory's .envrc into the current shell.
#
# Sourced from /etc/sandbox-persistent.sh, which BASH_ENV (every
# non-interactive bash), /etc/profile.d (login shells) and CLAUDE_ENV_FILE
# (Claude Code's per-command shells) all read. Must stay quiet and fast:
# with a warm nix-direnv cache `direnv export` is a few milliseconds.
#
# direnv evaluates .envrc in a child bash, which reads BASH_ENV again; the
# guard variable is set only in direnv's own environment to stop that
# recursion. `direnv export bash` prints bash syntax, so skip other shells.
if [ -n "${BASH_VERSION:-}" ] && [ -z "${__NIX_DIRENV_KIT_LOADING:-}" ] \
  && command -v direnv >/dev/null 2>&1; then
  eval "$(__NIX_DIRENV_KIT_LOADING=1 direnv export bash 2>/dev/null)"
fi
