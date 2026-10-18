# Sources

Every public specification or document consulted while writing PocketRoute. Behavior is
implemented from these; no text, output strings or assets are copied from proprietary
software. Add an entry before (or in the same commit as) code that relies on it.

| Source | Used for | First used |
| --- | --- | --- |
| RFC 791 — Internet Protocol | IPv4 header fields, TTL | 2026-10-16 |
| RFC 792 — Internet Control Message Protocol | Echo request/reply | 2026-10-16 |
| RFC 826 — An Ethernet Address Resolution Protocol | ARP request/reply, cache | 2026-10-16 |
| RFC 950 / RFC 4632 — Subnetting / CIDR | Masks, prefix length, network membership | 2026-10-16 |
| IEEE 802.1D (public summaries) — MAC bridges | Transparent bridging: learning, forwarding, flooding, aging | 2026-10-16 |
| IEEE 802 / RFC 7042 — IANA considerations for IEEE 802 parameters | EtherType values, locally administered MAC bit | 2026-10-16 |
| IEEE 802.1Q (public summaries) — VLAN tagging | VLAN IDs 1-4094, tagged/untagged ports, native VLAN | 2026-10-18 |
| IEEE 802.1D-1998 (public summaries) — Spanning Tree Protocol | Bridge/port IDs, priority vectors, port roles and states, path costs, timers, BPDU group address | 2026-10-18 |
| RFC 1812 — Requirements for IP Version 4 Routers | Forwarding, TTL decrement, longest-prefix match, no ICMP errors about ICMP errors | 2026-10-18 |
| RFC 792 — ICMP (destination unreachable, time exceeded) | Router error messages, traceroute behaviour | 2026-10-18 |
| RFC 3021 — 31-bit prefixes on point-to-point links | /31 host addresses | 2026-10-18 |
