# Cloud Agent base image for Project Marque.
#
# Bakes the toolchains into the image layer so every pod that boots from a build
# of this environment has them immediately (toolchains installed at `install`
# time into system directories do not survive into pods booted from the build).
#
# Build context is the repository root (see .cursor/environment.json) so the
# setup script can be copied in; the rest of the repository is checked out
# separately by Cursor after the image is built.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# System packages: git/curl/unzip for setup, build-essential for the Go race
# detector's C toolchain, libicu74 + libssl3 for PowerShell's runtime.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        unzip \
        xz-utils \
        sudo \
        build-essential \
        libicu74 \
        libssl3 \
    && rm -rf /var/lib/apt/lists/*

# ubuntu:24.04 already ships an `ubuntu` user at uid 1000; give it passwordless
# sudo so the environment can manage system paths when needed.
RUN echo 'ubuntu ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/ubuntu \
    && chmod 0440 /etc/sudoers.d/ubuntu

# Install Go 1.27, Godot 4.7 (headless), and PowerShell 7 into /usr/local.
# Only the setup script is copied in, never the whole repository.
COPY scripts/cloud_agent_setup.sh /tmp/cloud_agent_setup.sh
RUN bash /tmp/cloud_agent_setup.sh --tools-only \
    && rm -f /tmp/cloud_agent_setup.sh

USER ubuntu
