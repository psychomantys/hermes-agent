#!/bin/sh
# Seed bundled Cursor plugins + STT defaults into $HERMES_HOME.
# Safe to re-run: never overwrites an existing plugin checkout or STT block.
set -eu

HERMES_HOME="${HERMES_HOME:-/opt/data}"
BUNDLED="/opt/hermes/bundled/plugins"
PLUGINS_DIR="${HERMES_HOME}/plugins"
CONFIG_YAML="${HERMES_HOME}/config.yaml"
STT_DEFAULTS="/opt/hermes/bundled/stt.defaults.yaml"

mkdir -p "${PLUGINS_DIR}"

seed_plugin() {
  name="$1"
  src="${BUNDLED}/${name}"
  dst="${PLUGINS_DIR}/${name}"
  if [ ! -d "${src}" ]; then
    echo "seed-cursor-plugins: missing bundled plugin ${name}" >&2
    return 0
  fi
  if [ -e "${dst}" ]; then
    echo "seed-cursor-plugins: keeping existing ${dst}"
    return 0
  fi
  echo "seed-cursor-plugins: installing ${name} -> ${dst}"
  cp -a "${src}" "${dst}"
}

seed_plugin cursor-acp
seed_plugin cursor-subscription-directsdk

if [ -f "${CONFIG_YAML}" ] && command -v yq >/dev/null 2>&1; then
  enabled_count="$(yq -r '.plugins.enabled // [] | map(select(. == "cursor-acp")) | length' "${CONFIG_YAML}" 2>/dev/null || echo 0)"
  if [ "${enabled_count}" = "0" ]; then
    echo "seed-cursor-plugins: enabling cursor-acp in config.yaml"
    yq -i '.plugins.enabled = ((.plugins.enabled // []) + ["cursor-acp"] | unique)' "${CONFIG_YAML}"
  fi
  stt_type="$(yq -r '.stt | type' "${CONFIG_YAML}" 2>/dev/null || echo null)"
  if [ "${stt_type}" = "null" ] || [ "${stt_type}" = "!!null" ]; then
    if [ -f "${STT_DEFAULTS}" ]; then
      echo "seed-cursor-plugins: applying STT defaults"
      yq -i ".stt = load(\"${STT_DEFAULTS}\").stt" "${CONFIG_YAML}"
    fi
  fi
elif [ ! -f "${CONFIG_YAML}" ] && [ -f "${STT_DEFAULTS}" ]; then
  echo "seed-cursor-plugins: writing initial config.yaml with STT defaults"
  cp "${STT_DEFAULTS}" "${CONFIG_YAML}"
  if command -v yq >/dev/null 2>&1; then
    yq -i '.plugins.enabled = ["cursor-acp"]' "${CONFIG_YAML}"
  fi
fi

if command -v hermes >/dev/null 2>&1; then
  hermes plugins enable cursor-acp >/dev/null 2>&1 || true
fi

echo "seed-cursor-plugins: done"
