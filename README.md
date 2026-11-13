# nix-direnv-kit

A [Docker Sandboxes](https://docs.docker.com/ai/sandboxes/customize/author/) v3
**mixin** kit that adds [Nix](https://nixos.org) (single-user, flakes
enabled), [direnv](https://direnv.net) and
[nix-direnv](https://github.com/nix-community/nix-direnv) to any sbx workload.
The sandbox then loads the project's toolchain from the workspace `.envrc`
(for example `use flake`), both in your interactive shells and in the
commands the agent runs.

## Usage

The kit is published on Docker Hub as
[`docker.io/matthisk/nix-direnv-kit`](https://hub.docker.com/r/matthisk/nix-direnv-kit):

```sh
sbx run <WORKLOAD> ~/code/my-project --kit docker.io/matthisk/nix-direnv-kit:0.2.0
```

Docker Hub is in sbx's default `kit.allowedSources`, so no extra settings are
needed for the published kit. You can also use it from source:

```sh
# From a local checkout (the handle is the directory name,
# so pass ./nix-direnv-kit, not ./)
sbx run <WORKLOAD> ~/code/my-project --kit ./nix-direnv-kit

# From git
sbx run <WORKLOAD> --kit 'git+https://github.com/matthisk/nix-direnv-kit.git#ref=<COMMIT>'
```

Git kits must match `kit.allowedSources`, which defaults to Docker Hub only.
To use the git reference, allow the source first:

```sh
sbx settings set kit.allowedSources '["docker.io/","github.com/matthisk/"]'
```

`<WORKLOAD>` must be a **v3** workload kit. On sbx v0.50 the bare built-in
names (`shell`, `claude`, ...) still resolve to legacy templates unless a
shortcut is set, and passing `docker.io/sbx/shell:latest` directly is refused
because it collides with the built-in name. Point the shortcut at the v3 kit
once:

```sh
sbx settings set kit.shortcuts.shell  docker.io/sbx/shell:latest
sbx settings set kit.shortcuts.claude docker.io/sbx/claude:latest
sbx run claude ~/code/my-project --kit docker.io/matthisk/nix-direnv-kit:0.2.0
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
| `localCache` | empty | create | Binary cache URL tried before cache.nixos.org, for example `http://host.docker.internal:8080`. See [Local binary cache](#local-binary-cache) |

```sh
sbx run claude . --kit docker.io/matthisk/nix-direnv-kit:0.2.0 --kit-arg nix-direnv-kit.autoAllow=false
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
blocked. `host.docker.internal:8080` is also allowed, for the optional local
binary cache.

### Local binary cache

Every new sandbox starts with an empty `/nix/store` and downloads the whole
dev-shell closure again. A pull-through cache on the host makes every
sandbox after the first one fetch from local disk. `local-cache/nginx.conf`
is an nginx caching proxy for cache.nixos.org. It serves the upstream bytes
unchanged, so no extra trusted key is needed:

```sh
docker run -d --name nix-cache --restart unless-stopped \
  -p 127.0.0.1:8080:8080 \
  -v "$PWD/local-cache/nginx.conf:/etc/nginx/conf.d/default.conf:ro" \
  -v ~/.cache/nix-cache-proxy:/cache \
  nginx:alpine

sbx run claude . --kit docker.io/matthisk/nix-direnv-kit:<VERSION> \
  --kit-arg nix-direnv-kit.localCache=http://host.docker.internal:8080
```

The kit writes `/etc/nix/nix-direnv-kit.conf`, which `nix.conf` includes, with
the cache at priority 10 and cache.nixos.org (priority 40) as the fallback.
Nix falls back when the cache misses a path or is not running. A short
`connect-timeout` keeps an unreachable cache from stalling it. To check from
inside the sandbox, run
`curl -s http://host.docker.internal:8080/nix-cache-info` and
`nix config show substituters`. A cache on another host or port also needs
`sbx policy allow network <host>:<port>`.

## Develop

```sh
sbx kit validate ./nix-direnv-kit
sbx create --name ndk-test <WORKLOAD> ~/code/my-project --kit ./nix-direnv-kit
sbx exec ndk-test bash -c 'command -v <tool-from-your-devshell>'
```

Use a new sandbox name after each edit. Restarting an existing sandbox keeps
its recorded kit configuration.

## Publish

Bump `version:` in `nix-direnv-kit.yaml`, then build and push both
architectures with the same tag:

```sh
docker login
docker buildx build . -f nix-direnv-kit.yaml \
  --platform linux/amd64,linux/arm64 \
  -t docker.io/matthisk/nix-direnv-kit:<VERSION> --push
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
