import 'ipv4.dart';
import 'mac_address.dart';

/// An Ethernet frame moving between ports.
class Frame {
  const Frame({
    required this.src,
    required this.dst,
    required this.payload,
    this.vlan,
  });

  final MacAddress src;
  final MacAddress dst;
  final Payload payload;

  /// IEEE 802.1Q VLAN ID, or null for an untagged frame.
  final int? vlan;

  /// This frame with the tag replaced (null removes it).
  Frame withVlan(int? vlan) => vlan == this.vlan
      ? this
      : Frame(src: src, dst: dst, payload: payload, vlan: vlan);

  @override
  String toString() =>
      'Frame($src -> $dst${vlan == null ? '' : ' vlan $vlan'}, $payload)';
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

/// A bridge identifier: priority, then MAC address as the tie-breaker.
class BridgeId implements Comparable<BridgeId> {
  const BridgeId(this.priority, this.mac);

  final int priority;
  final MacAddress mac;

  @override
  int compareTo(BridgeId other) => priority != other.priority
      ? priority.compareTo(other.priority)
      : mac.compareTo(other.mac);

  @override
  bool operator ==(Object other) =>
      other is BridgeId && other.priority == priority && other.mac == mac;

  @override
  int get hashCode => Object.hash(priority, mac);

  @override
  String toString() => '$priority/${mac.toDotted()}';
}

/// A spanning tree configuration BPDU (IEEE 802.1D). Sent untagged to
/// [groupAddress], which bridges consume and never forward.
final class Bpdu extends Payload {
  const Bpdu({
    required this.rootId,
    required this.rootCost,
    required this.bridgeId,
    required this.portId,
    this.topologyChange = false,
  });

  static const groupAddress = MacAddress(0x0180C2000000);

  final BridgeId rootId;
  final int rootCost;
  final BridgeId bridgeId;

  /// Sending port as (priority, number).
  final (int, int) portId;
  final bool topologyChange;

  @override
  String toString() => 'BPDU root=$rootId cost=$rootCost from $bridgeId';
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

enum IcmpErrorKind { netUnreachable, hostUnreachable, ttlExceeded }

/// ICMP destination unreachable or time exceeded (RFC 792), quoting the
/// packet that caused it.
final class IcmpError extends IpBody {
  const IcmpError(this.kind, this.original);

  final IcmpErrorKind kind;
  final Ipv4Packet original;

  @override
  String toString() => 'ICMP ${kind.name}';
}
