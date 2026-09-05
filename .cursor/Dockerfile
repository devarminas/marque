# Project Marque Cloud Agent base image.
#
# Stable, slow-moving toolchains live here so they are cached in the image and
# not reinstalled on every boot. Repository-derived state (Go modules, the Godot
# import cache) is prepared by .cursor/install.sh after checkout instead.
#
# Versions are pinned to what STANDING-ORDERS.md and go.mod require:
#   Go 1.27.0, Godot 4.7.2 (Forward+ desktop build, run headless here).
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# build-essential supplies the C compiler `go test -race` needs (CGO_ENABLED=1);
# unzip unpacks the Godot release; git and curl are required in custom images.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        unzip \
        build-essential \
    && rm -rf /var/lib/apt/lists/*

# Go 1.27.0 (go.mod: `go 1.27.0`).
RUN curl -fsSL https://go.dev/dl/go1.27.0.linux-amd64.tar.gz -o /tmp/go.tar.gz \
    && tar -C /usr/local -xzf /tmp/go.tar.gz \
    && rm /tmp/go.tar.gz
ENV PATH="/usr/local/go/bin:${PATH}"

# Godot 4.7.2. The stock Linux binary links only against glibc and dlopens GL/X11
# lazily, so it runs headless (`--headless`) without a display or GPU libraries.
RUN curl -fsSL https://github.com/godotengine/godot/releases/download/4.7.2-stable/Godot_v4.7.2-stable_linux.x86_64.zip -o /tmp/godot.zip \
    && unzip -q /tmp/godot.zip -d /tmp \
    && mv /tmp/Godot_v4.7.2-stable_linux.x86_64 /usr/local/bin/godot \
    && chmod +x /usr/local/bin/godot \
    && rm /tmp/godot.zip

USER ubuntu
