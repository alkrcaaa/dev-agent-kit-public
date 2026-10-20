# A freshly-formatted machine, as far as this kit is concerned: no ~/.claude,
# no ~/.claude.json, no .env, no nvm/npm/pipx/uv, and none of the state an
# established host accumulates. Nothing runs as a service here, so there is no
# HEALTHCHECK or volume to declare — the container exists to perform one
# install and be discarded.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
# Only what a stock Ubuntu box plus a human's first five minutes would have.
# Notably absent: unzip — its absence is what exposed the tflint abort.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git sudo python3 python3-venv locales \
    && rm -rf /var/lib/apt/lists/*

RUN locale-gen en_US.UTF-8
ENV LANG=en_US.UTF-8

# install.sh refuses to run as root, so the test needs a normal user that can
# still reach the package manager.
RUN useradd -m -s /bin/bash tester \
    && echo 'tester ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/tester

USER tester
WORKDIR /home/tester
ENV HOME=/home/tester SHELL=/bin/bash

COPY --chown=tester:tester run-in-container.sh /home/tester/run-in-container.sh
