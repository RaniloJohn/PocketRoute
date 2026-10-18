/// Valid VLAN IDs (IEEE 802.1Q reserves 0 and 4095).
const minVlan = 1, maxVlan = 4094;

/// A set of VLAN IDs, written as ranges such as `1,10,20-30`.
class VlanSet {
  VlanSet(Iterable<int> ids) : _ids = {...ids};

  VlanSet.all() : this([for (var v = minVlan; v <= maxVlan; v++) v]);

  /// Parses `10`, `10,20` or `10-20,30`; null if malformed or out of range.
  static VlanSet? tryParse(String text) {
    final ids = <int>{};
    for (final part in text.split(',')) {
      final bounds = part.split('-');
      if (bounds.length > 2) return null;
      final low = int.tryParse(bounds.first);
      final high = int.tryParse(bounds.last);
      if (low == null || high == null || low > high) return null;
      if (low < minVlan || high > maxVlan) return null;
      for (var v = low; v <= high; v++) {
        ids.add(v);
      }
    }
    return VlanSet(ids);
  }

  final Set<int> _ids;

  bool contains(int vlan) => _ids.contains(vlan);

  bool get isEmpty => _ids.isEmpty;

  bool get isAll => _ids.length == maxVlan - minVlan + 1;

  VlanSet union(VlanSet other) => VlanSet({..._ids, ...other._ids});

  VlanSet minus(VlanSet other) => VlanSet(_ids.difference(other._ids));

  VlanSet intersect(Iterable<int> other) =>
      VlanSet(_ids.intersection({...other}));

  List<int> get sorted => _ids.toList()..sort();

  /// Compact range form, e.g. `1-9,11`; `none` when empty.
  String format() {
    final ids = sorted;
    if (ids.isEmpty) return 'none';
    final parts = <String>[];
    var start = ids.first, previous = ids.first;
    for (final id in [...ids.skip(1), -1]) {
      if (id == previous + 1) {
        previous = id;
        continue;
      }
      parts.add(start == previous ? '$start' : '$start-$previous');
      start = previous = id;
    }
    return parts.join(',');
  }

  @override
  bool operator ==(Object other) =>
      other is VlanSet &&
      other._ids.length == _ids.length &&
      other._ids.containsAll(_ids);

  @override
  int get hashCode => Object.hashAllUnordered(_ids);

  @override
  String toString() => format();
}
