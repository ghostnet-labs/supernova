ARG RUNNER_VERSION=2.338.0
FROM ghcr.io/actions/actions-runner:${RUNNER_VERSION}
ARG YQ_VERSION=4.54.1
ARG YQ_SHA256=189088da0c6429ec5178dfaab1a114805f6cab0b61b165ab236efedf1d57a71b
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl git jq zsh tmux python3 python3-venv \
    build-essential pkg-config unzip xz-utils rsync \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fsSL "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_arm64" -o /usr/local/bin/yq \
    && echo "${YQ_SHA256}  /usr/local/bin/yq" | sha256sum --check \
    && chmod 0755 /usr/local/bin/yq \
    && yq --version | grep -q "version v${YQ_VERSION}"
USER runner
RUN python3 -m venv /home/runner/tools-venv \
    && /home/runner/tools-venv/bin/pip install --no-cache-dir rich==14.3.3 textual==8.0.1
ENV PATH="/home/runner/tools-venv/bin:${PATH}"

