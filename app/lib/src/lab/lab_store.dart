import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pocketroute_core/pocketroute_core.dart';

/// A bundled starter lab.
class StarterLab {
  const StarterLab(this.asset, this.title, this.summary);

  final String asset;
  final String title;
  final String summary;
}

const starterLabs = [
  StarterLab('01-first-lan', 'Your first LAN', 'Two PCs, one switch, ARP'),
  StarterLab('02-router-on-a-stick', 'Router on a stick', 'VLANs and trunks'),
  StarterLab('03-campus-core', 'Campus core', 'L3 switch, SVIs, routing'),
  StarterLab(
    '04-spanning-tree',
    'Spanning tree loop',
    'Root, blocking, failover',
  ),
  StarterLab('05-serial-wan', 'Serial WAN', 'Troubleshooting: link down'),
];

/// A lab file saved on this device.
class SavedLab {
  const SavedLab(this.file, this.name, this.modified);

  final File file;
  final String name;
  final DateTime modified;
}

/// Reads and writes lab files in the app's documents folder.
class LabStore {
  Future<Directory> _folder() async {
    final docs = await getApplicationDocumentsDirectory();
    return Directory('${docs.path}/labs').create(recursive: true);
  }

  /// Saved labs, newest first.
  Future<List<SavedLab>> list() async {
    final folder = await _folder();
    final labs = <SavedLab>[];
    await for (final entry in folder.list()) {
      if (entry is File && entry.path.endsWith('.${LabFile.extension}')) {
        final name = entry.uri.pathSegments.last;
        labs.add(
          SavedLab(
            entry,
            name.substring(0, name.length - LabFile.extension.length - 1),
            await entry.lastModified(),
          ),
        );
      }
    }
    return labs..sort((a, b) => b.modified.compareTo(a.modified));
  }

  /// Writes [lab] as [name].prlab and returns the file.
  Future<File> save(Lab lab, String name) async {
    final folder = await _folder();
    final file = File(
      '${folder.path}/${safeFileName(name)}.${LabFile.extension}',
    );
    await file.writeAsBytes(LabFile.write(lab), flush: true);
    return file;
  }

  Future<Lab> load(File file, {List<String>? warnings}) async =>
      LabFile.read(await file.readAsBytes(), warnings: warnings);

  Future<Lab> loadStarter(StarterLab starter) async {
    final data = await rootBundle.load(
      'assets/labs/${starter.asset}.${LabFile.extension}',
    );
    return LabFile.read(data.buffer.asUint8List());
  }

  /// Letters, digits, spaces, dots, dashes and underscores; never empty.
  static String safeFileName(String name) {
    final cleaned = name
        .replaceAll(RegExp(r'[^A-Za-z0-9 ._-]'), '')
        .trim()
        .replaceAll(RegExp(r'\s+'), ' ');
    return cleaned.isEmpty ? 'Untitled lab' : cleaned;
  }
}
