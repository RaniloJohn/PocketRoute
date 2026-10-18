/// An IPv4 address (RFC 791), stored as an unsigned 32-bit integer.
class Ipv4Address implements Comparable<Ipv4Address> {
  const Ipv4Address(this.value);

  factory Ipv4Address.parse(String text) =>
      tryParse(text) ?? (throw FormatException('Not an IPv4 address', text));

  /// Parses dotted-quad text such as `192.168.1.10`; null if malformed.
  static Ipv4Address? tryParse(String text) {
    final parts = text.split('.');
    if (parts.length != 4) return null;
    var value = 0;
    for (final part in parts) {
      if (part.isEmpty || part.length > 3 || !_digits.hasMatch(part)) {
        return null;
      }
      final octet = int.parse(part);
      if (octet > 255) return null;
      value = value * 256 + octet;
    }
    return Ipv4Address(value);
  }

  /// The contiguous mask with [length] leading one bits (0-32).
  factory Ipv4Address.maskOfLength(int length) {
    RangeError.checkValueInInterval(length, 0, 32, 'length');
    return Ipv4Address(_all - (_pow2(32 - length) - 1));
  }

  static const any = Ipv4Address(0);
  static const broadcast = Ipv4Address(_all);
  static const _all = 0xFFFFFFFF;
  static final _digits = RegExp(r'^[0-9]+$');

  final int value;

  List<int> get octets => [
    value ~/ 0x1000000 % 256,
    value ~/ 0x10000 % 256,
    value ~/ 0x100 % 256,
    value % 256,
  ];

  /// Prefix length if this is a contiguous mask such as 255.255.255.0, else null.
  int? get prefixLength {
    for (var length = 0; length <= 32; length++) {
      if (Ipv4Address.maskOfLength(length).value == value) return length;
    }
    return null;
  }

  Ipv4Address network(Ipv4Address mask) => Ipv4Address(value & mask.value);

  Ipv4Address directedBroadcast(Ipv4Address mask) =>
      Ipv4Address(network(mask).value + (_all - mask.value));

  bool sameSubnet(Ipv4Address other, Ipv4Address mask) =>
      network(mask) == other.network(mask);

  /// True if this address can be assigned to a host on a subnet with [mask]:
  /// not the network or broadcast address (except /31 and /32, RFC 3021).
  bool isUsableHost(Ipv4Address mask) {
    final length = mask.prefixLength;
    if (length == null || value == 0) return false;
    if (length >= 31) return true;
    return this != network(mask) && this != directedBroadcast(mask);
  }

  @override
  int compareTo(Ipv4Address other) => value.compareTo(other.value);

  @override
  bool operator ==(Object other) =>
      other is Ipv4Address && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => octets.join('.');
}

int _pow2(int exponent) {
  var result = 1;
  for (var i = 0; i < exponent; i++) {
    result *= 2;
  }
  return result;
}
