import '../devices/router.dart';
import '../net/ipv4.dart';
import '../sim/network.dart';
import 'command.dart';
import 'common_commands.dart';

// Help strings here are PocketRoute's own wording. Only command names, mode
// structure and output column layouts follow the public IOS-style convention.

const _interfaceTypes = {
  'GigabitEthernet': 'Gigabit Ethernet (1 Gb/s) port',
  'Serial': 'Serial WAN port',
};

/// Clock rates a serial DCE accepts, in bit/s.
const serialClockRates = [
  1200, 2400, 4800, 9600, 19200, 38400, 56000, 64000, 72000, 125000, //
  128000, 148000, 250000, 500000, 800000, 1000000, 1300000, 2000000, 4000000,
];

/// Builds the command trees for [router].
CommandSet routerCommands(Router router) {
  final interfaceArg = CmdNode.arg(
    const InterfaceArg('interface', _interfaceTypes),
    '',
    run: (ctx) => _selectInterface(ctx, router),
    negate: (ctx) => _deleteSubinterface(ctx, router),
  );

  final interfaceModeNodes = [
    CmdNode.keyword(
      'description',
      'Add a note to this interface',
      negate: (ctx) => _target(ctx).description = null,
      children: [
        CmdNode.arg(
          const LineArg('text'),
          'Up to 240 characters',
          run: (ctx) {
            final text = ctx.arg<String>('text');
            if (text.length > 240) {
              ctx.writeln('% Description is longer than 240 characters');
            } else {
              _target(ctx).description = text;
            }
          },
          negate: (ctx) => _target(ctx).description = null,
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
          negate: (ctx) => _target(ctx).stack.configure(null, null),
          children: [
            CmdNode.arg(
              const Ipv4Arg('address'),
              'IP address',
              children: [
                CmdNode.arg(
                  const Ipv4Arg('mask'),
                  'Subnet mask',
                  run: (ctx) => _setAddress(ctx, router),
                  negate: (ctx) => _target(ctx).stack.configure(null, null),
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
      run: (ctx) => _target(ctx).adminUp = false,
      negate: (ctx) => _target(ctx).adminUp = true,
    ),
    CmdNode.keyword(
      'clock',
      'Serial line clocking',
      children: [
        CmdNode.keyword(
          'rate',
          'Clock this serial line (DCE end)',
          negate: (ctx) => _setClock(ctx, null),
          children: [
            CmdNode.arg(
              const IntArg('rate', 1200, 4000000),
              'Bits per second, e.g. 64000',
              run: (ctx) => _setClock(ctx, ctx.arg<int>('rate')),
              negate: (ctx) => _setClock(ctx, null),
            ),
          ],
        ),
      ],
    ),
  ];

  CmdNode routeTarget(ArgToken token, String help) => CmdNode.arg(
    token,
    help,
    run: (ctx) => _addRoute(ctx, router),
    negate: (ctx) => _removeRoute(ctx, router),
  );

  return buildCommandSet(
    router,
    interfaceNode: CmdNode.keyword(
      'interface',
      'Select an interface or create a subinterface',
      children: [interfaceArg],
    ),
    ping: (ctx) => iosPing(ctx, router.echo),
    show: ({required privileged}) => [
      CmdNode.keyword(
        'arp',
        'Address resolution cache',
        run: (ctx) => ctx.write(showArp(router)),
      ),
      CmdNode.keyword(
        'ip',
        'IP information',
        children: [
          CmdNode.keyword(
            'arp',
            'Address resolution cache',
            run: (ctx) => ctx.write(showArp(router)),
          ),
          CmdNode.keyword(
            'interface',
            'IP status of interfaces',
            children: [
              CmdNode.keyword(
                'brief',
                'One line per interface',
                run: (ctx) => ctx.write(showRouterInterfaceBrief(router)),
              ),
            ],
          ),
          CmdNode.keyword(
            'route',
            'Routing table',
            run: (ctx) => ctx.write(showIpRoute(router)),
          ),
        ],
      ),
    ],
    extras: {
      CliMode.globalConfig: [
        CmdNode.keyword(
          'ip',
          'IP settings',
          children: [
            CmdNode.keyword(
              'route',
              'Add a static route',
              children: [
                CmdNode.arg(
                  const Ipv4Arg('network'),
                  'Destination network',
                  children: [
                    CmdNode.arg(
                      const Ipv4Arg('mask'),
                      'Destination mask',
                      negate: (ctx) => _removeRoute(ctx, router),
                      children: [
                        routeTarget(
                          const Ipv4Arg('nextHop'),
                          'Next-hop router address',
                        ),
                        routeTarget(
                          const InterfaceArg('exit', _interfaceTypes),
                          '',
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ],
      CliMode.interfaceConfig: interfaceModeNodes,
      CliMode.subinterfaceConfig: [
        ...interfaceModeNodes,
        CmdNode.keyword(
          'encapsulation',
          'Frame tagging for this subinterface',
          children: [
            CmdNode.keyword(
              'dot1q',
              'IEEE 802.1Q VLAN tag',
              negate: (ctx) => _target(ctx)
                ..dot1qVlan = null
                ..native = false,
              children: [
                CmdNode.arg(
                  const IntArg('vlan', 1, 4094),
                  'VLAN ID',
                  run: (ctx) => _setEncapsulation(ctx, router, native: false),
                  negate: (ctx) => _target(ctx)
                    ..dot1qVlan = null
                    ..native = false,
                  children: [
                    CmdNode.keyword(
                      'native',
                      'Send and receive this VLAN untagged',
                      run: (ctx) =>
                          _setEncapsulation(ctx, router, native: true),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ],
    },
  );
}

RouterInterface _target(CommandContext ctx) =>
    ctx.session.target! as RouterInterface;

void _setClock(CommandContext ctx, int? rate) {
  final iface = _target(ctx);
  if (iface.port.medium != PortMedium.serial || !iface.isMain) {
    ctx.writeln('% Clock rate applies to serial interfaces only');
    return;
  }
  if (rate != null && !serialClockRates.contains(rate)) {
    ctx.writeln(
      '% Unsupported clock rate; try one of ${serialClockRates.join(', ')}',
    );
    return;
  }
  final link = iface.port.link;
  if (rate != null && link != null && !identical(link.dce, iface.port)) {
    ctx.warn('% This end is the DTE; the clock is set on the DCE end');
  }
  iface.port.clockRate = rate;
}

/// Splits `GigabitEthernet0/0.10` into its port and subinterface number.
(Port?, int?, bool) _resolve(InterfaceRef ref, Router router) {
  final parts = ref.number.split('.');
  final port = parts.length <= 2 ? router.port('${ref.type}${parts[0]}') : null;
  if (parts.length == 1) return (port, null, true);
  final subId = int.tryParse(parts[1]);
  final valid = subId != null && subId >= 1 && subId <= 4294967295;
  return (port, subId, valid);
}

void _selectInterface(CommandContext ctx, Router router) {
  final ref = ctx.arg<InterfaceRef>('interface');
  final (port, subId, valid) = _resolve(ref, router);
  if (port == null || !valid) {
    ctx.writeln('% ${ref.name} does not exist on this router');
    return;
  }
  if (subId == null) {
    ctx.session
      ..target = router.mainInterface(port)
      ..mode = CliMode.interfaceConfig;
  } else {
    ctx.session
      ..target = router.subinterface(port, subId)
      ..mode = CliMode.subinterfaceConfig;
  }
}

void _deleteSubinterface(CommandContext ctx, Router router) {
  final ref = ctx.arg<InterfaceRef>('interface');
  final (port, subId, valid) = _resolve(ref, router);
  if (port == null || subId == null || !valid) {
    ctx.writeln('% Only subinterfaces can be removed');
    return;
  }
  final sub = router.interface('${port.name}.$subId');
  if (sub != null) router.removeSubinterface(sub);
}

void _setEncapsulation(
  CommandContext ctx,
  Router router, {
  required bool native,
}) {
  final sub = _target(ctx);
  final vlan = ctx.arg<int>('vlan');
  for (final other in router.interfaces) {
    if (identical(other, sub) || !identical(other.port, sub.port)) continue;
    if (other.dot1qVlan == vlan) {
      ctx.writeln('% VLAN $vlan is already used by ${other.name}');
      return;
    }
    if (native && other.native) {
      ctx.writeln('% ${other.name} already carries the native VLAN');
      return;
    }
  }
  sub
    ..dot1qVlan = vlan
    ..native = native;
}

void _setAddress(CommandContext ctx, Router router) {
  final iface = _target(ctx);
  final address = ctx.arg<Ipv4Address>('address');
  final mask = ctx.arg<Ipv4Address>('mask');
  if (!iface.isMain && iface.dot1qVlan == null) {
    ctx.writeln(
      '% Set encapsulation dot1Q on this subinterface before giving it an '
      'address',
    );
    return;
  }
  if (!checkInterfaceAddress(ctx, address, mask)) return;
  for (final other in router.interfaces) {
    final otherAddress = other.address, otherMask = other.mask;
    if (identical(other, iface) || otherAddress == null || otherMask == null) {
      continue;
    }
    // Two subnets overlap if either contains the other's network.
    final shorter = mask.prefixLength! < otherMask.prefixLength!
        ? mask
        : otherMask;
    if (address.sameSubnet(otherAddress, shorter)) {
      ctx.writeln('% ${address.network(mask)} overlaps with ${other.name}');
      return;
    }
  }
  iface.stack.configure(address, mask);
}

/// The validated destination of an ip route command, or null.
(Ipv4Address, Ipv4Address)? _destination(CommandContext ctx) {
  final network = ctx.arg<Ipv4Address>('network');
  final mask = ctx.arg<Ipv4Address>('mask');
  if (mask.prefixLength == null) {
    ctx.writeln('% $mask is not a valid subnet mask');
    return null;
  }
  if (network.network(mask) != network) {
    ctx.writeln('% $network is not the network address for mask $mask');
    return null;
  }
  return (network, mask);
}

StaticRoute? _routeFromArgs(CommandContext ctx) {
  final destination = _destination(ctx);
  if (destination == null) return null;
  final (network, mask) = destination;
  final nextHop = ctx.optionalArg<Ipv4Address>('nextHop');
  final exit = ctx.optionalArg<InterfaceRef>('exit');
  if (nextHop == null && exit == null) return null;
  return StaticRoute(
    network,
    mask,
    nextHop: nextHop,
    exitInterface: exit?.name,
  );
}

void _addRoute(CommandContext ctx, Router router) {
  final route = _routeFromArgs(ctx);
  if (route == null) return;
  final exit = route.exitInterface;
  if (exit != null && router.interface(exit) == null) {
    ctx.writeln('% $exit does not exist on this router');
    return;
  }
  if (route.nextHop != null &&
      router.interfaces.any((i) => i.address == route.nextHop)) {
    ctx.writeln('% ${route.nextHop} is one of this router\'s own addresses');
    return;
  }
  if (!router.staticRoutes.contains(route)) router.staticRoutes.add(route);
}

void _removeRoute(CommandContext ctx, Router router) {
  final destination = _destination(ctx);
  if (destination == null) return;
  final (network, mask) = destination;
  final specific = _routeFromArgs(ctx);
  router.staticRoutes.removeWhere(
    (r) =>
        r.network == network &&
        r.mask == mask &&
        (specific == null || r == specific),
  );
}

/// The configuration body, from the first `!` to `end`. Replaying these lines
/// in global configuration mode rebuilds the same state.
String renderRouterConfig(Router router) {
  final out = StringBuffer()
    ..writeln('!')
    ..writeln('hostname ${router.hostname}')
    ..writeln('!');
  for (final iface in router.interfaces) {
    out.writeln('interface ${iface.name}');
    if (iface.description != null) {
      out.writeln(' description ${iface.description}');
    }
    if (iface.dot1qVlan case final vlan?) {
      out.writeln(' encapsulation dot1Q $vlan${iface.native ? ' native' : ''}');
    }
    final address = iface.address, mask = iface.mask;
    out.writeln(
      address == null || mask == null
          ? ' no ip address'
          : ' ip address $address $mask',
    );
    if (iface.isMain && iface.port.clockRate != null) {
      out.writeln(' clock rate ${iface.port.clockRate}');
    }
    if (!iface.adminUp) out.writeln(' shutdown');
    out.writeln('!');
  }
  if (router.staticRoutes.isNotEmpty) {
    for (final route in router.staticRoutes) {
      out.writeln(
        'ip route ${route.network} ${route.mask} '
        '${route.exitInterface ?? route.nextHop}',
      );
    }
    out.writeln('!');
  }
  out.writeln('end');
  return out.toString();
}

String showRouterInterfaceBrief(Router router) {
  final out = StringBuffer()..writeln(briefHeader());
  for (final iface in router.interfaces) {
    final address = iface.address;
    out.writeln(
      briefRow(
        iface.name,
        address?.toString() ?? 'unassigned',
        'YES',
        address == null ? 'unset' : 'manual',
        interfaceStatus(
          adminUp: iface.adminUp && iface.port.adminUp,
          up: iface.isUp,
        ),
        iface.isUp ? 'up' : 'down',
      ),
    );
  }
  return out.toString();
}

/// Classful mask of an address: A /8, B /16, C /24 (RFC 791 classes).
int _classfulLength(Ipv4Address address) => switch (address.octets.first) {
  < 128 => 8,
  < 192 => 16,
  < 224 => 24,
  _ => 32,
};

String showIpRoute(Router router) {
  final routes = router.routes
    ..sort((a, b) {
      final byNetwork = a.network.compareTo(b.network);
      return byNetwork != 0
          ? byNetwork
          : a.prefixLength.compareTo(b.prefixLength);
    });
  final out = StringBuffer()
    ..writeln(
      'Codes: L - local, C - connected, S - static, * - candidate default',
    )
    ..writeln();

  final defaultRoute = routes.where((r) => r.prefixLength == 0).firstOrNull;
  if (defaultRoute == null) {
    out.writeln('Gateway of last resort is not set');
  } else {
    out.writeln(
      'Gateway of last resort is ${defaultRoute.nextHop ?? Ipv4Address.any} '
      'to network 0.0.0.0',
    );
  }
  out.writeln();

  String describe(Route route) => switch (route) {
    Route(source: RouteSource.static, nextHop: final hop?) =>
      '[${route.distance}/0] via $hop',
    _ => 'is directly connected, ${route.interface.name}',
  };
  String code(Route route) =>
      switch (route.source) {
        RouteSource.connected => 'C',
        RouteSource.local => 'L',
        RouteSource.static => 'S',
      } +
      (route.prefixLength == 0 ? '*' : '');
  String prefix(Route route) => '${route.network}/${route.prefixLength}';

  // A classful network with any longer (subnet) routes is shown as a header
  // with all of its routes beneath; everything else stands alone.
  String? classfulKey(Route route) {
    final classful = _classfulLength(route.network);
    if (route.prefixLength < classful) return null;
    return '${route.network.network(Ipv4Address.maskOfLength(classful))}'
        '/$classful';
  }

  final subnetted = {
    for (final route in routes)
      if (route.prefixLength > _classfulLength(route.network))
        classfulKey(route),
  };
  final grouped = <String, List<Route>>{};
  final order = <Object>[];
  for (final route in routes) {
    final key = classfulKey(route);
    if (key != null && subnetted.contains(key)) {
      if (!grouped.containsKey(key)) order.add(key);
      grouped.putIfAbsent(key, () => []).add(route);
    } else {
      order.add(route);
    }
  }
  for (final item in order) {
    if (item case final Route route) {
      out.writeln(
        '${code(route).padRight(6)}${prefix(route)} ${describe(route)}',
      );
      continue;
    }
    final members = grouped[item as String]!;
    final lengths = members.map((r) => r.prefixLength).toSet();
    final count = members.length;
    if (lengths.length == 1) {
      final network = item.split('/').first;
      out.writeln(
        '      $network/${lengths.single} is subnetted, $count subnets',
      );
    } else {
      out.writeln(
        '      $item is variably subnetted, $count subnets, '
        '${lengths.length} masks',
      );
    }
    for (final route in members) {
      out.writeln(
        '${code(route).padRight(9)}${prefix(route)} ${describe(route)}',
      );
    }
  }
  return out.toString();
}

String showArp(Router router) {
  final out = StringBuffer()
    ..writeln(
      'Protocol  Address          Age (min)  Hardware Addr   Type   Interface',
    );
  final rows = <(Ipv4Address, String, String, String)>[];
  for (final iface in router.interfaces) {
    final address = iface.address;
    if (address == null || !iface.isUp) continue;
    rows.add((address, '-', iface.port.mac.toDotted(), iface.name));
    for (final (ip, mac, age) in iface.stack.arpTable) {
      rows.add((ip, '${age ~/ 60000}', mac.toDotted(), iface.name));
    }
  }
  rows.sort((a, b) => a.$1.compareTo(b.$1));
  for (final (ip, age, mac, name) in rows) {
    out.writeln(
      'Internet  ${ip.toString().padRight(17)}${age.padLeft(9)}  '
      '${mac.padRight(16)}ARPA   $name',
    );
  }
  return out.toString();
}
