# syntax=docker/dockerfile:1
# Builds a self-contained /nix store holding nix, direnv and nix-direnv,
# plus a default profile, and ships it as an overlay on scratch so it
# lands on any sbx workload regardless of distro.
FROM nixos/nix:latest AS build
ARG NIXPKGS_REF
ARG NIX_FLAGS="--extra-experimental-features nix-command --extra-experimental-features flakes"

RUN set -eux; \
    nix ${NIX_FLAGS} profile install --profile /tmp/profile \
      "github:NixOS/nixpkgs/${NIXPKGS_REF}#nix" \
      "github:NixOS/nixpkgs/${NIXPKGS_REF}#direnv" \
      "github:NixOS/nixpkgs/${NIXPKGS_REF}#nix-direnv"; \
    profile="$(readlink -f /tmp/profile)"; \
    # Copy only the profile's closure into a fresh store rooted at /out.
    # This also writes /out/nix/var/nix/db, so the store is valid on arrival.
    nix ${NIX_FLAGS} copy --no-check-sigs --to /out "$profile"; \
    # A default profile with one generation, laid out the way nix expects,
    # so `nix profile install --profile /nix/var/nix/profiles/default` works.
    mkdir -p /out/nix/var/nix/profiles /out/nix/var/nix/gcroots/auto; \
    ln -s "$profile" /out/nix/var/nix/profiles/default-1-link; \
    ln -s default-1-link /out/nix/var/nix/profiles/default; \
    # Each claim is checked against what was installed.
    "$profile/bin/nix" --version; \
    "$profile/bin/direnv" version; \
    test -f "$profile/share/nix-direnv/direnvrc"

# Single-user Nix: the store belongs to the agent (uid 1000), no daemon.
RUN chown -R 1000:1000 /out/nix

COPY nix.conf /out/etc/nix/nix.conf
COPY scripts/env.sh /out/usr/local/share/nix-direnv-kit/env.sh
COPY --chmod=0755 scripts/setup.sh scripts/prewarm.sh /out/usr/local/libexec/nix-direnv-kit/
RUN chown -R 0:0 /out/etc /out/usr

FROM scratch
COPY --from=build /out/ /
# Appended to the workload's PATH at assembly.
ENV PATH="/nix/var/nix/profiles/default/bin:/home/agent/.nix-profile/bin:${PATH}"
