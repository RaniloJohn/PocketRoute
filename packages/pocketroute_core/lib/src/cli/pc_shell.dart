import '../devices/pc.dart';
import '../net/ipv4.dart';
import '../protocols/ip_stack.dart';

/// The PC's command prompt: `ipconfig`, `ping` and `arp`, Windows style.
/// Arguments are parsed by hand; there is no abbreviation as on the switch.
class PcShell {
  PcShell(this.pc, {required this._write});

  final Pc pc;
  final void Function(String text) _write;
  bool busy = false;

  String get prompt => r'C:\>';

  void execute(String line) {
    final words = line.trim().split(RegExp(r'\s+'));
    if (words.first.isEmpty) return;
    final args = words.skip(1).toList();
    switch (words.first.toLowerCase()) {
      case 'ipconfig':
        _ipconfig(args);
      case 'ping':
        _ping(args);
      case 'arp':
        _arp(args);
      case 'tracert':
        _tracert(args);
      case 'help' || '?':
        _help();
      default:
        _writeln('Unknown command: ${words.first}. Type help for a list.');
    }
  }

  void _writeln([String line = '']) => _write('$line\n');

  void _help() {
    for (final (command, text) in const [
      ('arp -a', 'List the ARP cache'),
      ('arp -d', 'Clear the ARP cache'),
      ('help', 'Show this list'),
      ('ipconfig', 'Show IP settings (add /all for the MAC address)'),
      ('ipconfig IP MASK [GATEWAY]', 'Set a static IP address'),
      ('ping [-n COUNT] IP', 'Test reachability with ICMP echo'),
      ('tracert IP', 'List the routers on the path to an address'),
    ]) {
      _writeln('${command.padRight(28)}$text');
    }
  }

  void _ipconfig(List<String> args) {
    if (args.isEmpty || (args.length == 1 && args.single == '/all')) {
      _showConfig(all: args.isNotEmpty);
      return;
    }
    if (args.length < 2 || args.length > 3) {
      _writeln('Usage: ipconfig IP MASK [GATEWAY]');
      return;
    }
    final address = Ipv4Address.tryParse(args[0]);
    final mask = Ipv4Address.tryParse(args[1]);
    final gateway = args.length == 3 ? Ipv4Address.tryParse(args[2]) : null;
    if (address == null) return _writeln('Invalid IP address: ${args[0]}');
    if (mask == null || mask.prefixLength == null) {
      return _writeln('Invalid subnet mask: ${args[1]}');
    }
    if (!address.isUsableHost(mask)) {
      return _writeln('$address is not a usable host address with mask $mask');
    }
    if (args.length == 3 &&
        (gateway == null || !gateway.sameSubnet(address, mask))) {
      return _writeln('Default gateway must be on the same subnet: ${args[2]}');
    }
    pc.ip
      ..configure(address, mask)
      ..gateway = gateway;
  }

  void _showConfig({required bool all}) {
    final ip = pc.ip;
    String field(String label, Object? value) =>
        '   ${label.padRight(32, '.')}: ${value ?? ''}';
    _writeln();
    _writeln('${pc.nic.name} Connection:');
    _writeln();
    if (all) _writeln(field('Physical Address', pc.nic.mac.toHyphenated()));
    _writeln(field('IPv4 Address', ip.address ?? Ipv4Address.any));
    _writeln(field('Subnet Mask', ip.mask ?? Ipv4Address.any));
    _writeln(field('Default Gateway', ip.gateway ?? Ipv4Address.any));
    _writeln();
  }

  void _arp(List<String> args) {
    switch (args) {
      case ['-a']:
        final entries = pc.ip.arpEntries;
        if (entries.isEmpty) return _writeln('No ARP entries found.');
        _writeln();
        _writeln('  Internet Address      Physical Address      Type');
        entries.forEach(
          (ip, mac) => _writeln(
            '  ${ip.toString().padRight(22)}${mac.toHyphenated().padRight(22)}'
            'dynamic',
          ),
        );
        _writeln();
      case ['-d']:
        pc.ip.clearArp();
      default:
        _writeln('Usage: arp -a | arp -d');
    }
  }

  static const maxHops = 30;

  /// Probes with TTL 1, 2, 3... (three per hop) until the target answers.
  void _tracert(List<String> args) {
    final target = args.length == 1 ? Ipv4Address.tryParse(args.single) : null;
    if (target == null) return _writeln('Usage: tracert IP');
    busy = true;
    _writeln();
    _writeln('Tracing route to $target over a maximum of $maxHops hops:');
    _writeln();

    void finish(String? note) {
      if (note != null) _writeln(note);
      _writeln();
      _writeln('Trace complete.');
      busy = false;
    }

    void hop(int ttl) {
      final cells = <String>[];
      Ipv4Address? from;
      PingStatus? last;
      pc.ip.ping(
        target,
        count: 3,
        timeout: 4000,
        ttl: ttl,
        onResult: (result) {
          last = result.status;
          if (result.rtt != null) {
            cells.add('${result.rtt} ms');
            from = result.from;
          } else {
            cells.add('*');
          }
        },
        onDone: () {
          if (last == PingStatus.noRoute) {
            return finish('Transmit failed: no route to $target.');
          }
          final times = cells.map((c) => c.padLeft(6)).join(' ');
          _writeln(
            '${'$ttl'.padLeft(3)}  $times  ${from ?? 'Request timed out.'}',
          );
          if (last == PingStatus.reply) return finish(null);
          if (last == PingStatus.unreachable) {
            return finish('$from reports: Destination net unreachable.');
          }
          if (ttl >= maxHops) return finish(null);
          hop(ttl + 1);
        },
      );
    }

    hop(1);
  }

  void _ping(List<String> args) {
    var count = 4;
    String? targetText;
    for (var i = 0; i < args.length; i++) {
      if (args[i] == '-n' && i + 1 < args.length) {
        final n = int.tryParse(args[++i]);
        if (n == null || n < 1 || n > 100) {
          return _writeln('Count must be between 1 and 100.');
        }
        count = n;
      } else {
        targetText = args[i];
      }
    }
    if (targetText == null) return _writeln('Usage: ping [-n COUNT] IP');
    final target = Ipv4Address.tryParse(targetText);
    if (target == null) {
      return _writeln(
        'Ping could not find host $targetText. Use an IP address.',
      );
    }

    busy = true;
    final rtts = <int>[];
    var received = 0;
    _writeln();
    _writeln('Pinging $target with 32 bytes of data:');
    _writeln();
    pc.ip.ping(
      target,
      count: count,
      timeout: 4000,
      interval: 1000,
      onResult: (result) {
        // As on Windows, an ICMP error back from a router counts as received.
        if (result.rtt != null) received++;
        if (result.ok) rtts.add(result.rtt!);
        _writeln(switch (result.status) {
          PingStatus.reply =>
            'Reply from $target: bytes=${result.size} '
                'time=${result.rtt}ms TTL=${result.ttl}',
          PingStatus.unreachable =>
            'Reply from ${result.from}: Destination host unreachable.',
          PingStatus.ttlExceeded =>
            'Reply from ${result.from}: TTL expired in transit.',
          PingStatus.timeout => 'Request timed out.',
          PingStatus.noRoute => 'Transmit failed: no route to $target.',
        });
      },
      onDone: () {
        final lost = count - received;
        _writeln();
        _writeln('Ping statistics for $target:');
        _writeln(
          '    Packets: Sent = $count, Received = $received, '
          'Lost = $lost (${lost * 100 ~/ count}% loss),',
        );
        if (rtts.isNotEmpty) {
          final min = rtts.reduce((a, b) => a < b ? a : b);
          final max = rtts.reduce((a, b) => a > b ? a : b);
          final avg = rtts.reduce((a, b) => a + b) ~/ rtts.length;
          _writeln('Approximate round trip times in milli-seconds:');
          _writeln(
            '    Minimum = ${min}ms, Maximum = ${max}ms, '
            'Average = ${avg}ms',
          );
        }
        _writeln();
        busy = false;
      },
    );
  }
}
