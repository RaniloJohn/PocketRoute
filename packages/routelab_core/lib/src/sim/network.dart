import '../net/frames.dart';
import '../net/mac_address.dart';
import 'scheduler.dart';

/// Cable kinds. Copper ports auto-negotiate crossover, so both types link up.
enum CableType { copperStraight, copperCross }

/// A topology: devices, the links between their ports, and one shared clock.
class Network {
  Network({this.linkDelay = 1});

  /// Ticks a frame takes to cross any link.
  final int linkDelay;
  final Scheduler scheduler = Scheduler();
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
    for (final port in device.ports) {
      final link = port.link;
      if (link != null) disconnect(link);
    }
    _devices.remove(device.id);
    device._network = null;
  }

  Link connect(Port a, Port b, {CableType cable = CableType.copperStraight}) {
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
    final link = Link._(this, a, b, cable);
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
  final Port a;
  final Port b;
  final CableType cable;

  Port otherEnd(Port port) => identical(port, a) ? b : a;

  void _carry(Port from, Frame frame) {
    final to = otherEnd(from);
    network.scheduler.schedule(network.linkDelay, () {
      // The cable may have been pulled or the port shut while in flight.
      if (identical(to._link, this) && to.isUp) to.device.receive(to, frame);
    });
  }
}

/// A physical Ethernet port.
class Port {
  Port(
    this.device,
    this.name,
    this.shortName,
    this.index, {
    this._adminUp = true,
  }) : mac = MacAddress.derived(device.id, index);

  final Device device;

  /// Full name, e.g. `FastEthernet0/1`.
  final String name;

  /// Abbreviated name used in tables, e.g. `Fa0/1`.
  final String shortName;

  /// Position on the device; feeds the derived MAC address.
  final int index;
  final MacAddress mac;
  String? description;
  bool _adminUp;
  Link? _link;

  Link? get link => _link;

  Port? get peer => _link?.otherEnd(this);

  bool get adminUp => _adminUp;

  set adminUp(bool value) {
    if (value == _adminUp) return;
    _adminUp = value;
    _stateChanged();
  }

  /// Line protocol up: cabled, and enabled at both ends.
  bool get isUp {
    final peer = this.peer;
    return _adminUp && peer != null && peer._adminUp;
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

  List<Port> get ports;

  Network get network =>
      _network ?? (throw StateError('$id has not been added to a network'));

  Scheduler get scheduler => network.scheduler;

  /// Finds a port by full or short name, ignoring case.
  Port? port(String name) {
    final wanted = name.toLowerCase();
    for (final port in ports) {
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
