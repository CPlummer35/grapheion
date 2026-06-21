// Grapheion — weekly-schedule date helpers (pure, testable). Weeks run
// Monday..Sunday. A "day" is the local midnight timestamp at its start.

/// Midnight (local) at the start of [ms]'s day.
int startOfDay(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  return DateTime(d.year, d.month, d.day).millisecondsSinceEpoch;
}

/// Midnight Monday of [ms]'s week.
int startOfWeek(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  // DateTime.weekday: Mon = 1 .. Sun = 7. Back up to this week's Monday.
  return DateTime(d.year, d.month, d.day - (d.weekday - 1)).millisecondsSinceEpoch;
}

/// The 7 day-start timestamps of [ms]'s week, Monday..Sunday.
List<int> weekDays(int ms) {
  final s = DateTime.fromMillisecondsSinceEpoch(startOfWeek(ms));
  return [
    for (var i = 0; i < 7; i++)
      DateTime(s.year, s.month, s.day + i).millisecondsSinceEpoch
  ];
}

/// Whether [a] and [b] fall on the same calendar day.
bool isSameDay(int a, int b) => startOfDay(a) == startOfDay(b);

/// Whether [ms] falls in the same Mon..Sun week as [ref].
bool isSameWeek(int ms, int ref) => startOfWeek(ms) == startOfWeek(ref);

/// Outcome of an item placed on the weekly board — drives its dot color.
enum SchedOutcome { done, missed, upcoming }

/// For an item scheduled on [scheduledForMs], given when it was last done
/// ([doneAtMs], null if never): `done` once accomplished on or after its
/// scheduled day, `missed` if that day has passed without it, else `upcoming`.
SchedOutcome schedOutcome(int scheduledForMs, int? doneAtMs, int nowMs) {
  final day = startOfDay(scheduledForMs);
  if (doneAtMs != null && doneAtMs >= day) return SchedOutcome.done;
  if (day < startOfDay(nowMs)) return SchedOutcome.missed;
  return SchedOutcome.upcoming;
}

const weekdayShort = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// Short weekday label (Mon..Sun) for a day-start timestamp.
String weekdayLabel(int dayMs) =>
    weekdayShort[DateTime.fromMillisecondsSinceEpoch(dayMs).weekday - 1];
