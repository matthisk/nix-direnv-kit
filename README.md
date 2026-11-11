# nix-direnv-kit

A [Docker Sandboxes](https://docs.docker.com/ai/sandboxes/customize/author/) v3
**mixin** kit that adds [Nix](https://nixos.org) (single-user, flakes
enabled), [direnv](https://direnv.net) and
[nix-direnv](https://github.com/nix-community/nix-direnv) to any sbx workload.
The sandbox then loads the project's toolchain from the workspace `.envrc`
(for example `use flake`), both in your interactive shells and in the
commands the agent runs.

## Usage

```sh
# From the directory that contains this kit (the handle is the directory name,
# so pass ./nix-direnv-kit, not ./)
sbx run <WORKLOAD> ~/code/my-project --kit ./nix-direnv-kit

# From git
sbx run <WORKLOAD> --kit 'git+https://github.com/matthisk/nix-direnv-kit.git#ref=<COMMIT>'
```

`<WORKLOAD>` must be a **v3** workload kit. On sbx v0.50 the bare built-in
names (`shell`, `claude`, ...) still resolve to legacy templates unless a
shortcut is set, and passing `docker.io/sbx/shell:latest` directly is refused
because it collides with the built-in name. Point the shortcut at the v3 kit
once:

```sh
sbx settings set kit.shortcuts.shell  docker.io/sbx/shell:latest
sbx settings set kit.shortcuts.claude docker.io/sbx/claude:latest
sbx run claude ~/code/my-project --kit ./nix-direnv-kit
```

The project needs an `.envrc`, for example:

```sh
use flake
```

### Args

| Arg | Default | Phase | Meaning |
|---|---|---|---|
| `nixpkgsRef` | `nixos-26.05` | build | nixpkgs ref that nix, direnv and nix-direnv are built from |
| `autoAllow` | `true` | create | Whitelist the workspace in `direnv.toml` so no `direnv allow` is needed |
| `prewarm` | `true` | create | Evaluate the workspace `.envrc` in the background on every start |

```sh
sbx run claude . --kit ./nix-direnv-kit --kit-arg nix-direnv-kit.autoAllow=false
```

## How it works

| Piece | Where | What |
|---|---|---|
| Nix store | `/nix`, owned by `agent` (uid 1000) | Closure of nix + direnv + nix-direnv, built with `nixos/nix` and shipped as a `FROM scratch` overlay. Single-user, no daemon. |
| Nix config | `/etc/nix/nix.conf` | `nix-command flakes`, `sandbox = false`, system CA store, `keep-outputs`. |
| PATH | image `ENV` | `/nix/var/nix/profiles/default/bin` and `~/.nix-profile/bin` are appended to the workload's PATH. |
| Agent shells | `/etc/sandbox-persistent.sh` → `env.sh` | sbx base images source this file from `BASH_ENV` (every non-interactive bash), `/etc/profile.d` (login shells) and `CLAUDE_ENV_FILE` (Claude Code). `env.sh` runs `direnv export bash` for the current directory. With a warm cache this takes about 30 ms. |
| Interactive shells | `~/.bashrc` (and `~/.zshrc` if present) | `eval "$(direnv hook bash)"`. |
| direnv config | `~/.config/direnv/direnvrc` | Sources nix-direnv and moves the layout dir to `~/.cache/direnv/layouts/…`. The workspace is shared with the host, so without this a host-side nix-direnv and the sandbox would overwrite each other's `.direnv` caches (macOS and Linux store paths). |
| Trust | `~/.config/direnv/direnv.toml` | `[whitelist] prefix = ["$WORKSPACE_DIR"]` when `autoAllow=true`. |
| Prewarm | startup hook | `direnv exec "$WORKSPACE_DIR" true` in the background. The log is at `~/.cache/nix-direnv-kit/prewarm.log`. |

### Network

At runtime the kit allows `cache.nixos.org`, `channels.nixos.org`,
`releases.nixos.org`, `tarballs.nixos.org`, `nixos.org`, and the GitHub hosts
used by `github:` flake inputs. Other substituters (for example Cachix) and
private flake hosts are refused until you allow them. To allow them, use
`sbx policy` or add a small mixin that declares
`com.docker.sandbox/network-policy@1`. Run `sbx policy log` to see what was
blocked.

## Develop

```sh
sbx kit validate ./nix-direnv-kit
sbx create --name ndk-test <WORKLOAD> ~/code/my-project --kit ./nix-direnv-kit
sbx exec ndk-test bash -c 'command -v <tool-from-your-devshell>'
```

Use a new sandbox name after each edit. Restarting an existing sandbox keeps
its recorded kit configuration.

## Publish

```sh
docker buildx build . -f nix-direnv-kit.yaml \
  --platform linux/amd64,linux/arm64 \
  -t docker.io/<NAMESPACE>/nix-direnv-kit:0.1.0 --push
```

## Limitations

- Agent command shells pick up the env only if they are bash. `env.sh` is a
  no-op in other shells, because `direnv export bash` emits bash syntax.
- The first evaluation of a flake can take minutes. Prewarm hides this when
  the agent starts later than the sandbox; otherwise the first command waits.
- Nix writes `flake.lock` into the workspace if it is missing, which is
  normal Nix behaviour.
- Single-user Nix with `sandbox = false`: the sandbox VM is the isolation
  boundary.
