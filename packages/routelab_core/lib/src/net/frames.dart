import 'ipv4.dart';
import 'mac_address.dart';

/// EtherType values carried in an Ethernet header (IEEE 802 / RFC 7042).
abstract final class EtherType {
  static const ipv4 = 0x0800;
  static const arp = 0x0806;
}

/// An Ethernet frame moving between ports.
class Frame {
  const Frame({required this.src, required this.dst, required this.payload});

  final MacAddress src;
  final MacAddress dst;
  final Payload payload;

  int get etherType => switch (payload) {
    ArpPacket() => EtherType.arp,
    Ipv4Packet() => EtherType.ipv4,
  };

  @override
  String toString() => 'Frame($src -> $dst, $payload)';
}

/// What an Ethernet frame carries.
sealed class Payload {
  const Payload();
}

enum ArpOperation { request, reply }

/// An ARP message (RFC 826) for IPv4 over Ethernet.
final class ArpPacket extends Payload {
  const ArpPacket({
    required this.operation,
    required this.senderMac,
    required this.senderIp,
    required this.targetMac,
    required this.targetIp,
  });

  final ArpOperation operation;
  final MacAddress senderMac;
  final Ipv4Address senderIp;

  /// All zeros in a request; the requester's address in a reply.
  final MacAddress targetMac;
  final Ipv4Address targetIp;

  @override
  String toString() => 'ARP ${operation.name} $senderIp -> $targetIp';
}

/// An IPv4 packet (RFC 791). Only the fields the simulator uses are modelled.
final class Ipv4Packet extends Payload {
  const Ipv4Packet({
    required this.src,
    required this.dst,
    required this.ttl,
    required this.body,
  });

  final Ipv4Address src;
  final Ipv4Address dst;
  final int ttl;
  final IpBody body;

  Ipv4Packet withTtl(int ttl) =>
      Ipv4Packet(src: src, dst: dst, ttl: ttl, body: body);

  @override
  String toString() => 'IPv4 $src -> $dst ttl=$ttl $body';
}

/// The upper-layer message inside an IPv4 packet.
sealed class IpBody {
  const IpBody();
}

/// ICMP echo request or reply (RFC 792).
final class IcmpEcho extends IpBody {
  const IcmpEcho({
    required this.isReply,
    required this.id,
    required this.seq,
    this.size = 32,
  });

  final bool isReply;
  final int id;
  final int seq;

  /// Data bytes, reported back by ping output.
  final int size;

  IcmpEcho toReply() => IcmpEcho(isReply: true, id: id, seq: seq, size: size);

  @override
  String toString() => 'ICMP echo ${isReply ? 'reply' : 'request'} seq=$seq';
}
