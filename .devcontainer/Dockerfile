# Make sure RUBY_VERSION matches the Ruby version in .ruby-version
ARG RUBY_VERSION=4.0.0
FROM ghcr.io/rails/devcontainer/images/ruby:$RUBY_VERSION

# Ensure binding is always 0.0.0.0
# Binds the server to all IP addresses of the container, so it can be accessed from outside the container.
ENV BINDING="0.0.0.0"

# The base image installs Ruby via mise and activates it through .bashrc, which is only
# sourced for interactive shells. Add the mise binary AND its shims to PATH so
# non-interactive `docker compose exec` (and `bin/dc`) get a working ruby/bundle
# without sourcing .bashrc. Bundler shells out to `mise` directly during installs,
# so the mise binary itself (at ~/.local/bin/mise) must also be on PATH — not just
# the shims.
ENV PATH="/home/vscode/.local/bin:/home/vscode/.local/share/mise/shims:${PATH}"
