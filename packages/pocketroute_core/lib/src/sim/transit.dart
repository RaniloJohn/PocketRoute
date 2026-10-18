import '../net/frames.dart';
import 'network.dart';

/// What sort of traffic a frame is, for filtering and colouring.
enum FrameKind { arp, icmp, stp, other }

/// One frame put onto a cable: who sent it, who receives it, and when.
class Transit {
  const Transit({
    required this.link,
    required this.from,
    required this.to,
    required this.frame,
    required this.sentAt,
    required this.arrivesAt,
  });

  final Link link;
  final Port from;
  final Port to;
  final Frame frame;

  /// Simulated time in ticks (milliseconds).
  final int sentAt;
  final int arrivesAt;

  FrameKind get kind => frameKind(frame);

  String get description => describeFrame(frame);
}

FrameKind frameKind(Frame frame) => switch (frame.payload) {
  ArpPacket() => FrameKind.arp,
  Ipv4Packet(body: IcmpEcho() || IcmpError()) => FrameKind.icmp,
  Bpdu() => FrameKind.stp,
};

/// A one-line, plain-language summary of [frame] for the event list.
String describeFrame(Frame frame) {
  final tag = frame.vlan == null ? '' : '  [VLAN ${frame.vlan}]';
  final text = switch (frame.payload) {
    ArpPacket(operation: ArpOperation.request) && final arp =>
      'ARP request: who has ${arp.targetIp}? Tell ${arp.senderIp}',
    final ArpPacket arp =>
      'ARP reply: ${arp.senderIp} is at ${arp.senderMac.toDotted()}',
    Ipv4Packet(body: final IcmpEcho echo) && final ip =>
      'ICMP echo ${echo.isReply ? 'reply' : 'request'} '
          '${ip.src} to ${ip.dst}, TTL ${ip.ttl}',
    Ipv4Packet(body: final IcmpError error) && final ip =>
      'ICMP ${switch (error.kind) {
        IcmpErrorKind.ttlExceeded => 'time exceeded',
        IcmpErrorKind.hostUnreachable => 'host unreachable',
        IcmpErrorKind.netUnreachable => 'network unreachable',
      }} ${ip.src} to ${ip.dst}',
    final Bpdu bpdu =>
      'STP BPDU: root ${bpdu.rootId.mac.toDotted()}, cost ${bpdu.rootCost}',
  };
  return '$text$tag';
}
