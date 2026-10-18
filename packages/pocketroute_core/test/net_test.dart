import 'package:pocketroute_core/pocketroute_core.dart';
import 'package:test/test.dart';

void main() {
  group('MacAddress', () {
    test('derived addresses are stable and locally administered unicast', () {
      final a = MacAddress.derived('pc1', 0);
      expect(MacAddress.derived('pc1', 0), a);
      expect(MacAddress.derived('pc1', 1), isNot(a));
      expect(MacAddress.derived('pc2', 0), isNot(a));
      expect(a.octets.first, 0x02);
      expect(a.isGroup, isFalse);
    });

    test('formats as dotted and hyphenated', () {
      const mac = MacAddress(0x02001a2b3c4d);
      expect(mac.toDotted(), '0200.1a2b.3c4d');
      expect(mac.toHyphenated(), '02-00-1A-2B-3C-4D');
    });

    test('broadcast is a group address', () {
      expect(MacAddress.broadcast.isBroadcast, isTrue);
      expect(MacAddress.broadcast.isGroup, isTrue);
    });
  });

  group('Ipv4Address', () {
    test('parses dotted quads and rejects malformed text', () {
      expect(Ipv4Address.parse('192.168.1.10').octets, [192, 168, 1, 10]);
      for (final bad in ['256.1.1.1', '1.2.3', '1.2.3.4.5', 'a.b.c.d', '']) {
        expect(Ipv4Address.tryParse(bad), isNull, reason: bad);
      }
    });

    test('knows contiguous masks', () {
      expect(Ipv4Address.parse('255.255.255.0').prefixLength, 24);
      expect(Ipv4Address.parse('255.255.255.255').prefixLength, 32);
      expect(Ipv4Address.parse('0.0.0.0').prefixLength, 0);
      expect(Ipv4Address.parse('255.0.255.0').prefixLength, isNull);
      expect(Ipv4Address.maskOfLength(20).toString(), '255.255.240.0');
    });

    test('subnet membership and usable hosts', () {
      final mask = Ipv4Address.parse('255.255.255.0');
      final host = Ipv4Address.parse('10.0.0.5');
      expect(host.sameSubnet(Ipv4Address.parse('10.0.0.200'), mask), isTrue);
      expect(host.sameSubnet(Ipv4Address.parse('10.0.1.5'), mask), isFalse);
      expect(host.isUsableHost(mask), isTrue);
      expect(Ipv4Address.parse('10.0.0.0').isUsableHost(mask), isFalse);
      expect(Ipv4Address.parse('10.0.0.255').isUsableHost(mask), isFalse);
      expect(
        Ipv4Address.parse('10.0.0.0')
            .isUsableHost(Ipv4Address.maskOfLength(31)),
        isTrue,
      );
    });
  });

  group('Scheduler', () {
    test('runs actions in tick order, zero delays within the same tick', () {
      final scheduler = Scheduler();
      final log = <String>[];
      scheduler
        ..schedule(5, () => log.add('5'))
        ..schedule(1, () {
          log.add('1');
          scheduler.schedule(0, () => log.add('1b'));
        })
        ..runUntilIdle();
      expect(log, ['1', '1b', '5']);
      expect(scheduler.now, 5);
      expect(scheduler.isIdle, isTrue);
    });

    test('advance stops at the end of the window', () {
      final scheduler = Scheduler();
      var ran = false;
      scheduler
        ..schedule(10, () => ran = true)
        ..advance(9);
      expect(ran, isFalse);
      expect(scheduler.now, 9);
      scheduler.advance(1);
      expect(ran, isTrue);
    });
  });
}
