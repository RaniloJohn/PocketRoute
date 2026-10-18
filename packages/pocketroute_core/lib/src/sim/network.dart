import '../net/frames.dart';
import '../net/mac_address.dart';
import 'scheduler.dart';
import 'transit.dart';

/// Cable kinds, each fitting one kind of port.
enum CableType {
  /// Copper between unlike devices (host or router to switch).
  copperStraight,

  /// Copper between like devices (switch to switch, router to router, host to
  /// router or host).
  copperCross,

  /// Point-to-point WAN link. The first end cabled is the DCE and must
  /// supply a clock rate before the line comes up.
  serial,

  /// Management access from a host's RS-232 port to a device console port.
  /// Carries no network traffic.
  console,
}

/// What a port physically is, and so which cable fits it.
enum PortMedium { ethernet, serial, console, rs232 }

/// A topology: devices, the links between their ports, and one shared clock.
class Network {
  Network({this.linkDelay = 1});

  /// Ticks a frame takes to cross any link.
  final int linkDelay;
  final Scheduler scheduler = Scheduler();

  /// Called for every frame put onto a cable (simulation mode watches this).
  void Function(Transit transit)? onTransmit;
  final _devices = <String, Device>{};
  final _links = <Link>[];

  Iterable<Device> get devices => _devices.values;

  List<Link> get links => List.unmodifiable(_links);

  Device? operator [](String id) => _devices[id];

  T add<T extends Device>(T device) {
    if (device._network != null) {
      throw StateError('${device.id} already belongs to a network');
    }
    if (_devices.containsKey(device.id)) {
      throw ArgumentError.value(device.id, 'device.id', 'Duplicate device id');
    }
    device._network = this;
    _devices[device.id] = device;
    return device;
  }

  void remove(Device device) {
    for (final port in device.allPorts) {
      final link = port.link;
      if (link != null) disconnect(link);
    }
    _devices.remove(device.id);
    device._network = null;
  }

  /// The cable that fits [a] and [b] and works between them, or null if the
  /// ports cannot be cabled together at all.
  static CableType? cableFor(Port a, Port b) {
    final media = {a.medium, b.medium};
    if (media.length == 1 && a.medium == PortMedium.ethernet) {
      return a.device.isSwitchLike == b.device.isSwitchLike
          ? CableType.copperCross
          : CableType.copperStraight;
    }
    if (media.length == 1 && a.medium == PortMedium.serial) {
      return CableType.serial;
    }
    if (media.length == 2 &&
        media.contains(PortMedium.console) &&
        media.contains(PortMedium.rs232)) {
      return CableType.console;
    }
    return null;
  }

  /// Whether [cable] physically fits both ports (it may still not work, e.g.
  /// a straight-through cable between two switches).
  static bool fits(CableType cable, Port a, Port b) => switch (cable) {
    CableType.copperStraight || CableType.copperCross =>
      a.medium == PortMedium.ethernet && b.medium == PortMedium.ethernet,
    CableType.serial =>
      a.medium == PortMedium.serial && b.medium == PortMedium.serial,
    CableType.console => cableFor(a, b) == CableType.console,
  };

  /// Cables [a] to [b]. With no [cable] the right one is chosen.
  Link connect(Port a, Port b, {CableType? cable}) {
    for (final port in [a, b]) {
      if (!identical(port.device._network, this)) {
        throw ArgumentError('${port.device.id} is not in this network');
      }
      if (port.link != null) {
        throw StateError('${port.device.id} ${port.name} is already cabled');
      }
    }
    if (identical(a.device, b.device)) {
      throw ArgumentError('Cannot cable a device to itself');
    }
    final chosen = cable ?? cableFor(a, b);
    if (chosen == null || !fits(chosen, a, b)) {
      throw ArgumentError(
        '${chosen?.name ?? 'No'} cable fits ${a.name} and ${b.name}',
      );
    }
    final link = Link._(this, a, b, chosen);
    a._link = link;
    b._link = link;
    _links.add(link);
    a._stateChanged();
    return link;
  }

  void disconnect(Link link) {
    if (!_links.remove(link)) return;
    link.a._link = null;
    link.b._link = null;
    link.a.device.portStateChanged(link.a);
    link.b.device.portStateChanged(link.b);
  }
}

/// A cable between two ports. Frames take [Network.linkDelay] ticks to cross.
class Link {
  Link._(this.network, this.a, this.b, this.cable);

  final Network network;

  /// The first end cabled; the DCE on a serial link.
  final Port a;
  final Port b;
  final CableType cable;

  Port otherEnd(Port port) => identical(port, a) ? b : a;

  /// The clocking end of a serial link.
  Port get dce => a;

  /// Whether this cable can carry traffic between its two ports: the right
  /// copper type for the devices, a clocked serial line, and never console.
  bool get works => switch (cable) {
    CableType.copperStraight => a.device.isSwitchLike != b.device.isSwitchLike,
    CableType.copperCross => a.device.isSwitchLike == b.device.isSwitchLike,
    CableType.serial => dce.clockRate != null,
    CableType.console => false,
  };

  void _carry(Port from, Frame frame) {
    final to = otherEnd(from);
    final now = network.scheduler.now;
    network.onTransmit?.call(
      Transit(
        link: this,
        from: from,
        to: to,
        frame: frame,
        sentAt: now,
        arrivesAt: now + network.linkDelay,
      ),
    );
    network.scheduler.schedule(network.linkDelay, () {
      // The cable may have been pulled or the port shut while in flight.
      if (identical(to._link, this) && to.isUp) to.device.receive(to, frame);
    });
  }
}

/// A physical port: Ethernet, serial, console or RS-232.
class Port {
  Port(
    this.device,
    this.name,
    this.shortName,
    this.index, {
    this._adminUp = true,
    this.medium = PortMedium.ethernet,
  }) : mac = MacAddress.derived(device.id, index);

  final Device device;

  /// Full name, e.g. `FastEthernet0/1`.
  final String name;

  /// Abbreviated name used in tables, e.g. `Fa0/1`.
  final String shortName;

  /// Position on the device; feeds the derived MAC address.
  final int index;
  final PortMedium medium;
  final MacAddress mac;
  String? description;
  bool _adminUp;
  int? _clockRate;
  Link? _link;

  Link? get link => _link;

  Port? get peer => _link?.otherEnd(this);

  bool get adminUp => _adminUp;

  set adminUp(bool value) {
    if (value == _adminUp) return;
    _adminUp = value;
    _stateChanged();
  }

  /// Serial clock in bit/s, needed on the DCE end of a serial link.
  int? get clockRate => _clockRate;

  set clockRate(int? value) {
    if (value == _clockRate) return;
    _clockRate = value;
    _stateChanged();
  }

  /// Line protocol up: cabled with a working cable, and enabled at both ends.
  bool get isUp {
    final link = _link;
    final peer = this.peer;
    return _adminUp &&
        link != null &&
        peer != null &&
        peer._adminUp &&
        link.works;
  }

  void send(Frame frame) {
    final link = _link;
    if (link != null && isUp) link._carry(this, frame);
  }

  void _stateChanged() {
    device.portStateChanged(this);
    final peer = this.peer;
    if (peer != null) peer.device.portStateChanged(peer);
  }

  @override
  String toString() => '${device.id}:$name';
}

/// Anything with ports that can sit on the canvas.
abstract class Device {
  Device(this.id, {required this.hostname});

  /// Stable id used in saved files and for derived MAC addresses.
  final String id;
  String hostname;
  Network? _network;

  /// Ports that carry traffic.
  List<Port> get ports;

  /// Management ports (console, RS-232) that carry none.
  List<Port> get managementPorts => const [];

  Iterable<Port> get allPorts => [...ports, ...managementPorts];

  /// Switches cross their copper pairs (MDI-X); hosts and routers do not.
  /// Decides whether a straight-through or crossover cable is needed.
  bool get isSwitchLike => false;

  Network get network =>
      _network ?? (throw StateError('$id has not been added to a network'));

  bool get isInNetwork => _network != null;

  Scheduler get scheduler => network.scheduler;

  /// Finds a port by full or short name, ignoring case.
  Port? port(String name) {
    final wanted = name.toLowerCase();
    for (final port in allPorts) {
      if (port.name.toLowerCase() == wanted ||
          port.shortName.toLowerCase() == wanted) {
        return port;
      }
    }
    return null;
  }

  /// Called when [frame] arrives on [port].
  void receive(Port port, Frame frame);

  /// Called when [port] is cabled, uncabled, enabled or shut down at either end.
  void portStateChanged(Port port) {}
}
