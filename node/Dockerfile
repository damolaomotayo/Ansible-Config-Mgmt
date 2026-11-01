# A "server" for Ansible to manage: Ubuntu with SSH, Python and sudo, like a freshly launched cloud VM.
# The packages Ansible will install later (nginx, cron...) are only DOWNLOADED here, not installed, so the
# demo is fast and works without a second download, yet Ansible still does the real installation.
ARG UBUNTU_IMAGE=ubuntu:24.04
FROM ${UBUNTU_IMAGE}
ENV DEBIAN_FRONTEND=noninteractive

RUN rm -f /etc/apt/apt.conf.d/docker-clean \
 && apt-get update \
 && apt-get install -y --no-install-recommends openssh-server python3 python3-apt sudo ca-certificates curl \
 && apt-get install -y --no-install-recommends --download-only nginx cron logrotate jq htop

RUN useradd -m -s /bin/bash ansible \
 && echo 'ansible ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/ansible \
 && chmod 440 /etc/sudoers.d/ansible \
 && mkdir -p /run/sshd \
 && printf 'PasswordAuthentication no\nPermitRootLogin no\nPubkeyAuthentication yes\n' > /etc/ssh/sshd_config.d/10-lab.conf

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
EXPOSE 22 80
ENTRYPOINT ["/entrypoint.sh"]
