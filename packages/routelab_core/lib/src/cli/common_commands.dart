import '../net/ipv4.dart';
import '../protocols/echo.dart';
import 'command.dart';
import 'session.dart';

// Help strings here are RouteLab's own wording. Only command names, mode
// structure and output column layouts follow the public IOS-style convention.

/// What the shared commands need from a device with an IOS-style CLI.
abstract interface class ConfigurableDevice {
  String get hostname;
  set hostname(String value);
  String get defaultHostname;

  /// Saved by `copy running-config startup-config`; null until first save.
  String? get startupConfig;
  set startupConfig(String? value);

  /// The configuration body, from the first `!` to `end`.
  String renderConfig();

  /// Resets whatever a saved config only records when it differs from the
  /// loaded-config default (e.g. router ports that are not `shutdown`).
  void prepareForConfigLoad();

  CliSession openCli(void Function(String text) write);
}

/// Builds a device's command trees: the shared commands plus the [extras]
/// for each mode. [interfaceNode] is offered in global and interface modes.
CommandSet buildCommandSet(
  ConfigurableDevice device, {
  required CmdNode interfaceNode,
  required CommandHandler ping,
  required List<CmdNode> Function({required bool privileged}) show,
  Map<CliMode, List<CmdNode>> extras = const {},
}) {
  final pingNode = CmdNode.keyword(
    'ping',
    'Send ICMP echo requests to test reachability',
    children: [
      CmdNode.arg(const Ipv4Arg('target'), 'Address to ping', run: ping),
    ],
  );

  final exitNode = CmdNode.keyword(
    'exit',
    'Leave the current mode',
    run: (ctx) {
      final session = ctx.session;
      session
        ..mode = switch (session.mode) {
          CliMode.globalConfig => CliMode.privilegedExec,
          final mode when mode.isSubConfig => CliMode.globalConfig,
          _ => CliMode.userExec,
        }
        ..target = null;
    },
  );

  final endNode = CmdNode.keyword(
    'end',
    'Leave configuration mode',
    run: (ctx) => ctx.session.ctrlZ(),
  );

  void saveConfig(CommandContext ctx) {
    ctx.writeln('Building configuration...');
    device.startupConfig = device.renderConfig();
    ctx.writeln('[OK]');
  }

  List<CmdNode> showNodes({required bool privileged}) => [
    ...show(privileged: privileged),
    if (privileged) ...[
      CmdNode.keyword(
        'running-config',
        'Configuration currently in effect',
        run: (ctx) => ctx.write(showRunningConfig(device)),
      ),
      CmdNode.keyword(
        'startup-config',
        'Configuration saved for the next start',
        run: (ctx) => ctx.write(
          device.startupConfig ?? 'startup-config is not present\n',
        ),
      ),
    ],
  ];

  List<CmdNode> subMode(CliMode mode, {bool withInterface = false}) => [
    endNode,
    exitNode,
    if (withInterface) interfaceNode,
    ...?extras[mode],
  ];

  return CommandSet({
    CliMode.userExec: [
      CmdNode.keyword(
        'enable',
        'Enter privileged mode',
        run: (ctx) => ctx.session.mode = CliMode.privilegedExec,
      ),
      exitNode,
      pingNode,
      CmdNode.keyword(
        'show',
        'Display device status',
        children: showNodes(privileged: false),
      ),
      ...?extras[CliMode.userExec],
    ],
    CliMode.privilegedExec: [
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
      pingNode,
      CmdNode.keyword(
        'show',
        'Display device status',
        children: showNodes(privileged: true),
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
      ...?extras[CliMode.privilegedExec],
    ],
    CliMode.globalConfig: [
      endNode,
      exitNode,
      CmdNode.keyword(
        'hostname',
        'Set the device name',
        negate: (ctx) => device.hostname = device.defaultHostname,
        children: [
          CmdNode.arg(
            const WordArg('name'),
            'New device name',
            run: (ctx) => _setHostname(ctx, device),
          ),
        ],
      ),
      interfaceNode,
      ...?extras[CliMode.globalConfig],
    ],
    CliMode.interfaceConfig: subMode(
      CliMode.interfaceConfig,
      withInterface: true,
    ),
    if (extras.containsKey(CliMode.subinterfaceConfig))
      CliMode.subinterfaceConfig: subMode(
        CliMode.subinterfaceConfig,
        withInterface: true,
      ),
    if (extras.containsKey(CliMode.vlanConfig))
      CliMode.vlanConfig: subMode(CliMode.vlanConfig),
  });
}

final _hostnamePattern = RegExp(r'^[A-Za-z]([A-Za-z0-9-]{0,62})$');

void _setHostname(CommandContext ctx, ConfigurableDevice device) {
  final name = ctx.arg<String>('name');
  if (!_hostnamePattern.hasMatch(name)) {
    ctx.writeln(
      '% Hostnames start with a letter and use only letters, digits and '
      'hyphens (max 63)',
    );
    return;
  }
  device.hostname = name;
}

/// Validates an interface address; prints why and returns false if unusable.
bool checkInterfaceAddress(
  CommandContext ctx,
  Ipv4Address address,
  Ipv4Address mask,
) {
  if (mask.prefixLength == null) {
    ctx.writeln('% $mask is not a valid subnet mask');
    return false;
  }
  if (!address.isUsableHost(mask)) {
    ctx.writeln('% $address is not a usable host address with mask $mask');
    return false;
  }
  return true;
}

/// IOS-style ping: five 100-byte echoes, one mark per answer, then a summary.
/// Marks: `!` reply, `.` timeout, `U` unreachable, `&` TTL expired.
void iosPing(CommandContext ctx, EchoClient? client) {
  final target = ctx.arg<Ipv4Address>('target');
  if (client == null) {
    ctx.writeln('% Cannot ping: no IP address is configured');
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
  client.ping(
    target,
    count: count,
    size: size,
    timeout: 2000,
    ttl: 255,
    onResult: (result) {
      if (result.ok) rtts.add(result.rtt!);
      ctx.write(switch (result.status) {
        PingStatus.reply => '!',
        PingStatus.timeout || PingStatus.noRoute => '.',
        PingStatus.unreachable => 'U',
        PingStatus.ttlExceeded => '&',
      });
    },
    onDone: () {
      final summary = StringBuffer(
        'Success rate is ${rtts.length * 100 ~/ count} percent '
        '(${rtts.length}/$count)',
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

String showRunningConfig(ConfigurableDevice device) {
  final body = device.renderConfig();
  return 'Building configuration...\n\n'
      'Current configuration : ${body.length} bytes\n'
      '$body';
}

/// Replays [config] (as produced by [ConfigurableDevice.renderConfig])
/// through the CLI, the same path a user's typing takes. Returns any error
/// output; empty means clean.
String applyConfig(ConfigurableDevice device, String config) {
  final errors = StringBuffer();
  device.prepareForConfigLoad();
  final session = device.openCli(errors.write)
    ..mode = CliMode.globalConfig
    ..loadingConfig = true;
  for (final line in config.split('\n')) {
    if (session.mode == CliMode.privilegedExec) break;
    session.execute(line);
  }
  return errors.toString();
}

/// One row of `show ip interface brief`.
String briefRow(
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

String briefHeader() =>
    briefRow('Interface', 'IP-Address', 'OK?', 'Method', 'Status', 'Protocol');

String interfaceStatus({required bool adminUp, required bool up}) => !adminUp
    ? 'administratively down'
    : up
    ? 'up'
    : 'down';
