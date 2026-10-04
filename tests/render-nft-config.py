#!/usr/bin/env python3
"""Render the nftables heredoc from install.sh with deterministic CI values."""

from pathlib import Path


root = Path(__file__).resolve().parent.parent
installer = (root / "install.sh").read_text(encoding="utf-8")
start_marker = "cat >/etc/nftables.d/vpngate.nft <<EOF\n"
start = installer.index(start_marker) + len(start_marker)
end = installer.index("\nEOF", start)
config = installer[start:end]

replacements = {
    "${WG_IF}": "wg0",
    "${WG_NETWORK}": "10.66.66.0/24",
    "${MARK}": "0x64",
    "${WAN_IF}": "eth0",
    "${AWG_IF}": "awg0",
    'include "/etc/nftables.d/vpngate-static/*.nft"': (
        f'include "{(root / "config" / "static").as_posix()}/*.nft"'
    ),
}
for source, rendered in replacements.items():
    config = config.replace(source, rendered)

if "${" in config:
    raise SystemExit("Unrendered shell variable remains in nftables configuration")

print(config)
