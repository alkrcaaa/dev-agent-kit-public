# A stand-in for the remote target: reachable over SSH, nothing installed.
# Lets remote-qwen-install.sh be exercised end to end without pointing it at a
# real robot, which is exactly the machine you do not want to debug a shell
# script on.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git sudo python3 python3-venv rsync \
      openssh-server locales \
    && rm -rf /var/lib/apt/lists/*

RUN locale-gen en_US.UTF-8
ENV LANG=en_US.UTF-8

# Mirrors the shape of a Jetson login: an unprivileged user with sudo, keys
# only. Password auth stays off so the test cannot pass by prompting.
RUN useradd -m -s /bin/bash nvidia \
    && echo 'nvidia ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/nvidia \
    && mkdir -p /home/nvidia/.ssh && chmod 700 /home/nvidia/.ssh \
    && chown -R nvidia:nvidia /home/nvidia/.ssh \
    && mkdir -p /run/sshd \
    && sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config

EXPOSE 22
CMD ["/usr/sbin/sshd", "-D", "-e"]
