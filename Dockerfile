# syntax=docker/dockerfile:1.7
# Extended Hermes Agent image with local STT (faster-whisper), Cursor
# integration (Agent CLI + Hermes plugins), and common DevOps CLIs.
#
# Base image is produced by:
#   https://github.com/NousResearch/hermes-agent/blob/main/Dockerfile
# Published as: nousresearch/hermes-agent
#

ARG HERMES_IMAGE=nousresearch/hermes-agent
ARG HERMES_TAG=latest
FROM ${HERMES_IMAGE}:${HERMES_TAG}

ARG TARGETARCH
ARG BB_VERSION=0.6.0
ARG YQ_VERSION=v4.44.3
ARG HELM_VERSION=v3.16.3
ARG KUSTOMIZE_VERSION=v5.5.0
ARG KUBECTL_VERSION=v1.31.3

# Base image USER is root (s6 PID 1). Switch explicitly for installs, then restore.
USER root

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_ROOT_USER_ACTION=ignore \
    PATH="/opt/cursor-agent/bin:/opt/opencode/bin:/usr/local/bin:/opt/hermes/bin:/opt/hermes/.venv/bin:/opt/data/.local/bin:${PATH}"

# Seed scripts / defaults (copied before the install RUN so chmod/install stay one layer).
COPY docker/seed-cursor-plugins.sh /opt/hermes/docker/seed-cursor-plugins.sh
COPY docker/cont-init.d/03-seed-cursor-plugins /etc/cont-init.d/03-seed-cursor-plugins
COPY config/stt.defaults.yaml /opt/hermes/bundled/stt.defaults.yaml

# Single install layer: BuildKit cache mounts keep rebuilds fast without baking
# apt/pip caches into the image. pip installs use --no-cache-dir so site-packages
# are the only Python artifacts left behind.
RUN --mount=type=cache,id=hermes-agent-apt-cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,id=hermes-agent-apt-lists,target=/var/lib/apt,sharing=locked \
    --mount=type=cache,id=hermes-agent-pip,target=/root/.cache/pip,sharing=locked \
    --mount=type=cache,id=hermes-agent-downloads,target=/var/cache/downloads,sharing=locked \
    set -eux; \
    case "${TARGETARCH:-amd64}" in \
      amd64) GOARCH=amd64; ACLI_ARCH=amd64; BB_ARCH=amd64; YQ_ARCH=amd64 ;; \
      arm64) GOARCH=arm64; ACLI_ARCH=arm64; BB_ARCH=arm64; YQ_ARCH=arm64 ;; \
      *) echo "Unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    \
    # apt keeps its own docker-clean drop-in which deletes downloads; disable it
    # so the cache mounts are useful across builds.
    rm -f /etc/apt/apt.conf.d/docker-clean; \
    echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' \
      > /etc/apt/apt.conf.d/keep-cache; \
    \
    apt-get -o Acquire::Retries=3 update; \
    apt-get -o Acquire::Retries=3 install -y --no-install-recommends \
      ca-certificates \
      curl \
      gnupg \
      unzip \
      xz-utils \
      git \
      jq \
      pre-commit \
      ; \
    # Prefer distro ffmpeg codecs when available; base already ships ffmpeg.
    apt-get -o Acquire::Retries=3 install -y --no-install-recommends libavcodec-extra \
      || apt-get -o Acquire::Retries=3 install -y --no-install-recommends libavcodec-extra61 \
      || true; \
    if ! command -v ffmpeg >/dev/null 2>&1; then \
      apt-get -o Acquire::Retries=3 install -y --no-install-recommends ffmpeg; \
    fi; \
    \
    install -d \
      /usr/local/bin \
      /opt/cursor-agent/bin \
      /opt/opencode/bin \
      /opt/hermes/bundled/plugins \
      /var/cache/downloads; \
    \
    download() { \
      # download <url> <dest-basename>
      url="$1"; dest="/var/cache/downloads/$2"; \
      if [ ! -s "${dest}" ]; then \
        curl -fsSL --retry 3 -o "${dest}.partial" "${url}"; \
        mv "${dest}.partial" "${dest}"; \
      fi; \
      printf '%s\n' "${dest}"; \
    }; \
    \
    # --- yq ---
    if ! command -v yq >/dev/null 2>&1; then \
      yq_path="$(download \
        "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${YQ_ARCH}" \
        "yq_linux_${YQ_ARCH}_${YQ_VERSION}")"; \
      install -m 0755 "${yq_path}" /usr/local/bin/yq; \
    fi; \
    \
    # --- GitHub CLI ---
    if ! command -v gh >/dev/null 2>&1; then \
      curl -fsSL --retry 3 https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg status=none; \
      chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg; \
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list; \
      apt-get -o Acquire::Retries=3 update; \
      apt-get -o Acquire::Retries=3 install -y --no-install-recommends gh; \
    fi; \
    \
    # --- Helm ---
    if ! command -v helm >/dev/null 2>&1; then \
      helm_tgz="$(download \
        "https://get.helm.sh/helm-${HELM_VERSION}-linux-${GOARCH}.tar.gz" \
        "helm-${HELM_VERSION}-linux-${GOARCH}.tar.gz")"; \
      tar -xzf "${helm_tgz}" -C /tmp; \
      install -m 0755 "/tmp/linux-${GOARCH}/helm" /usr/local/bin/helm; \
      rm -rf "/tmp/linux-${GOARCH}"; \
    fi; \
    \
    # --- kubectl ---
    if ! command -v kubectl >/dev/null 2>&1; then \
      kubectl_bin="$(download \
        "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${GOARCH}/kubectl" \
        "kubectl_${KUBECTL_VERSION}_linux_${GOARCH}")"; \
      install -m 0755 "${kubectl_bin}" /usr/local/bin/kubectl; \
    fi; \
    \
    # --- kustomize ---
    if ! command -v kustomize >/dev/null 2>&1; then \
      kust_tgz="$(download \
        "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F${KUSTOMIZE_VERSION}/kustomize_${KUSTOMIZE_VERSION}_linux_${GOARCH}.tar.gz" \
        "kustomize_${KUSTOMIZE_VERSION}_linux_${GOARCH}.tar.gz")"; \
      tar -xzf "${kust_tgz}" -C /usr/local/bin kustomize; \
      chmod 0755 /usr/local/bin/kustomize; \
    fi; \
    \
    # --- Atlassian CLI ---
    if ! command -v acli >/dev/null 2>&1; then \
      acli_bin="$(download \
        "https://acli.atlassian.com/linux/latest/acli_linux_${ACLI_ARCH}/acli" \
        "acli_linux_${ACLI_ARCH}")"; \
      install -m 0755 "${acli_bin}" /usr/local/bin/acli; \
    fi; \
    \
    # --- Bitbucket CLI (bb / bbcli) ---
    if ! command -v bb >/dev/null 2>&1 && ! command -v bbcli >/dev/null 2>&1; then \
      bb_deb="$(download \
        "https://github.com/craftamap/bb/releases/download/v${BB_VERSION}/bb_${BB_VERSION}_linux_${BB_ARCH}.deb" \
        "bb_${BB_VERSION}_linux_${BB_ARCH}.deb")"; \
      apt-get -o Acquire::Retries=3 install -y --no-install-recommends "${bb_deb}" \
        || (cd /tmp && cp "${bb_deb}" ./bb.deb && ar x bb.deb \
            && tar -xf data.tar.* -C / \
            && rm -f control.tar.* data.tar.* debian-binary bb.deb); \
    fi; \
    if command -v bb >/dev/null 2>&1 && ! command -v bbcli >/dev/null 2>&1; then \
      ln -sfn "$(command -v bb)" /usr/local/bin/bbcli; \
    fi; \
    \
    \
    # --- OpenCode ---
    if ! command -v opencode >/dev/null 2>&1; then \
      curl -fsSL https://opencode.ai/v2/install | bash -s -- --no-modify-path; \
      if [ -x "${HOME}/.opencode/bin/opencode" ]; then \
        cp -a "${HOME}/.opencode/bin/." /opt/opencode/bin/; \
      elif [ -x /root/.opencode/bin/opencode ]; then \
        cp -a /root/.opencode/bin/. /opt/opencode/bin/; \
      fi; \
      rm -rf /root/.opencode "${HOME}/.opencode" 2>/dev/null || true; \
      chmod -R a+rX /opt/opencode; \
    fi; \
    \
    # --- Cursor Agent CLI ---
    if ! command -v agent >/dev/null 2>&1 && ! command -v cursor-agent >/dev/null 2>&1; then \
      curl -fsSL https://cursor.com/install | bash; \
      if [ -d /root/.local/share/cursor-agent ]; then \
        mkdir -p /opt/cursor-agent; \
        cp -a /root/.local/share/cursor-agent /opt/cursor-agent/share; \
        latest="$(ls -1 /opt/cursor-agent/share/versions | sort | tail -n1)"; \
        ln -sfn "/opt/cursor-agent/share/versions/${latest}/cursor-agent" /opt/cursor-agent/bin/agent; \
        ln -sfn "/opt/cursor-agent/share/versions/${latest}/cursor-agent" /opt/cursor-agent/bin/cursor-agent; \
        ln -sfn /opt/cursor-agent/bin/agent /usr/local/bin/agent; \
        ln -sfn /opt/cursor-agent/bin/cursor-agent /usr/local/bin/cursor-agent; \
      elif [ -x /root/.local/bin/agent ]; then \
        install -m 0755 /root/.local/bin/agent /usr/local/bin/agent; \
        if [ -x /root/.local/bin/cursor-agent ]; then \
          install -m 0755 /root/.local/bin/cursor-agent /usr/local/bin/cursor-agent; \
        fi; \
      fi; \
      rm -rf /root/.local/share/cursor-agent /root/.local/bin/agent /root/.local/bin/cursor-agent; \
      chmod -R a+rX /opt/cursor-agent; \
    fi; \
    \
    # --- faster-whisper into the Hermes runtime venv (pip only, no uv) ---
    if [ ! -x /opt/hermes/.venv/bin/python ]; then \
      echo "Hermes venv not found at /opt/hermes/.venv" >&2; \
      exit 1; \
    fi; \
    /opt/hermes/.venv/bin/python -m ensurepip --upgrade; \
    /opt/hermes/.venv/bin/python -m pip install --no-cache-dir --upgrade pip; \
    /opt/hermes/.venv/bin/python -m pip install --no-cache-dir faster-whisper; \
    /opt/hermes/.venv/bin/python -c "import faster_whisper; print('faster-whisper OK', faster_whisper.__version__)"; \
    # Remove pip from the sealed Hermes venv after installing runtime deps.
    /opt/hermes/.venv/bin/python -m pip uninstall -y pip setuptools wheel || true; \
    rm -rf /opt/hermes/.venv/bin/pip /opt/hermes/.venv/bin/pip3 \
      /opt/hermes/.venv/bin/pip[0-9]* 2>/dev/null || true; \
    find /opt/hermes/.venv -type d -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true; \
    find /opt/hermes/.venv -type f -name '*.pyc' -delete 2>/dev/null || true; \
    \
    # --- Bundle Cursor Hermes plugins ---
    git clone --depth 1 https://github.com/neerazz/hermes-cursor-acp.git \
      /opt/hermes/bundled/plugins/cursor-acp; \
    git clone --depth 1 https://github.com/arnavprabhu/CursorProviderHermes.git \
      /opt/hermes/bundled/plugins/cursor-subscription-directsdk; \
    rm -rf \
      /opt/hermes/bundled/plugins/cursor-acp/.git \
      /opt/hermes/bundled/plugins/cursor-subscription-directsdk/.git; \
    chmod 0755 \
      /opt/hermes/docker/seed-cursor-plugins.sh \
      /etc/cont-init.d/03-seed-cursor-plugins; \
    chmod -R a+rX /opt/hermes/bundled; \
    \
    # --- Sanity checks ---
    for cmd in git jq yq ffmpeg gh helm kubectl kustomize acli pre-commit; do \
      command -v "${cmd}" >/dev/null 2>&1 || { echo "missing required tool: ${cmd}" >&2; exit 1; }; \
    done; \
    command -v bb >/dev/null 2>&1 || command -v bbcli >/dev/null 2>&1 \
      || { echo "missing required tool: bb/bbcli" >&2; exit 1; }; \
    command -v opencode >/dev/null 2>&1 \
      || { echo "missing required tool: opencode" >&2; exit 1; }; \
    command -v agent >/dev/null 2>&1 || command -v cursor-agent >/dev/null 2>&1 \
      || { echo "missing required tool: Cursor Agent CLI" >&2; exit 1; }; \
    \
    # --- Strip build leftovers that would otherwise land in the image layer ---
    rm -rf \
      /tmp/* \
      /var/tmp/* \
      /root/.cache \
      /root/.npm \
      /root/.local \
      /root/.opencode \
      /root/.config \
      2>/dev/null || true; \
    find /opt/hermes/.venv -type d -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true

# Restore base image USER (s6 entrypoint expects root as PID 1).
USER root
