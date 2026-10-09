"""Source-manifest helpers for the Hardware Planner management command."""

import hashlib
import json
from pathlib import Path
import sys


def source_hashes(source):
    root = source.parent.parent
    inputs = list(source.glob("*.swift")) + [
        source / "Info.plist",
        source / "install_support.py",
        root / "dotfiles/.bin/hardware-planner",
        source.parent / "lib/quit-app.sh",
        source.parent / "lib/HardwareReport.swift",
        source.parent / "lib/octicons/Octicons.swift",
        source.parent / "lib/octicons/LICENSE",
    ]
    return {
        str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in sorted(inputs)
    }


def main():
    action, source, bundle = sys.argv[1:]
    source, bundle = Path(source), Path(bundle)
    manifest = bundle / "Contents/Resources/SourceHashes.json"
    if action == "manifest":
        manifest.write_text(json.dumps(source_hashes(source), indent=2) + "\n")
    elif action == "verify":
        if json.loads(manifest.read_text()) != source_hashes(source):
            raise SystemExit("Installed sources do not match the build manifest")
    else:
        raise SystemExit("Unknown manifest action")


if __name__ == "__main__":
    main()
