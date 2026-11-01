# The Ansible "control node": where you run ansible-playbook. Pinned version, runs as your own user id
# so every file it writes (like the encrypted vault file) belongs to you on the instance.
ARG PYTHON_IMAGE=python:3.12-slim
FROM ${PYTHON_IMAGE}
ARG HOST_UID=1000
ARG HOST_GID=1000

RUN apt-get update \
 && apt-get install -y --no-install-recommends openssh-client \
 && rm -rf /var/lib/apt/lists/* \
 && pip install --no-cache-dir ansible-core==2.18.1

RUN groupadd -g ${HOST_GID} ctl 2>/dev/null || true \
 && useradd -m -u ${HOST_UID} -g ${HOST_GID} -s /bin/bash ctl

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
USER ctl
WORKDIR /ansible
ENV ANSIBLE_CONFIG=/ansible/ansible.cfg
ENTRYPOINT ["/entrypoint.sh"]
