import '../devices/l2_switch.dart';
import '../devices/multilayer_switch.dart';
import '../net/ipv4.dart';
import '../protocols/echo.dart';
import '../protocols/routing.dart';
import '../protocols/stp.dart';
import '../protocols/vlan.dart';
import '../sim/network.dart';
import 'command.dart';
import 'common_commands.dart';
import 'router_commands.dart';

// Help strings here are PocketRoute's own wording. Only command names, mode
// structure and output column layouts follow the public IOS-style convention.

/// What `interface ...` selected on a switch.
sealed class SwitchInterface {
  const SwitchInterface();
}

final class PhysicalInterface extends SwitchInterface {
  const PhysicalInterface(this.port);

  final Port port;
}

final class VlanInterface extends SwitchInterface {
  const VlanInterface(this.vlan);

  final int vlan;
}

const _interfaceTypes = {
  'FastEthernet': 'Fast Ethernet (100 Mb/s) port',
  'GigabitEthernet': 'Gigabit Ethernet (1 Gb/s) port',
  'Vlan': 'Switch virtual interface for a VLAN',
};

const _multilayerTypes = {
  'GigabitEthernet': 'Gigabit Ethernet (1 Gb/s) port',
  'Vlan': 'Switch virtual interface for a VLAN',
};

Map<String, String> _typesFor(L2Switch sw) =>
    sw is MultilayerSwitch ? _multilayerTypes : _interfaceTypes;

/// Who answers `ping` from the switch: the routing engine on an L3 switch,
/// the management interface on an L2 switch.
EchoClient? _pinger(L2Switch sw) {
  if (sw is MultilayerSwitch) {
    final any = sw.interfaces.any((i) => i.stack.isConfigured);
    return any ? sw.routing.echo : null;
  }
  return sw.svi.isConfigured ? sw.svi.echo : null;
}

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
          InterfaceArg('interface', _typesFor(sw)),
          '',
          run: (ctx) => _selectInterface(ctx, sw),
          negate: (ctx) => _deleteInterface(ctx, sw),
        ),
      ],
    ),
    ping: (ctx) => iosPing(ctx, _pinger(sw)),
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
          if (sw is MultilayerSwitch)
            CmdNode.keyword(
              'route',
              'Routing table',
              run: (ctx) => ctx.write(showIpRoute(sw.routing)),
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
              negate: (ctx) => _setGateway(sw, null),
              children: [
                CmdNode.arg(
                  const Ipv4Arg('gateway'),
                  'Gateway address',
                  run: (ctx) =>
                      _setGateway(sw, ctx.arg<Ipv4Address>('gateway')),
                  negate: (ctx) => _setGateway(sw, null),
                ),
              ],
            ),
            if (sw is MultilayerSwitch) ...[
              CmdNode.keyword(
                'routing',
                'Route between this switch'
                    's IP interfaces',
                run: (ctx) => sw.ipRouting = true,
                negate: (ctx) => sw.ipRouting = false,
              ),
              ipRouteNode(sw.routing, _multilayerTypes),
            ],
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
              run: (ctx) => _withPort(ctx, sw, (port) {
                sw.stp.portfast.add(port);
                ctx.warn(
                  '% Portfast is on for ${port.name}. Connect only one host '
                  'here: a loop through this port is not blocked while it '
                  'comes up.',
                );
              }),
              negate: (ctx) =>
                  _withPort(ctx, sw, (port) => sw.stp.portfast.remove(port)),
            ),
          ],
        ),
        CmdNode.keyword(
          'switchport',
          'Layer 2 port settings; alone, makes a routed port a switch port',
          run: (ctx) => _setRouted(ctx, sw, routed: false),
          negate: (ctx) => _setRouted(ctx, sw, routed: true),
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
      _withPort(ctx, sw, (port) {
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

/// Runs [action] on the selected switch port, or explains why not.
void _withPort(
  CommandContext ctx,
  L2Switch sw,
  void Function(Port port) action,
) {
  switch (ctx.session.target) {
    case PhysicalInterface(:final port) when sw.isRouted(port):
      ctx.writeln(
        '% ${port.name} is a routed port; enter "switchport" to make it a '
        'switch port first',
      );
    case PhysicalInterface(:final port):
      action(port);
    default:
      ctx.writeln('% Not available on a VLAN interface');
  }
}

void _setRouted(CommandContext ctx, L2Switch sw, {required bool routed}) {
  final target = ctx.session.target;
  if (target is! PhysicalInterface) {
    ctx.writeln('% Not available on a VLAN interface');
    return;
  }
  if (sw is! MultilayerSwitch) {
    if (routed) {
      ctx.writeln(
        '% Ports on a layer 2 switch cannot be routed; use an L3 switch',
      );
    }
    return;
  }
  sw.setRouted(target.port, routed: routed);
}

void _setGateway(L2Switch sw, Ipv4Address? gateway) {
  if (sw is MultilayerSwitch) {
    sw.routing.defaultGateway = gateway;
  } else {
    sw.svi.gateway = gateway;
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
  final vlanNumber = int.tryParse(ref.number);
  final SwitchInterface? selected = switch (ref.type) {
    'Vlan'
        when vlanNumber != null &&
            vlanNumber >= minVlan &&
            vlanNumber <= maxVlan &&
            sw.supportsSvi(vlanNumber) =>
      VlanInterface(vlanNumber),
    'Vlan' => null,
    _ => switch (sw.port(ref.name)) {
      final Port port => PhysicalInterface(port),
      null => null,
    },
  };
  if (selected == null) {
    ctx.writeln(
      ref.type == 'Vlan'
          ? sw is MultilayerSwitch
                ? '% VLAN interfaces are numbered 1 to $maxVlan'
                : '% A layer 2 switch has only interface '
                      'Vlan${L2Switch.managementVlan}; use an L3 switch for more'
          : '% ${ref.name} does not exist on this switch',
    );
    return;
  }
  if (selected is VlanInterface) sw.sviFor(selected.vlan);
  ctx.session
    ..target = selected
    ..mode = CliMode.interfaceConfig;
}

void _deleteInterface(CommandContext ctx, L2Switch sw) {
  final ref = ctx.arg<InterfaceRef>('interface');
  final vlan = int.tryParse(ref.number);
  if (ref.type != 'Vlan' || vlan == null) {
    ctx.writeln('% Only VLAN interfaces can be removed');
    return;
  }
  if (vlan == L2Switch.managementVlan) {
    ctx.writeln('% Interface Vlan1 cannot be removed');
    return;
  }
  sw.removeSvi(vlan);
}

void _setDescription(CommandContext ctx, L2Switch sw, String? text) {
  if (text != null && text.length > 240) {
    ctx.writeln('% Description is longer than 240 characters');
    return;
  }
  switch (ctx.session.target) {
    case PhysicalInterface(:final port):
      port.description = text;
    case VlanInterface(:final vlan):
      sw.sviFor(vlan).description = text;
  }
}

void _setAdmin(CommandContext ctx, L2Switch sw, {required bool up}) {
  switch (ctx.session.target) {
    case PhysicalInterface(:final port):
      port.adminUp = up;
    case VlanInterface(:final vlan):
      sw.sviFor(vlan).adminUp = up;
  }
}

void _setAddress(CommandContext ctx, L2Switch sw, {required bool clear}) {
  final L3Interface? iface = switch (ctx.session.target) {
    VlanInterface(:final vlan) => sw.sviFor(vlan),
    PhysicalInterface(:final port) when sw is MultilayerSwitch => sw.routedPort(
      port,
    ),
    _ => null,
  };
  if (iface == null) {
    ctx.writeln(
      sw is MultilayerSwitch
          ? '% This is a switch port; enter "no switchport" to route on it'
          : '% Switch ports are layer 2; set the address on interface '
                'Vlan${L2Switch.managementVlan}',
    );
    return;
  }
  if (clear) {
    iface.stack.configure(null, null);
    return;
  }
  final address = ctx.arg<Ipv4Address>('address');
  final mask = ctx.arg<Ipv4Address>('mask');
  if (sw is MultilayerSwitch) {
    setInterfaceAddress(ctx, sw.routing, iface, address, mask);
  } else if (checkInterfaceAddress(ctx, address, mask)) {
    iface.stack.configure(address, mask);
  }
}

/// The configuration body, from the first `!` to `end`. Replaying these lines
/// in global configuration mode rebuilds the same state.
String renderSwitchConfig(L2Switch sw) {
  final out = StringBuffer()
    ..writeln('!')
    ..writeln('hostname ${sw.hostname}')
    ..writeln('!');
  if (sw is MultilayerSwitch && sw.ipRouting) {
    out
      ..writeln('ip routing')
      ..writeln('!');
  }
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
    if (sw is MultilayerSwitch && sw.routedPort(port) != null) {
      out.writeln(' no switchport');
      _renderAddress(out, sw.routedPort(port)!);
      if (!port.adminUp) out.writeln(' shutdown');
      out.writeln('!');
      continue;
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
  for (final svi in sw.svis.values) {
    out.writeln('interface ${svi.name}');
    if (svi.description != null) out.writeln(' description ${svi.description}');
    _renderAddress(out, svi);
    // SVIs start shut down, so the enabled state must be written out.
    out
      ..writeln(svi.adminUp ? ' no shutdown' : ' shutdown')
      ..writeln('!');
  }
  final gateway = sw is MultilayerSwitch
      ? sw.routing.defaultGateway
      : sw.svi.gateway;
  if (gateway != null) {
    out
      ..writeln('ip default-gateway $gateway')
      ..writeln('!');
  }
  if (sw is MultilayerSwitch) renderStaticRoutes(out, sw.routing);
  out.writeln('end');
  return out.toString();
}

void _renderAddress(StringBuffer out, L3Interface iface) {
  final address = iface.stack.address, mask = iface.stack.mask;
  out.writeln(
    address == null || mask == null
        ? ' no ip address'
        : ' ip address $address $mask',
  );
}

String showIpInterfaceBrief(L2Switch sw) {
  final out = StringBuffer()..writeln(briefHeader());
  void row(String name, Ipv4Address? address, bool adminUp, bool up) =>
      out.writeln(
        briefRow(
          name,
          address?.toString() ?? 'unassigned',
          'YES',
          address == null ? 'unset' : 'manual',
          interfaceStatus(adminUp: adminUp, up: up),
          up ? 'up' : 'down',
        ),
      );
  for (final port in sw.ports) {
    final routed = sw is MultilayerSwitch ? sw.routedPort(port) : null;
    row(port.name, routed?.stack.address, port.adminUp, port.isUp);
  }
  for (final svi in sw.svis.values) {
    row(svi.name, svi.stack.address, svi.adminUp, svi.isUp);
  }
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
