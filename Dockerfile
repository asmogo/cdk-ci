# syntax=docker/dockerfile:1.7

# CI container with Nix runtime to isolate and run all tests defined in .github/workflows/ci.yml
#
# Usage examples:
#   Build image:
#     docker build -t cdk-ci-nix -f Dockerfile.ci.nix .
#
#   Run (mount repo; enable Docker access for integration tests):
#     docker run --rm -it \
#       -v "$PWD":/work \
#       -v /var/run/docker.sock:/var/run/docker.sock \
#       -w /work cdk-ci-nix \
#       bash -lc "nix --version && nix develop -i -L .#stable --command bash -lc 'PARALLEL=true MAX_PARALLEL_JOBS=8 TEST_SUBSET=full ./misc/test_matrix.sh'"
#
#   WASM tests:
#     docker run --rm -it -v "$PWD":/work -w /work cdk-ci-nix \
#       bash -lc "nix develop -i -L .#stable --command bash -lc 'RUN_WASM_TESTS=true ./misc/test_matrix.sh'"
#
#   Integration tests (requires host Docker socket mounted as above):
#     docker run --rm -it -v "$PWD":/work -v /var/run/docker.sock:/var/run/docker.sock -w /work cdk-ci-nix \
#       bash -lc "nix develop -i -L .#stable --command bash -lc 'RUN_INTEGRATION_TESTS=true ./misc/test_matrix.sh'"

FROM nixos/nix:2.21.2

SHELL ["/bin/sh", "-c"]

ENV PATH=/root/.nix-profile/bin:/nix/var/nix/profiles/default/bin:${PATH}
RUN set -eux; nix --version
# Configure Nix: enable flakes; accept flake config; keep outputs for caching layers
RUN set -eux; mkdir -p /etc/nix \
  && printf '%s\n' \
  'experimental-features = nix-command flakes' \
  'accept-flake-config = true' \
  'keep-outputs = true' \
  'keep-derivations = true' \
  > /etc/nix/nix.conf

# Optional: Add popular binary caches to speed up CI (public keys included)
## Uncomment if you want extra substituters beyond cache.nixos.org
## RUN printf '%s\n' \
##   'substituters = https://cache.nixos.org https://nix-community.cachix.org' \
##   'trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY= nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs=' \
##   >> /etc/nix/nix.conf

# Install Docker CLI, tini, jq via Nix profiles so they are globally available
RUN set -eux; \
  nix profile remove --impure git || true; \
  nix profile remove --impure curl || true; \
  nix profile remove --impure bash-interactive || true; \
  nix profile install --impure --accept-flake-config \
  nixpkgs#docker-client \
  nixpkgs#docker-compose \
  nixpkgs#bashInteractive \
  nixpkgs#tini \
  nixpkgs#jq \
  nixpkgs#git \
  nixpkgs#curl \
  nixpkgs#xz \
  nixpkgs#bzip2

# Pre-build devshell closures for faster cold starts (optional)
# Copy just flake files to leverage Docker layer cache
WORKDIR /prebuild
COPY flake.nix flake.lock ./
# Build each devShell closurelosure without entering it (succeeds without project sources)
# This pulls toolchains, just, typos, bitcoind, lnd, cln, etc. as referenced by devShells.
RUN set -eux; nix --version \
  && nix develop -i -L .#stable --command true || true \
  && nix develop -i -L .#msrv --command true || true \
  && nix develop -i -L .#nightly --command true || true \
  && nix develop -i -L .#integration --command true || true

# Runtime workdir for mounting the repository at /work
WORKDIR /work

# Ensure tini is PID 1 (proper signal handling for CI)
ENTRYPOINT ["tini", "-g", "--"]
CMD ["sh"]

# Install Docker Compose v2 CLI plugin so `docker compose` works
RUN mkdir -p /root/.docker/cli-plugins \
  && arch="$(uname -m)" \
  && case "$arch" in \
  x86_64) comp_url="https://github.com/docker/compose/releases/download/v2.29.7/docker-compose-linux-x86_64" ;; \
  aarch64) comp_url="https://github.com/docker/compose/releases/download/v2.29.7/docker-compose-linux-aarch64" ;; \
  arm64) comp_url="https://github.com/docker/compose/releases/download/v2.29.7/docker-compose-linux-aarch64" ;; \
  *) echo "Unsupported arch: $arch" && exit 1 ;; \
  esac \
  && curl -L "$comp_url" -o /root/.docker/cli-plugins/docker-compose \
  && chmod +x /root/.docker/cli-plugins/docker-compose \
  && docker compose version
