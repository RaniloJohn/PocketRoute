import '../net/mac_address.dart';
import '../sim/network.dart';

class MacTableEntry {
  MacTableEntry(this.mac, this.vlan, this.port, this.lastSeen);

  final MacAddress mac;
  final int vlan;
  Port port;
  int lastSeen;
}

/// A bridge's learned addresses (IEEE 802.1D transparent bridging), per VLAN.
class MacTable {
  MacTable(this._clock, {this.agingTicks = 300000});

  final int Function() _clock;

  /// Entries unseen for this long are dropped. Default: 300 s.
  int agingTicks;
  final _entries = <(int, MacAddress), MacTableEntry>{};

  void learn(MacAddress mac, int vlan, Port port) {
    if (mac.isGroup) return;
    final entry = _entries[(vlan, mac)];
    if (entry == null) {
      _entries[(vlan, mac)] = MacTableEntry(mac, vlan, port, _clock());
    } else {
      entry
        ..port = port
        ..lastSeen = _clock();
    }
  }

  /// The port [mac] was last seen on, or null if unknown or aged out.
  Port? lookup(MacAddress mac, int vlan) {
    final entry = _entries[(vlan, mac)];
    if (entry == null) return null;
    if (_expired(entry)) {
      _entries.remove((vlan, mac));
      return null;
    }
    return entry.port;
  }

  void flushPort(Port port) =>
      _entries.removeWhere((_, entry) => identical(entry.port, port));

  void clear() => _entries.clear();

  /// Live entries sorted by VLAN, then address.
  List<MacTableEntry> get entries {
    _entries.removeWhere((_, entry) => _expired(entry));
    return _entries.values.toList()..sort(
      (a, b) =>
          a.vlan != b.vlan ? a.vlan.compareTo(b.vlan) : a.mac.compareTo(b.mac),
    );
  }

  bool _expired(MacTableEntry entry) => _clock() - entry.lastSeen > agingTicks;
}
