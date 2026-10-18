import 'dart:collection';

typedef SimAction = void Function();

/// Discrete-event clock. One tick is one simulated millisecond.
///
/// Realtime mode drives [advance] from a timer; simulation mode and tests call
/// [step] or [runUntilIdle] directly.
///
/// Background actions (periodic timers such as spanning tree hellos) run in
/// order with everything else but do not keep the network busy: [isIdle] and
/// [runUntilIdle] only wait for foreground work such as frames in flight.
class Scheduler {
  int _now = 0;
  int _foreground = 0;
  final _queue = SplayTreeMap<int, Queue<(SimAction, bool)>>();

  int get now => _now;

  bool get isIdle => _foreground == 0;

  /// Runs [action] [delay] ticks from now. A zero delay runs it later in the
  /// current tick, after the actions already queued for it.
  void schedule(int delay, SimAction action, {bool background = false}) {
    RangeError.checkNotNegative(delay, 'delay');
    _queue.putIfAbsent(_now + delay, Queue.new).add((action, background));
    if (!background) _foreground++;
  }

  /// Runs every action due at the next scheduled tick. False if none is queued.
  bool step() {
    final tick = _queue.firstKey();
    if (tick == null) return false;
    _now = tick;
    final actions = _queue[tick]!;
    while (actions.isNotEmpty) {
      final (action, background) = actions.removeFirst();
      if (!background) _foreground--;
      action();
    }
    _queue.remove(tick);
    return true;
  }

  /// Steps until no foreground work is queued. Throws if it never settles.
  void runUntilIdle({int maxSteps = 1000000}) {
    var steps = 0;
    while (!isIdle && step()) {
      if (++steps >= maxSteps) {
        throw StateError('Simulation still busy after $maxSteps steps');
      }
    }
  }

  /// Runs everything due within the next [ticks] ticks, then moves the clock
  /// to the end of that window.
  void advance(int ticks) {
    RangeError.checkNotNegative(ticks, 'ticks');
    final end = _now + ticks;
    while (_queue.isNotEmpty && _queue.firstKey()! <= end) {
      step();
    }
    _now = end;
  }
}
