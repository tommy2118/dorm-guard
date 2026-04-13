# Make sure RUBY_VERSION matches the Ruby version in .ruby-version
ARG RUBY_VERSION=4.0.0
FROM ghcr.io/rails/devcontainer/images/ruby:$RUBY_VERSION

# Ensure binding is always 0.0.0.0
# Binds the server to all IP addresses of the container, so it can be accessed from outside the container.
ENV BINDING="0.0.0.0"

# Install the Docker CLI (not the daemon) so `bin/dc kamal ...` can talk
# to the host Docker engine via the socket mounted in compose.yaml. The
# daemon runs on the host (Docker Desktop on macOS / the host daemon on
# Linux) — the container only needs the client binary.
#
# Debian's `docker.io` package ships only the daemon + docker-proxy +
# docker-init, NOT the `docker` CLI (the CLI is shipped as `docker-ce-
# cli` from Docker's own repo, which we'd have to add as a new apt
# source). Shortest-path fix: drop the static CLI binary from Docker's
# stable channel directly. No daemon, no extra repos, no apt churn.
#
# The Rails devcontainer base image runs RUN commands as the `vscode`
# non-root user by default, so root access needs an explicit switch.
ARG DOCKER_CLI_VERSION=27.3.1
ARG DOCKER_BUILDX_VERSION=0.19.0
USER root
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) docker_arch=x86_64; buildx_arch=amd64 ;; \
      arm64) docker_arch=aarch64; buildx_arch=arm64 ;; \
      *) echo "unsupported arch: $arch" && exit 1 ;; \
    esac; \
    # Docker CLI static binary
    curl -fsSL "https://download.docker.com/linux/static/stable/${docker_arch}/docker-${DOCKER_CLI_VERSION}.tgz" \
      -o /tmp/docker.tgz; \
    tar -xzf /tmp/docker.tgz -C /tmp; \
    install -m 0755 /tmp/docker/docker /usr/local/bin/docker; \
    rm -rf /tmp/docker /tmp/docker.tgz; \
    docker --version; \
    # docker buildx plugin (required by Kamal for cross-platform builds,
    # e.g. amd64 images built from an arm64 Mac). Distributed as a
    # single static binary from docker/buildx releases; dropped into
    # Docker CLI's plugin search path.
    mkdir -p /usr/local/libexec/docker/cli-plugins; \
    curl -fsSL "https://github.com/docker/buildx/releases/download/v${DOCKER_BUILDX_VERSION}/buildx-v${DOCKER_BUILDX_VERSION}.linux-${buildx_arch}" \
      -o /usr/local/libexec/docker/cli-plugins/docker-buildx; \
    chmod +x /usr/local/libexec/docker/cli-plugins/docker-buildx; \
    docker buildx version; \
    # Docker Desktop on macOS mounts /var/run/docker.sock as root:root
    # mode 660 inside the container. Add `vscode` to the root
    # supplementary group so it gets group-read/write on the socket.
    # This does NOT elevate vscode to root privileges — the user is
    # still uid 1000 — it just grants group-file-access to files
    # owned by the root group. Standard Docker-via-socket pattern for
    # Docker Desktop devcontainers.
    usermod -aG root vscode
USER vscode

# The base image installs Ruby via mise and activates it through .bashrc, which is only
# sourced for interactive shells. Add the mise binary AND its shims to PATH so
# non-interactive `docker compose exec` (and `bin/dc`) get a working ruby/bundle
# without sourcing .bashrc. Bundler shells out to `mise` directly during installs,
# so the mise binary itself (at ~/.local/bin/mise) must also be on PATH — not just
# the shims.
ENV PATH="/home/vscode/.local/bin:/home/vscode/.local/share/mise/shims:${PATH}"
