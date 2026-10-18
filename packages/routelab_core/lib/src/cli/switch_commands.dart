import '../devices/l2_switch.dart';
import '../net/ipv4.dart';
import '../protocols/stp.dart';
import '../protocols/vlan.dart';
import '../sim/network.dart';
import 'command.dart';
import 'common_commands.dart';

// Help strings here are RouteLab's own wording. Only command names, mode
// structure and output column layouts follow the public IOS-style convention.

/// What `interface ...` selected on a switch.
sealed class SwitchInterface {
  const SwitchInterface();
}

final class PhysicalInterface extends SwitchInterface {
  const PhysicalInterface(this.port);

  final Port port;
}

final class ManagementInterface extends SwitchInterface {
  const ManagementInterface();
}

const _interfaceTypes = {
  'FastEthernet': 'Fast Ethernet (100 Mb/s) port',
  'GigabitEthernet': 'Gigabit Ethernet (1 Gb/s) port',
  'Vlan': 'Switch virtual interface for a VLAN',
};

/// Builds the command trees for [sw].
CmdNode _vlanIdArg(
  String help, {
  List<CmdNode> children = const [],
  CommandHandler? run,
  CommandHandler? negate,
}) => CmdNode.arg(
  const IntArg('vlan', minVlan, maxVlan),
  help,
  children: children,
  run: run,
  negate: negate,
);

CommandSet switchCommands(L2Switch sw) {
  return buildCommandSet(
    sw,
    interfaceNode: CmdNode.keyword(
      'interface',
      'Select an interface to configure',
      children: [
        CmdNode.arg(
          const InterfaceArg('interface', _interfaceTypes),
          '',
          run: (ctx) => _selectInterface(ctx, sw),
        ),
      ],
    ),
    ping: (ctx) => iosPing(ctx, sw.svi.isConfigured ? sw.svi.echo : null),
    show: ({required privileged}) => [
      CmdNode.keyword(
        'interfaces',
        'Interface status',
        children: [
          CmdNode.keyword(
            'trunk',
            'Ports in trunk mode',
            run: (ctx) => ctx.write(showInterfacesTrunk(sw)),
          ),
        ],
      ),
      CmdNode.keyword(
        'ip',
        'IP information',
        children: [
          CmdNode.keyword(
            'interface',
            'IP status of interfaces',
            children: [
              CmdNode.keyword(
                'brief',
                'One line per interface',
                run: (ctx) => ctx.write(showIpInterfaceBrief(sw)),
              ),
            ],
          ),
        ],
      ),
      CmdNode.keyword(
        'mac',
        'MAC address information',
        children: [
          CmdNode.keyword(
            'address-table',
            'Addresses this switch has learned',
            run: (ctx) => ctx.write(showMacAddressTable(sw)),
          ),
        ],
      ),
      CmdNode.keyword(
        'spanning-tree',
        'Spanning tree roles and states',
        run: (ctx) => ctx.write(showSpanningTree(sw)),
      ),
      CmdNode.keyword(
        'vlan',
        'VLANs and their ports',
        run: (ctx) => ctx.write(showVlanBrief(sw)),
        children: [
          CmdNode.keyword(
            'brief',
            'One line per VLAN',
            run: (ctx) => ctx.write(showVlanBrief(sw)),
          ),
        ],
      ),
    ],
    extras: {
      CliMode.privilegedExec: [
        CmdNode.keyword(
          'clear',
          'Reset counters or tables',
          children: [
            CmdNode.keyword(
              'mac',
              'MAC address tables',
              children: [
                CmdNode.keyword(
                  'address-table',
                  'Forget learned addresses',
                  children: [
                    CmdNode.keyword(
                      'dynamic',
                      'Learned entries only',
                      run: (ctx) => sw.macTable.clear(),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ],
      CliMode.globalConfig: [
        CmdNode.keyword(
          'ip',
          'IP settings',
          children: [
            CmdNode.keyword(
              'default-gateway',
              'Router used to reach other subnets',
              negate: (ctx) => sw.svi.gateway = null,
              children: [
                CmdNode.arg(
                  const Ipv4Arg('gateway'),
                  'Gateway address',
                  run: (ctx) =>
                      sw.svi.gateway = ctx.arg<Ipv4Address>('gateway'),
                  negate: (ctx) => sw.svi.gateway = null,
                ),
              ],
            ),
          ],
        ),
        CmdNode.keyword(
          'spanning-tree',
          'Spanning tree settings',
          children: [
            CmdNode.keyword(
              'vlan',
              'Settings for a VLAN',
              children: [
                _vlanIdArg(
                  'VLAN (one instance covers all VLANs in this version)',
                  children: [
                    CmdNode.keyword(
                      'priority',
                      'Bridge priority; the lowest becomes root',
                      negate: (ctx) =>
                          sw.stp.priority = SpanningTree.defaultPriority,
                      children: [
                        CmdNode.arg(
                          const IntArg('priority', 0, 61440),
                          'Multiple of 4096',
                          run: (ctx) => _setPriority(ctx, sw),
                          negate: (ctx) =>
                              sw.stp.priority = SpanningTree.defaultPriority,
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
        CmdNode.keyword(
          'vlan',
          'Create or configure a VLAN',
          children: [
            _vlanIdArg(
              'VLAN ID',
              run: (ctx) {
                final vlan = ctx.arg<int>('vlan');
                sw.createVlan(vlan);
                ctx.session
                  ..target = vlan
                  ..mode = CliMode.vlanConfig;
              },
              negate: (ctx) {
                final vlan = ctx.arg<int>('vlan');
                if (vlan == 1) {
                  ctx.writeln(
                    '% VLAN 1 is the default VLAN and cannot be deleted',
                  );
                } else {
                  sw.deleteVlan(vlan);
                }
              },
            ),
          ],
        ),
      ],
      CliMode.interfaceConfig: [
        CmdNode.keyword(
          'description',
          'Add a note to this interface',
          negate: (ctx) => _setDescription(ctx, sw, null),
          children: [
            CmdNode.arg(
              const LineArg('text'),
              'Up to 240 characters',
              run: (ctx) => _setDescription(ctx, sw, ctx.arg<String>('text')),
              negate: (ctx) => _setDescription(ctx, sw, null),
            ),
          ],
        ),
        CmdNode.keyword(
          'ip',
          'IP settings',
          children: [
            CmdNode.keyword(
              'address',
              'Set the IP address',
              negate: (ctx) => _setAddress(ctx, sw, clear: true),
              children: [
                CmdNode.arg(
                  const Ipv4Arg('address'),
                  'IP address',
                  children: [
                    CmdNode.arg(
                      const Ipv4Arg('mask'),
                      'Subnet mask',
                      run: (ctx) => _setAddress(ctx, sw, clear: false),
                      negate: (ctx) => _setAddress(ctx, sw, clear: true),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
        CmdNode.keyword(
          'shutdown',
          'Disable this interface',
          run: (ctx) => _setAdmin(ctx, sw, up: false),
          negate: (ctx) => _setAdmin(ctx, sw, up: true),
        ),
        CmdNode.keyword(
          'spanning-tree',
          'Spanning tree settings for this port',
          children: [
            CmdNode.keyword(
              'portfast',
              'Forward at once when up; for ports to a single host',
              run: (ctx) => _withPort(ctx, (port) {
                sw.stp.portfast.add(port);
                ctx.warn(
                  '% Portfast is on for ${port.name}. Connect only one host '
                  'here: a loop through this port is not blocked while it '
                  'comes up.',
                );
              }),
              negate: (ctx) =>
                  _withPort(ctx, (port) => sw.stp.portfast.remove(port)),
            ),
          ],
        ),
        CmdNode.keyword(
          'switchport',
          'Layer 2 port settings',
          children: _switchportNodes(sw),
        ),
      ],
      CliMode.vlanConfig: [
        CmdNode.keyword(
          'name',
          'Name this VLAN',
          negate: (ctx) {
            final vlan = ctx.session.target! as int;
            sw.vlans[vlan] = L2Switch.defaultVlanName(vlan);
          },
          children: [
            CmdNode.arg(
              const WordArg('name'),
              'Up to 32 characters',
              run: (ctx) {
                final name = ctx.arg<String>('name');
                if (name.length > 32) {
                  ctx.writeln('% VLAN names are at most 32 characters');
                  return;
                }
                sw.vlans[ctx.session.target! as int] = name;
              },
            ),
          ],
        ),
      ],
    },
  );
}

List<CmdNode> _switchportNodes(L2Switch sw) {
  void config(CommandContext ctx, void Function(SwitchportConfig c) change) =>
      _withPort(ctx, (port) {
        change(sw.switchport(port));
        sw.macTable.flushPort(port);
      });

  void setAllowed(CommandContext ctx, VlanSet Function(VlanSet now) change) =>
      config(ctx, (c) => c.allowed = change(c.allowed));

  return [
    CmdNode.keyword(
      'access',
      'Settings used in access mode',
      children: [
        CmdNode.keyword(
          'vlan',
          'VLAN for untagged traffic on this port',
          negate: (ctx) => config(ctx, (c) => c.accessVlan = 1),
          children: [
            _vlanIdArg(
              'VLAN ID',
              run: (ctx) {
                final vlan = ctx.arg<int>('vlan');
                if (!sw.vlans.containsKey(vlan)) {
                  ctx.writeln('% VLAN $vlan did not exist; created it');
                  sw.createVlan(vlan);
                }
                config(ctx, (c) => c.accessVlan = vlan);
              },
              negate: (ctx) => config(ctx, (c) => c.accessVlan = 1),
            ),
          ],
        ),
      ],
    ),
    CmdNode.keyword(
      'mode',
      'Access (one VLAN) or trunk (many, tagged)',
      negate: (ctx) => config(ctx, (c) => c.mode = SwitchportMode.access),
      children: [
        CmdNode.keyword(
          'access',
          'Carry one VLAN, untagged',
          run: (ctx) => config(ctx, (c) => c.mode = SwitchportMode.access),
        ),
        CmdNode.keyword(
          'trunk',
          'Carry many VLANs with 802.1Q tags',
          run: (ctx) => config(ctx, (c) => c.mode = SwitchportMode.trunk),
        ),
      ],
    ),
    CmdNode.keyword(
      'trunk',
      'Settings used in trunk mode',
      children: [
        CmdNode.keyword(
          'allowed',
          'VLANs this trunk carries',
          children: [
            CmdNode.keyword(
              'vlan',
              'VLAN list',
              negate: (ctx) => setAllowed(ctx, (_) => VlanSet.all()),
              children: [
                CmdNode.arg(
                  const VlanListArg('vlans'),
                  'VLAN IDs, e.g. 10,20,30-40',
                  run: (ctx) =>
                      setAllowed(ctx, (_) => ctx.arg<VlanSet>('vlans')),
                ),
                CmdNode.keyword(
                  'add',
                  'Add to the current list',
                  children: [
                    CmdNode.arg(
                      const VlanListArg('vlans'),
                      'VLAN IDs to add',
                      run: (ctx) => setAllowed(
                        ctx,
                        (now) => now.union(ctx.arg<VlanSet>('vlans')),
                      ),
                    ),
                  ],
                ),
                CmdNode.keyword(
                  'all',
                  'Every VLAN',
                  run: (ctx) => setAllowed(ctx, (_) => VlanSet.all()),
                ),
                CmdNode.keyword(
                  'none',
                  'No VLANs',
                  run: (ctx) => setAllowed(ctx, (_) => VlanSet(const [])),
                ),
                CmdNode.keyword(
                  'remove',
                  'Remove from the current list',
                  children: [
                    CmdNode.arg(
                      const VlanListArg('vlans'),
                      'VLAN IDs to remove',
                      run: (ctx) => setAllowed(
                        ctx,
                        (now) => now.minus(ctx.arg<VlanSet>('vlans')),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
        CmdNode.keyword(
          'native',
          'Untagged VLAN on this trunk',
          children: [
            CmdNode.keyword(
              'vlan',
              'Native VLAN ID',
              negate: (ctx) => config(ctx, (c) => c.nativeVlan = 1),
              children: [
                _vlanIdArg(
                  'VLAN ID',
                  run: (ctx) =>
                      config(ctx, (c) => c.nativeVlan = ctx.arg<int>('vlan')),
                  negate: (ctx) => config(ctx, (c) => c.nativeVlan = 1),
                ),
              ],
            ),
          ],
        ),
      ],
    ),
  ];
}

/// Runs [action] on the selected physical port, or explains why not.
void _withPort(CommandContext ctx, void Function(Port port) action) {
  switch (ctx.session.target) {
    case PhysicalInterface(:final port):
      action(port);
    default:
      ctx.writeln('% Not available on a VLAN interface');
  }
}

void _setPriority(CommandContext ctx, L2Switch sw) {
  if (ctx.arg<int>('vlan') != 1) {
    ctx.writeln(
      '% One spanning tree instance covers all VLANs in this version; '
      'set it with vlan 1',
    );
    return;
  }
  final priority = ctx.arg<int>('priority');
  if (priority % 4096 != 0) {
    ctx.writeln('% Bridge priority must be a multiple of 4096');
    return;
  }
  sw.stp.priority = priority;
}

void _selectInterface(CommandContext ctx, L2Switch sw) {
  final ref = ctx.arg<InterfaceRef>('interface');
  final SwitchInterface? selected = switch (ref.type) {
    'Vlan' when ref.number == '${L2Switch.managementVlan}' =>
      const ManagementInterface(),
    'Vlan' => null,
    _ => switch (sw.port(ref.name)) {
      final Port port => PhysicalInterface(port),
      null => null,
    },
  };
  if (selected == null) {
    ctx.writeln(
      ref.type == 'Vlan'
          ? '% Only interface Vlan${L2Switch.managementVlan} is available '
                'in this version'
          : '% ${ref.name} does not exist on this switch',
    );
    return;
  }
  ctx.session
    ..target = selected
    ..mode = CliMode.interfaceConfig;
}

void _setDescription(CommandContext ctx, L2Switch sw, String? text) {
  if (text != null && text.length > 240) {
    ctx.writeln('% Description is longer than 240 characters');
    return;
  }
  switch (ctx.session.target) {
    case PhysicalInterface(:final port):
      port.description = text;
    case ManagementInterface():
      sw.sviDescription = text;
  }
}

void _setAdmin(CommandContext ctx, L2Switch sw, {required bool up}) {
  switch (ctx.session.target) {
    case PhysicalInterface(:final port):
      port.adminUp = up;
    case ManagementInterface():
      sw.sviAdminUp = up;
  }
}

void _setAddress(CommandContext ctx, L2Switch sw, {required bool clear}) {
  if (ctx.session.target is! ManagementInterface) {
    ctx.writeln(
      '% Switch ports are layer 2; set the address on interface '
      'Vlan${L2Switch.managementVlan}',
    );
    return;
  }
  if (clear) {
    sw.svi.configure(null, null);
    return;
  }
  final address = ctx.arg<Ipv4Address>('address');
  final mask = ctx.arg<Ipv4Address>('mask');
  if (checkInterfaceAddress(ctx, address, mask)) {
    sw.svi.configure(address, mask);
  }
}

/// The configuration body, from the first `!` to `end`. Replaying these lines
/// in global configuration mode rebuilds the same state.
String renderSwitchConfig(L2Switch sw) {
  final out = StringBuffer()
    ..writeln('!')
    ..writeln('hostname ${sw.hostname}')
    ..writeln('!');
  if (sw.stp.priority != SpanningTree.defaultPriority) {
    out
      ..writeln('spanning-tree vlan 1 priority ${sw.stp.priority}')
      ..writeln('!');
  }
  for (final MapEntry(key: vlan, value: name) in sw.vlans.entries) {
    if (vlan == 1) continue;
    out.writeln('vlan $vlan');
    if (name != L2Switch.defaultVlanName(vlan)) out.writeln(' name $name');
    out.writeln('!');
  }
  for (final port in sw.ports) {
    final config = sw.switchport(port);
    out.writeln('interface ${port.name}');
    if (port.description != null) {
      out.writeln(' description ${port.description}');
    }
    if (config.accessVlan != 1) {
      out.writeln(' switchport access vlan ${config.accessVlan}');
    }
    if (config.nativeVlan != 1) {
      out.writeln(' switchport trunk native vlan ${config.nativeVlan}');
    }
    if (!config.allowed.isAll) {
      out.writeln(' switchport trunk allowed vlan ${config.allowed.format()}');
    }
    if (config.isTrunk) out.writeln(' switchport mode trunk');
    if (!port.adminUp) out.writeln(' shutdown');
    if (sw.stp.portfast.contains(port)) out.writeln(' spanning-tree portfast');
    out.writeln('!');
  }
  out.writeln('interface Vlan${L2Switch.managementVlan}');
  if (sw.sviDescription != null) {
    out.writeln(' description ${sw.sviDescription}');
  }
  final address = sw.svi.address, mask = sw.svi.mask;
  out.writeln(
    address == null || mask == null
        ? ' no ip address'
        : ' ip address $address $mask',
  );
  // Vlan1 defaults to shut down, so the enabled state must be written out.
  out
    ..writeln(sw.sviAdminUp ? ' no shutdown' : ' shutdown')
    ..writeln('!');
  final gateway = sw.svi.gateway;
  if (gateway != null) {
    out
      ..writeln('ip default-gateway $gateway')
      ..writeln('!');
  }
  out.writeln('end');
  return out.toString();
}

String showIpInterfaceBrief(L2Switch sw) {
  final out = StringBuffer()..writeln(briefHeader());
  for (final port in sw.ports) {
    out.writeln(
      briefRow(
        port.name,
        'unassigned',
        'YES',
        'unset',
        interfaceStatus(adminUp: port.adminUp, up: port.isUp),
        port.isUp ? 'up' : 'down',
      ),
    );
  }
  final address = sw.svi.address;
  out.writeln(
    briefRow(
      'Vlan${L2Switch.managementVlan}',
      address?.toString() ?? 'unassigned',
      'YES',
      address == null ? 'unset' : 'manual',
      interfaceStatus(adminUp: sw.sviAdminUp, up: sw.sviIsUp),
      sw.sviIsUp ? 'up' : 'down',
    ),
  );
  return out.toString();
}

String showMacAddressTable(L2Switch sw) {
  final entries = sw.macTable.entries;
  final out = StringBuffer()
    ..writeln('          Mac Address Table')
    ..writeln('-------------------------------------------')
    ..writeln()
    ..writeln('Vlan    Mac Address       Type        Ports')
    ..writeln('----    -----------       --------    -----');
  for (final entry in entries) {
    out.writeln(
      '${entry.vlan.toString().padLeft(4)}    ${entry.mac.toDotted()}    '
      '${'DYNAMIC'.padRight(12)}${entry.port.shortName}',
    );
  }
  out.writeln('Total Mac Addresses for this criterion: ${entries.length}');
  return out.toString();
}

String showVlanBrief(L2Switch sw) {
  const portsWidth = 31;
  final out = StringBuffer()
    ..writeln('VLAN Name                             Status    Ports')
    ..writeln(
      '---- -------------------------------- --------- '
      '${'-' * portsWidth}',
    );
  for (final MapEntry(key: vlan, value: name) in sw.vlans.entries) {
    final members = [
      for (final port in sw.ports)
        if (!sw.switchport(port).isTrunk &&
            sw.switchport(port).accessVlan == vlan)
          port.shortName,
    ];
    final lines = <String>[];
    var line = '';
    for (final member in members) {
      final next = line.isEmpty ? member : '$line, $member';
      if (next.length > portsWidth) {
        lines.add('$line,');
        line = member;
      } else {
        line = next;
      }
    }
    if (line.isNotEmpty) lines.add(line);
    final head =
        '${'$vlan'.padRight(5)}${name.padRight(33)}${'active'.padRight(10)}';
    out.writeln('$head${lines.isEmpty ? '' : lines.first}'.trimRight());
    for (final rest in lines.skip(1)) {
      out.writeln('${' ' * head.length}$rest');
    }
  }
  return out.toString();
}

String showInterfacesTrunk(L2Switch sw) {
  final trunks = [
    for (final port in sw.ports)
      if (port.isUp && sw.switchport(port).isTrunk) port,
  ];
  if (trunks.isEmpty) return '';
  String row(String port, String rest) => '${port.padRight(12)}$rest';
  final out = StringBuffer()
    ..writeln()
    ..writeln(
      row(
        'Port',
        '${'Mode'.padRight(17)}${'Encapsulation'.padRight(15)}'
            '${'Status'.padRight(14)}Native vlan',
      ),
    );
  for (final port in trunks) {
    out.writeln(
      row(
        port.shortName,
        '${'on'.padRight(17)}${'802.1q'.padRight(15)}'
        '${'trunking'.padRight(14)}${sw.switchport(port).nativeVlan}',
      ),
    );
  }
  void section(String title, String Function(Port port) vlans) {
    out
      ..writeln()
      ..writeln(row('Port', title));
    for (final port in trunks) {
      out.writeln(row(port.shortName, vlans(port)));
    }
  }

  VlanSet active(Port port) =>
      sw.switchport(port).allowed.intersect(sw.vlans.keys);
  section('Vlans allowed on trunk', (p) => sw.switchport(p).allowed.format());
  section(
    'Vlans allowed and active in management domain',
    (p) => active(p).format(),
  );
  section(
    'Vlans in spanning tree forwarding state and not pruned',
    (p) => sw.stp.forwards(p) ? active(p).format() : 'none',
  );
  return out.toString();
}

String showSpanningTree(L2Switch sw) {
  final stp = sw.stp;
  final timers =
      '             Hello Time   ${SpanningTree.helloTime ~/ 1000} sec  '
      'Max Age  ${SpanningTree.maxAge ~/ 1000} sec  '
      'Forward Delay  ${SpanningTree.forwardDelay ~/ 1000} sec';
  final out = StringBuffer()
    ..writeln('VLAN0001')
    ..writeln('  Spanning tree enabled protocol ieee')
    ..writeln('  (one spanning tree instance is shared by all VLANs)')
    ..writeln('  Root ID    Priority    ${stp.rootId.priority}')
    ..writeln('             Address     ${stp.rootId.mac.toDotted()}');
  final rootPort = stp.rootPort;
  if (rootPort == null) {
    out.writeln('             This bridge is the root');
  } else {
    out
      ..writeln('             Cost        ${stp.rootCost}')
      ..writeln(
        '             Port        ${rootPort.index} (${rootPort.name})',
      );
  }
  out
    ..writeln(timers)
    ..writeln()
    ..writeln(
      '  Bridge ID  Priority    ${stp.bridgeId.priority}  '
      '(priority ${stp.priority} sys-id-ext 1)',
    )
    ..writeln('             Address     ${stp.bridgeId.mac.toDotted()}')
    ..writeln(timers)
    ..writeln()
    ..writeln('Interface           Role Sts Cost      Prio.Nbr Type')
    ..writeln(
      '------------------- ---- --- --------- -------- '
      '--------------------------------',
    );
  for (final port in sw.ports) {
    final role = stp.role(port);
    if (role == StpRole.disabled) continue;
    final roleText = switch (role) {
      StpRole.root => 'Root',
      StpRole.designated => 'Desg',
      StpRole.alternate || StpRole.disabled => 'Altn',
    };
    final state = switch (stp.state(port)) {
      StpState.blocking || StpState.disabled => 'BLK',
      StpState.listening => 'LIS',
      StpState.learning => 'LRN',
      StpState.forwarding => 'FWD',
    };
    out.writeln(
      '${port.shortName.padRight(20)}${roleText.padRight(5)}'
      '${state.padRight(4)}${'${SpanningTree.costFor(port)}'.padRight(10)}'
      '${'${SpanningTree.portPriority}.${port.index}'.padRight(9)}'
      'P2p${stp.portfast.contains(port) ? ' Edge' : ''}',
    );
  }
  return out.toString();
}
