// Logic tests for the weekly-schedule date helpers.

import 'package:flutter_test/flutter_test.dart';
import 'package:grapheion/domain/schedule.dart';

void main() {
  final someDay = DateTime(2026, 6, 17, 14, 30, 5).millisecondsSinceEpoch;

  test('startOfDay strips the time-of-day', () {
    final d = DateTime.fromMillisecondsSinceEpoch(startOfDay(someDay));
    expect([d.year, d.month, d.day], [2026, 6, 17]);
    expect([d.hour, d.minute, d.second], [0, 0, 0]);
  });

  test('startOfWeek lands on midnight Monday', () {
    final d = DateTime.fromMillisecondsSinceEpoch(startOfWeek(someDay));
    expect(d.weekday, DateTime.monday);
    expect(d.hour, 0);
  });

  test('weekDays is 7 consecutive days, Monday..Sunday', () {
    final days = weekDays(someDay);
    expect(days.length, 7);
    expect(
      DateTime.fromMillisecondsSinceEpoch(days.first).weekday,
      DateTime.monday,
    );
    expect(
      DateTime.fromMillisecondsSinceEpoch(days.last).weekday,
      DateTime.sunday,
    );
    for (var i = 0; i < 7; i++) {
      expect(weekdayLabel(days[i]), weekdayShort[i]);
    }
  });

  test('isSameDay ignores time-of-day, distinguishes days', () {
    final morning = DateTime(2026, 6, 17, 8).millisecondsSinceEpoch;
    final night = DateTime(2026, 6, 17, 23).millisecondsSinceEpoch;
    final next = DateTime(2026, 6, 18, 1).millisecondsSinceEpoch;
    expect(isSameDay(morning, night), isTrue);
    expect(isSameDay(morning, next), isFalse);
  });

  test('isSameWeek groups Mon..Sun, splits at the week boundary', () {
    final monday = startOfWeek(someDay);
    final mid = monday + 3 * 86400000; // Thursday-ish
    final nextWeek = monday + 7 * 86400000;
    expect(isSameWeek(monday, mid), isTrue);
    expect(isSameWeek(monday, nextWeek), isFalse);
  });

  group('schedOutcome (board dot)', () {
    final now = DateTime(2026, 6, 17, 12).millisecondsSinceEpoch; // Wed noon
    final today = startOfDay(now);
    final pastDay = today - 2 * 86400000;
    final futureDay = today + 2 * 86400000;

    test('not done + past day -> missed', () {
      expect(
        schedOutcome(done: false, dayMs: pastDay, nowMs: now),
        SchedOutcome.missed,
      );
    });
    test('done -> done regardless of which day', () {
      expect(
        schedOutcome(done: true, dayMs: pastDay, nowMs: now),
        SchedOutcome.done,
      );
      expect(
        schedOutcome(done: true, dayMs: today, nowMs: now),
        SchedOutcome.done,
      );
    });
    test('not done + today or future -> upcoming', () {
      expect(
        schedOutcome(done: false, dayMs: today, nowMs: now),
        SchedOutcome.upcoming,
      );
      expect(
        schedOutcome(done: false, dayMs: futureDay, nowMs: now),
        SchedOutcome.upcoming,
      );
    });
  });
}
