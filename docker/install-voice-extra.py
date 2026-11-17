"""Install the hermes-agent[voice] extra into the current interpreter.

``pip install hermes-agent[voice]`` re-resolves the distribution baked into
the image and fails: its Requires-Dist includes a direct-URL kittentts
requirement that packaging cannot parse. The voice pins are plain
name==version lines, so read them from the installed metadata and install
those. That is the same set the extra declares (faster-whisper, av,
sounddevice, numpy, with their dependencies).
"""

from __future__ import annotations

import importlib.metadata as metadata
import subprocess
import sys


def voice_requirements() -> list[str]:
    reqs: list[str] = []
    for raw in metadata.requires("hermes-agent") or []:
        if "extra == 'voice'" not in raw and 'extra == "voice"' not in raw:
            continue
        reqs.append(raw.split(";", 1)[0].strip())
    if not reqs:
        raise SystemExit("hermes-agent[voice] has no installable requirements")
    return reqs


def main() -> None:
    reqs = voice_requirements()
    print("installing hermes-agent[voice]:", " ".join(reqs), flush=True)
    subprocess.check_call(
        [sys.executable, "-m", "pip", "install", "--no-cache-dir", *reqs]
    )


if __name__ == "__main__":
    main()
