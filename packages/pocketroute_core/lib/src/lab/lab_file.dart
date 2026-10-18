import 'dart:convert';

import 'package:archive/archive.dart';

import '../cli/common_commands.dart';
import '../devices/l2_switch.dart';
import '../devices/multilayer_switch.dart';
import '../devices/pc.dart';
import '../devices/router.dart';
import '../net/ipv4.dart';
import '../sim/network.dart';

/// Device models a lab can contain.
enum DeviceModel { router, l2switch, l3switch, pc, laptop, server }

DeviceModel modelOf(Device device) => switch (device) {
  Router() => DeviceModel.router,
  MultilayerSwitch() => DeviceModel.l3switch,
  L2Switch() => DeviceModel.l2switch,
  Pc(kind: HostKind.laptop) => DeviceModel.laptop,
  Pc(kind: HostKind.server) => DeviceModel.server,
  Pc() => DeviceModel.pc,
  _ => throw ArgumentError('Unsupported device ${device.runtimeType}'),
};

Device createDevice(DeviceModel model, String id, String hostname) =>
    switch (model) {
      DeviceModel.router => Router(id, hostname: hostname),
      DeviceModel.l2switch => L2Switch(id, hostname: hostname),
      DeviceModel.l3switch => MultilayerSwitch(id, hostname: hostname),
      DeviceModel.pc => Pc(id, hostname: hostname),
      DeviceModel.laptop => Pc(id, hostname: hostname, kind: HostKind.laptop),
      DeviceModel.server => Pc(id, hostname: hostname, kind: HostKind.server),
    };

/// A device and where it sits on the canvas.
class LabDevice {
  LabDevice(this.device, this.x, this.y);

  final Device device;
  double x;
  double y;

  DeviceModel get model => modelOf(device);
}

/// A whole lab: the network, device positions, a name and notes.
class Lab {
  Lab({
    Network? network,
    List<LabDevice>? devices,
    this.name = 'Untitled lab',
    this.notes = '',
  }) : network = network ?? Network(),
       devices = devices ?? [];

  final Network network;
  final List<LabDevice> devices;
  String name;

  /// Free text for the student (Markdown), shown when the lab opens.
  String notes;
}

class LabFormatException implements Exception {
  const LabFormatException(this.message);

  final String message;

  @override
  String toString() => 'LabFormatException: $message';
}

/// Lab files: a zip holding `topology.json` and `notes.md`.
abstract final class LabFile {
  static const extension = 'prlab';
  static const format = 'pocketroute-lab';

  /// Bump with a migration in [_migrate] whenever the JSON shape changes.
  static const version = 1;

  static Map<String, Object?> encode(Lab lab) => {
    'format': format,
    'version': version,
    'name': lab.name,
    'devices': [
      for (final entry in lab.devices)
        {
          'id': entry.device.id,
          'model': entry.model.name,
          'hostname': entry.device.hostname,
          'pos': [_round(entry.x), _round(entry.y)],
          if (entry.device case final ConfigurableDevice d) ...{
            'config': d.renderConfig(),
            if (d.startupConfig != null) 'startupConfig': d.startupConfig,
          },
          if (entry.device case final Pc pc)
            'host': {
              'address': pc.ip.address?.toString(),
              'mask': pc.ip.mask?.toString(),
              'gateway': pc.ip.gateway?.toString(),
            },
        },
    ],
    'links': [
      for (final link in lab.network.links)
        {
          'a': [link.a.device.id, link.a.name],
          'b': [link.b.device.id, link.b.name],
          'cable': link.cable.name,
        },
    ],
  };

  /// Builds a lab from [json]. Configs are replayed through each device's
  /// CLI; anything the CLI rejects is added to [warnings].
  static Lab decode(Map<String, Object?> json, {List<String>? warnings}) {
    if (json['format'] != format) {
      throw const LabFormatException('Not a PocketRoute lab');
    }
    final data = _migrate(json);
    final lab = Lab(name: data['name'] as String? ?? 'Untitled lab');
    final byId = <String, Device>{};
    final configs = <ConfigurableDevice, Map<String, Object?>>{};

    for (final raw in (data['devices'] as List? ?? const [])) {
      final entry = (raw as Map).cast<String, Object?>();
      final id = entry['id'] as String;
      final model = DeviceModel.values.asNameMap()[entry['model']];
      if (model == null) {
        warnings?.add('Skipped $id: unknown device type ${entry['model']}');
        continue;
      }
      final device = createDevice(model, id, entry['hostname'] as String);
      lab.network.add(device);
      byId[id] = device;
      final pos = (entry['pos'] as List?)?.cast<num>() ?? const [0, 0];
      lab.devices.add(LabDevice(device, pos[0].toDouble(), pos[1].toDouble()));
      if (device is ConfigurableDevice) {
        configs[device as ConfigurableDevice] = entry;
      }
      if (device is Pc) {
        if (entry['host'] case final Map host) {
          final address = Ipv4Address.tryParse('${host['address']}');
          final mask = Ipv4Address.tryParse('${host['mask']}');
          if (address != null && mask != null) {
            device.ip.configure(address, mask);
          }
          device.ip.gateway = Ipv4Address.tryParse('${host['gateway']}');
        }
      }
    }

    for (final raw in (data['links'] as List? ?? const [])) {
      final entry = (raw as Map).cast<String, Object?>();
      final a = _port(byId, entry['a']);
      final b = _port(byId, entry['b']);
      final cable = CableType.values.asNameMap()[entry['cable']];
      if (a == null || b == null) {
        warnings?.add('Skipped a cable to a missing port');
        continue;
      }
      try {
        lab.network.connect(a, b, cable: cable);
      } on Object catch (e) {
        warnings?.add('Skipped cable ${a.name} - ${b.name}: $e');
      }
    }

    // Configs last: they may refer to cabled ports (e.g. serial DCE ends).
    for (final MapEntry(key: device, value: entry) in configs.entries) {
      if (entry['config'] case final String config) {
        final errors = applyConfig(device, config).trim();
        if (errors.isNotEmpty) {
          warnings?.add('${device.hostname}: $errors');
        }
      }
      device.startupConfig = entry['startupConfig'] as String?;
    }
    return lab;
  }

  /// The lab as `.prlab` bytes.
  static List<int> write(Lab lab) {
    final json = const JsonEncoder.withIndent('  ').convert(encode(lab));
    final archive = Archive()
      ..addFile(ArchiveFile.string('topology.json', json))
      ..addFile(ArchiveFile.string('notes.md', lab.notes));
    return ZipEncoder().encode(archive);
  }

  /// Reads `.prlab` bytes. Throws [LabFormatException] if they are not one.
  static Lab read(List<int> bytes, {List<String>? warnings}) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } on Object {
      throw const LabFormatException('The file is not a PocketRoute lab');
    }
    final topology = archive.findFile('topology.json');
    if (topology == null) {
      throw const LabFormatException('The lab has no topology.json');
    }
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(topology.content));
    } on FormatException {
      throw const LabFormatException('topology.json is not valid JSON');
    }
    if (json is! Map) {
      throw const LabFormatException('topology.json has the wrong shape');
    }
    final lab = decode(json.cast<String, Object?>(), warnings: warnings);
    final notes = archive.findFile('notes.md');
    if (notes != null) lab.notes = utf8.decode(notes.content);
    return lab;
  }

  static Map<String, Object?> _migrate(Map<String, Object?> json) {
    final from = json['version'];
    if (from is! int || from < 1) {
      throw const LabFormatException('The lab has no valid version');
    }
    if (from > version) {
      throw const LabFormatException(
        'This lab was made with a newer PocketRoute; update the app to open it',
      );
    }
    // Version 1 is current; future migrations go here, oldest first.
    return json;
  }

  static Port? _port(Map<String, Device> byId, Object? ref) {
    if (ref is! List || ref.length != 2) return null;
    return byId[ref[0]]?.port('${ref[1]}');
  }

  static num _round(double v) => (v * 10).round() / 10;
}
