# Cloud Agent base image for Project Marque.
#
# Bakes the toolchains into the image layer so every pod that boots from a build
# of this environment has them immediately. Toolchains installed at `install`
# time into system directories do NOT survive into pods booted from an
# environment build, so they must live in the image.
#
# Build context is the repository root (see .cursor/environment.json) so the
# setup script can be copied in; the rest of the repository is checked out
# separately by Cursor after the image is built.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# build-essential provides the C toolchain the Go race detector needs; sudo lets
# the `ubuntu` runtime user manage system paths; libfontconfig1 is dlopened by
# Godot's text server (absent from the minimal Ubuntu image). The setup script
# installs the rest of its own prerequisites (curl, wget, unzip, apt-transport-https).
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        sudo \
        build-essential \
        libfontconfig1 \
    && rm -rf /var/lib/apt/lists/*

# ubuntu:24.04 already ships an `ubuntu` user at uid 1000; give it passwordless
# sudo so the environment can manage system paths when needed.
RUN echo 'ubuntu ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/ubuntu \
    && chmod 0440 /etc/sudoers.d/ubuntu

# Install Go (apt), Godot 4.7 headless (binary), and PowerShell 7 (Microsoft PMC
# apt repo). Only the setup script is copied in, never the whole repository.
COPY scripts/cloud_agent_setup.sh /tmp/cloud_agent_setup.sh
RUN bash /tmp/cloud_agent_setup.sh --tools-only \
    && rm -f /tmp/cloud_agent_setup.sh \
    && rm -rf /var/lib/apt/lists/*

USER ubuntu
