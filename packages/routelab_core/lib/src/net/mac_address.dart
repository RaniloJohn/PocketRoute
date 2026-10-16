/// A 48-bit IEEE 802 MAC address.
///
/// Stored as a plain integer. Arithmetic (not bit shifts) is used for the
/// 48-bit value so results match on the web, where bitwise operators work on
/// 32 bits only.
class MacAddress implements Comparable<MacAddress> {
  const MacAddress(this.value);

  /// A stable, locally administered unicast address for port [index] of the
  /// device with [deviceId]. Reloading a lab gives every port the same address.
  factory MacAddress.derived(String deviceId, int index) {
    var hash = 0;
    for (final unit in deviceId.codeUnits) {
      hash = (hash * 31 + unit) & 0xFFFFFFFF;
    }
    // Leading octet 0x02: locally administered, unicast.
    return MacAddress(0x020000000000 + hash * 0x100 + (index % 0x100));
  }

  static const broadcast = MacAddress(0xFFFFFFFFFFFF);

  final int value;

  List<int> get octets {
    final out = List<int>.filled(6, 0);
    var rest = value;
    for (var i = 5; i >= 0; i--) {
      out[i] = rest % 256;
      rest ~/= 256;
    }
    return out;
  }

  bool get isBroadcast => value == broadcast.value;

  /// True for broadcast and multicast addresses (I/G bit set).
  bool get isGroup => octets.first.isOdd;

  /// `0200.1a2b.3c01` style, as switch tables show it.
  String toDotted() {
    final hex = value.toRadixString(16).padLeft(12, '0');
    return '${hex.substring(0, 4)}.${hex.substring(4, 8)}.${hex.substring(8)}';
  }

  /// `02-00-1A-2B-3C-01` style, as a PC shows it.
  String toHyphenated() => octets
      .map((o) => o.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join('-');

  @override
  int compareTo(MacAddress other) => value.compareTo(other.value);

  @override
  bool operator ==(Object other) => other is MacAddress && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => toDotted();
}
