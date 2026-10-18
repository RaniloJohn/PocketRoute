# pocketroute_core

PocketRoute's simulation engine and IOS-style CLI, in pure Dart (no Flutter imports),
so it runs headless in `dart test` and can be reused on the web.

- `lib/src/net/`: addresses and frame types (MAC, IPv4, ARP, ICMP)
- `lib/src/sim/`: discrete-event scheduler, devices, ports, links
- `lib/src/protocols/`: MAC learning table, host IPv4 stack (ARP + ICMP echo)
- `lib/src/devices/`: PC and layer 2 switch
- `lib/src/cli/`: command-tree parser, console session, switch commands, PC shell

```bash
dart test
```
