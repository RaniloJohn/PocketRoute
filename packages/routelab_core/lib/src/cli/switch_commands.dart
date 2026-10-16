import '../devices/l2_switch.dart';
import '../net/ipv4.dart';
import '../protocols/ip_stack.dart';
import '../sim/network.dart';
import 'command.dart';

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
CommandSet switchCommands(L2Switch sw) {
  final ping = CmdNode.keyword(
    'ping',
    'Send ICMP echo requests to test reachability',
    children: [
      CmdNode.arg(
        const Ipv4Arg('target'),
        'Address to ping',
        run: (ctx) => _ping(ctx, sw),
      ),
    ],
  );

  List<CmdNode> showChildren({required bool privileged}) => [
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
    if (privileged) ...[
      CmdNode.keyword(
        'running-config',
        'Configuration currently in effect',
        run: (ctx) => ctx.write(showRunningConfig(sw)),
      ),
      CmdNode.keyword(
        'startup-config',
        'Configuration saved for the next start',
        run: (ctx) {
          final saved = sw.startupConfig;
          ctx.write(saved ?? 'startup-config is not present\n');
        },
      ),
    ],
  ];

  final exitNode = CmdNode.keyword(
    'exit',
    'Leave the current mode',
    run: (ctx) {
      final session = ctx.session;
      session.mode = switch (session.mode) {
        CliMode.interfaceConfig => CliMode.globalConfig,
        CliMode.globalConfig => CliMode.privilegedExec,
        _ => CliMode.userExec,
      };
      if (session.mode != CliMode.interfaceConfig) session.target = null;
    },
  );

  final endNode = CmdNode.keyword(
    'end',
    'Leave configuration mode',
    run: (ctx) => ctx.session.ctrlZ(),
  );

  final interfaceNode = CmdNode.keyword(
    'interface',
    'Select an interface to configure',
    children: [
      CmdNode.arg(
        const InterfaceArg('interface', _interfaceTypes),
        '',
        run: (ctx) => _selectInterface(ctx, sw),
      ),
    ],
  );

  void saveConfig(CommandContext ctx) {
    ctx.writeln('Building configuration...');
    sw.startupConfig = renderConfig(sw);
    ctx.writeln('[OK]');
  }

  return CommandSet({
    CliMode.userExec: [
      CmdNode.keyword(
        'enable',
        'Enter privileged mode',
        run: (ctx) => ctx.session.mode = CliMode.privilegedExec,
      ),
      exitNode,
      ping,
      CmdNode.keyword(
        'show',
        'Display device status',
        children: showChildren(privileged: false),
      ),
    ],
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
      CmdNode.keyword(
        'configure',
        'Enter configuration mode',
        children: [
          CmdNode.keyword(
            'terminal',
            'Configure from this terminal',
            run: (ctx) {
              ctx.writeln(
                'Enter configuration commands, one per line.  '
                'End with CNTL/Z.',
              );
              ctx.session.mode = CliMode.globalConfig;
            },
          ),
        ],
      ),
      CmdNode.keyword(
        'copy',
        'Copy a configuration',
        children: [
          CmdNode.keyword(
            'running-config',
            'Configuration currently in effect',
            children: [
              CmdNode.keyword(
                'startup-config',
                'Save it for the next start',
                run: saveConfig,
              ),
            ],
          ),
        ],
      ),
      CmdNode.keyword(
        'disable',
        'Return to user mode',
        run: (ctx) => ctx.session.mode = CliMode.userExec,
      ),
      exitNode,
      ping,
      CmdNode.keyword(
        'show',
        'Display device status',
        children: showChildren(privileged: true),
      ),
      CmdNode.keyword(
        'write',
        'Save the running configuration',
        run: saveConfig,
        children: [
          CmdNode.keyword(
            'memory',
            'Save it for the next start',
            run: saveConfig,
          ),
        ],
      ),
    ],
    CliMode.globalConfig: [
      endNode,
      exitNode,
      CmdNode.keyword(
        'hostname',
        'Set the device name',
        negate: (ctx) => sw.hostname = L2Switch.defaultHostname,
        children: [
          CmdNode.arg(
            const WordArg('name'),
            'New device name',
            run: (ctx) => _setHostname(ctx, sw),
          ),
        ],
      ),
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
                run: (ctx) => sw.svi.gateway = ctx.arg<Ipv4Address>('gateway'),
                negate: (ctx) => sw.svi.gateway = null,
              ),
            ],
          ),
        ],
      ),
      interfaceNode,
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
      endNode,
      exitNode,
      interfaceNode,
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
    ],
  });
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

final _hostnamePattern = RegExp(r'^[A-Za-z]([A-Za-z0-9-]{0,62})$');

void _setHostname(CommandContext ctx, L2Switch sw) {
  final name = ctx.arg<String>('name');
  if (!_hostnamePattern.hasMatch(name)) {
    ctx.writeln(
      '% Hostnames start with a letter and use only letters, digits and '
      'hyphens (max 63)',
    );
    return;
  }
  sw.hostname = name;
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
  if (mask.prefixLength == null) {
    ctx.writeln('% $mask is not a valid subnet mask');
    return;
  }
  if (!address.isUsableHost(mask)) {
    ctx.writeln('% $address is not a usable host address with mask $mask');
    return;
  }
  sw.svi.configure(address, mask);
}

void _ping(CommandContext ctx, L2Switch sw) {
  final target = ctx.arg<Ipv4Address>('target');
  if (!sw.svi.isConfigured) {
    ctx.writeln('% Cannot ping: this switch has no IP address configured');
    return;
  }
  const count = 5, size = 100;
  final session = ctx.session..busy = true;
  final rtts = <int>[];
  ctx
    ..writeln('Type escape sequence to abort.')
    ..writeln(
      'Sending $count, $size-byte ICMP Echos to $target, '
      'timeout is 2 seconds:',
    );
  sw.svi.ping(
    target,
    count: count,
    size: size,
    timeout: 2000,
    onResult: (result) {
      if (result.ok) rtts.add(result.rtt!);
      ctx.write(switch (result.status) {
        PingStatus.reply => '!',
        PingStatus.timeout || PingStatus.noRoute => '.',
      });
    },
    onDone: () {
      final percent = rtts.length * 100 ~/ count;
      final summary = StringBuffer(
        'Success rate is $percent percent (${rtts.length}/$count)',
      );
      if (rtts.isNotEmpty) {
        final min = rtts.reduce((a, b) => a < b ? a : b);
        final max = rtts.reduce((a, b) => a > b ? a : b);
        final avg = rtts.reduce((a, b) => a + b) ~/ rtts.length;
        summary.write(', round-trip min/avg/max = $min/$avg/$max ms');
      }
      ctx
        ..writeln()
        ..writeln(summary.toString());
      session.busy = false;
    },
  );
}

/// The configuration body, from the first `!` to `end`. Replaying these lines
/// in global configuration mode rebuilds the same state.
String renderConfig(L2Switch sw) {
  final out = StringBuffer()
    ..writeln('!')
    ..writeln('hostname ${sw.hostname}')
    ..writeln('!');
  for (final port in sw.ports) {
    out.writeln('interface ${port.name}');
    if (port.description != null) {
      out.writeln(' description ${port.description}');
    }
    if (!port.adminUp) out.writeln(' shutdown');
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
  out.writeln(sw.sviAdminUp ? ' no shutdown' : ' shutdown');
  out.writeln('!');
  final gateway = sw.svi.gateway;
  if (gateway != null) {
    out
      ..writeln('ip default-gateway $gateway')
      ..writeln('!');
  }
  out.writeln('end');
  return out.toString();
}

/// Replays [config] (as produced by [renderConfig]) through the CLI, the same
/// path a user's typing takes. Returns any error output; empty means clean.
String applyConfig(L2Switch sw, String config) {
  final errors = StringBuffer();
  final session = sw.openCli(errors.write)..mode = CliMode.globalConfig;
  for (final line in config.split('\n')) {
    if (session.mode == CliMode.privilegedExec) break;
    session.execute(line);
  }
  return errors.toString();
}

String showRunningConfig(L2Switch sw) {
  final body = renderConfig(sw);
  return 'Building configuration...\n\n'
      'Current configuration : ${body.length} bytes\n'
      '$body';
}

String showIpInterfaceBrief(L2Switch sw) {
  final out = StringBuffer()
    ..writeln(
      _briefRow(
        'Interface',
        'IP-Address',
        'OK?',
        'Method',
        'Status',
        'Protocol',
      ),
    );
  String status(bool adminUp, bool up) => !adminUp
      ? 'administratively down'
      : up
      ? 'up'
      : 'down';
  for (final port in sw.ports) {
    out.writeln(
      _briefRow(
        port.name,
        'unassigned',
        'YES',
        'unset',
        status(port.adminUp, port.isUp),
        port.isUp ? 'up' : 'down',
      ),
    );
  }
  final address = sw.svi.address;
  out.writeln(
    _briefRow(
      'Vlan${L2Switch.managementVlan}',
      address?.toString() ?? 'unassigned',
      'YES',
      address == null ? 'unset' : 'manual',
      status(sw.sviAdminUp, sw.sviIsUp),
      sw.sviIsUp ? 'up' : 'down',
    ),
  );
  return out.toString();
}

String _briefRow(
  String name,
  String address,
  String ok,
  String method,
  String status,
  String protocol,
) =>
    '${name.padRight(23)}${address.padRight(16)}${ok.padRight(4)}'
            '${method.padRight(7)}${status.padRight(22)}$protocol'
        .trimRight();

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
