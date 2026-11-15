# Extended Hermes Agent image with local STT (faster-whisper), Cursor
# integration (Agent CLI + Hermes plugins), and common DevOps CLIs.
#
# Base image is produced by:
#   https://github.com/NousResearch/hermes-agent/blob/main/Dockerfile
# Published as: nousresearch/hermes-agent

ARG HERMES_IMAGE=nousresearch/hermes-agent
ARG HERMES_TAG=latest
FROM ${HERMES_IMAGE}:${HERMES_TAG}

ARG TARGETARCH
ARG BB_VERSION=0.6.0
ARG YQ_VERSION=v4.44.3
ARG HELM_VERSION=v3.16.3
ARG KUSTOMIZE_VERSION=v5.5.0
ARG KUBECTL_VERSION=v1.31.3

USER root

ENV DEBIAN_FRONTEND=noninteractive
# Keep Cursor Agent / OpenCode / user-local bins on PATH for supervised processes.
ENV PATH="/opt/cursor-agent/bin:/opt/opencode/bin:/usr/local/bin:/opt/hermes/bin:/opt/hermes/.venv/bin:/opt/data/.local/bin:${PATH}"

# ---------------------------------------------------------------------------
# System packages (skip if already present in the base image)
# ---------------------------------------------------------------------------
RUN set -eux; \
    apt-get -o Acquire::Retries=3 update; \
    apt-get -o Acquire::Retries=3 install -y --no-install-recommends \
        ca-certificates \
        curl \
        wget \
        gnupg \
        unzip \
        xz-utils \
        git \
        jq \
        ffmpeg \
        python3-pip \
        python3-venv \
        ; \
    # Extra/ffmpeg "principal" codec stack when the distro provides it.
    apt-get -o Acquire::Retries=3 install -y --no-install-recommends \
        libavcodec-extra \
        || apt-get -o Acquire::Retries=3 install -y --no-install-recommends \
            libavcodec-extra61 \
        || true; \
    rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Arch helpers + CLI tooling not reliably available via apt
# ---------------------------------------------------------------------------
RUN set -eux; \
    case "${TARGETARCH:-amd64}" in \
      amd64) GOARCH=amd64; ACLI_ARCH=amd64; BB_ARCH=amd64; YQ_ARCH=amd64 ;; \
      arm64) GOARCH=arm64; ACLI_ARCH=arm64; BB_ARCH=arm64; YQ_ARCH=arm64 ;; \
      *) echo "Unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    install -d /usr/local/bin /opt/cursor-agent/bin /opt/opencode/bin /opt/hermes/bundled/plugins; \
    \
    # --- yq (mikefarah) ---
    if ! command -v yq >/dev/null 2>&1; then \
      curl -fsSL --retry 3 \
        -o /usr/local/bin/yq \
        "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${YQ_ARCH}"; \
      chmod 0755 /usr/local/bin/yq; \
    fi; \
    \
    # --- GitHub CLI (gh) ---
    if ! command -v gh >/dev/null 2>&1; then \
      curl -fsSL --retry 3 https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg; \
      chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg; \
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list; \
      apt-get -o Acquire::Retries=3 update; \
      apt-get -o Acquire::Retries=3 install -y --no-install-recommends gh; \
      rm -rf /var/lib/apt/lists/*; \
    fi; \
    \
    # --- Helm ---
    if ! command -v helm >/dev/null 2>&1; then \
      curl -fsSL --retry 3 \
        "https://get.helm.sh/helm-${HELM_VERSION}-linux-${GOARCH}.tar.gz" \
        | tar -xz -C /tmp; \
      install -m 0755 "/tmp/linux-${GOARCH}/helm" /usr/local/bin/helm; \
      rm -rf "/tmp/linux-${GOARCH}"; \
    fi; \
    \
    # --- kubectl ---
    if ! command -v kubectl >/dev/null 2>&1; then \
      curl -fsSL --retry 3 \
        -o /usr/local/bin/kubectl \
        "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${GOARCH}/kubectl"; \
      chmod 0755 /usr/local/bin/kubectl; \
    fi; \
    \
    # --- kustomize ---
    if ! command -v kustomize >/dev/null 2>&1; then \
      curl -fsSL --retry 3 \
        "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F${KUSTOMIZE_VERSION}/kustomize_${KUSTOMIZE_VERSION}_linux_${GOARCH}.tar.gz" \
        | tar -xz -C /usr/local/bin kustomize; \
      chmod 0755 /usr/local/bin/kustomize; \
    fi; \
    \
    # --- Atlassian CLI (acli) ---
    if ! command -v acli >/dev/null 2>&1; then \
      curl -fsSL --retry 3 \
        -o /usr/local/bin/acli \
        "https://acli.atlassian.com/linux/latest/acli_linux_${ACLI_ARCH}/acli"; \
      chmod 0755 /usr/local/bin/acli; \
    fi; \
    \
    # --- Bitbucket CLI (bb / bbcli) ---
    if ! command -v bb >/dev/null 2>&1 && ! command -v bbcli >/dev/null 2>&1; then \
      curl -fsSL --retry 3 \
        -o /tmp/bb.deb \
        "https://github.com/craftamap/bb/releases/download/v${BB_VERSION}/bb_${BB_VERSION}_linux_${BB_ARCH}.deb"; \
      apt-get -o Acquire::Retries=3 update; \
      apt-get -o Acquire::Retries=3 install -y --no-install-recommends /tmp/bb.deb \
        || (cd /tmp && ar x bb.deb && tar -xf data.tar.* -C / && rm -f control.tar.* data.tar.* debian-binary); \
      rm -f /tmp/bb.deb; \
      rm -rf /var/lib/apt/lists/*; \
    fi; \
    if command -v bb >/dev/null 2>&1 && ! command -v bbcli >/dev/null 2>&1; then \
      ln -sf "$(command -v bb)" /usr/local/bin/bbcli; \
    fi; \
    \
    # --- pre-commit ---
    if ! command -v pre-commit >/dev/null 2>&1; then \
      if command -v uv >/dev/null 2>&1; then \
        uv pip install --system pre-commit || pip3 install --break-system-packages pre-commit; \
      else \
        pip3 install --break-system-packages pre-commit; \
      fi; \
    fi; \
    \
    # --- OpenCode ---
    if ! command -v opencode >/dev/null 2>&1; then \
      curl -fsSL https://opencode.ai/v2/install | bash -s -- --no-modify-path; \
      if [ -x "${HOME}/.opencode/bin/opencode" ]; then \
        cp -a "${HOME}/.opencode/bin/." /opt/opencode/bin/; \
      elif [ -x /root/.opencode/bin/opencode ]; then \
        cp -a /root/.opencode/bin/. /opt/opencode/bin/; \
      fi; \
      chmod -R a+rX /opt/opencode || true; \
    fi; \
    \
    # --- Cursor Agent CLI ---
    if ! command -v agent >/dev/null 2>&1 && ! command -v cursor-agent >/dev/null 2>&1; then \
      curl -fsSL https://cursor.com/install | bash; \
      if [ -d /root/.local/share/cursor-agent ]; then \
        cp -a /root/.local/share/cursor-agent /opt/cursor-agent/share; \
        latest="$(ls -1 /opt/cursor-agent/share/versions | sort | tail -n1)"; \
        ln -sfn "/opt/cursor-agent/share/versions/${latest}/cursor-agent" /opt/cursor-agent/bin/agent; \
        ln -sfn "/opt/cursor-agent/share/versions/${latest}/cursor-agent" /opt/cursor-agent/bin/cursor-agent; \
        ln -sfn /opt/cursor-agent/bin/agent /usr/local/bin/agent; \
        ln -sfn /opt/cursor-agent/bin/cursor-agent /usr/local/bin/cursor-agent; \
      elif [ -x /root/.local/bin/agent ]; then \
        cp -a /root/.local/bin/agent /usr/local/bin/agent; \
        cp -a /root/.local/bin/cursor-agent /usr/local/bin/cursor-agent 2>/dev/null || true; \
      fi; \
      chmod -R a+rX /opt/cursor-agent || true; \
    fi; \
    \
    # Sanity: fail the build if critical tools are still missing.
    for cmd in git jq yq ffmpeg gh helm kubectl kustomize acli pre-commit; do \
      command -v "$cmd" >/dev/null 2>&1 || { echo "missing required tool: $cmd" >&2; exit 1; }; \
    done; \
    command -v bb >/dev/null 2>&1 || command -v bbcli >/dev/null 2>&1 \
      || { echo "missing required tool: bb/bbcli" >&2; exit 1; }; \
    command -v opencode >/dev/null 2>&1 \
      || { echo "missing required tool: opencode" >&2; exit 1; }; \
    command -v agent >/dev/null 2>&1 || command -v cursor-agent >/dev/null 2>&1 \
      || { echo "missing required tool: Cursor Agent CLI" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Local STT: faster-whisper inside the Hermes runtime venv
# ---------------------------------------------------------------------------
RUN set -eux; \
    if [ -x /opt/hermes/.venv/bin/python ]; then \
      if command -v uv >/dev/null 2>&1; then \
        uv pip install --python /opt/hermes/.venv/bin/python faster-whisper; \
      else \
        /opt/hermes/.venv/bin/python -m pip install faster-whisper; \
      fi; \
      /opt/hermes/.venv/bin/python -c "import faster_whisper; print('faster-whisper OK', faster_whisper.__version__)"; \
    else \
      echo "Hermes venv not found at /opt/hermes/.venv" >&2; \
      exit 1; \
    fi

# ---------------------------------------------------------------------------
# Hermes Cursor plugins (bundled; seeded into $HERMES_HOME on first boot)
# ---------------------------------------------------------------------------
COPY docker/seed-cursor-plugins.sh /opt/hermes/docker/seed-cursor-plugins.sh
COPY docker/cont-init.d/03-seed-cursor-plugins /etc/cont-init.d/03-seed-cursor-plugins
RUN chmod 0755 /opt/hermes/docker/seed-cursor-plugins.sh /etc/cont-init.d/03-seed-cursor-plugins

RUN set -eux; \
    git clone --depth 1 https://github.com/neerazz/hermes-cursor-acp.git \
      /opt/hermes/bundled/plugins/cursor-acp; \
    git clone --depth 1 https://github.com/arnavprabhu/CursorProviderHermes.git \
      /opt/hermes/bundled/plugins/cursor-subscription-directsdk; \
    rm -rf \
      /opt/hermes/bundled/plugins/cursor-acp/.git \
      /opt/hermes/bundled/plugins/cursor-subscription-directsdk/.git; \
    chmod -R a+rX /opt/hermes/bundled/plugins

# Default STT hint config fragment (merged only when missing).
COPY config/stt.defaults.yaml /opt/hermes/bundled/stt.defaults.yaml

# Keep the base image's s6 ENTRYPOINT/CMD unchanged.
