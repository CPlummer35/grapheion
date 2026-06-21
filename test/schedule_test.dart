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
    expect(DateTime.fromMillisecondsSinceEpoch(days.first).weekday, DateTime.monday);
    expect(DateTime.fromMillisecondsSinceEpoch(days.last).weekday, DateTime.sunday);
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

    test('past day, not done -> missed', () {
      expect(schedOutcome(pastDay, null, now), SchedOutcome.missed);
    });
    test('past day, done before its day -> still missed', () {
      expect(schedOutcome(pastDay, pastDay - 86400000, now),
          SchedOutcome.missed);
    });
    test('done on/after its scheduled day -> done', () {
      expect(schedOutcome(pastDay, now, now), SchedOutcome.done);
      expect(schedOutcome(pastDay, pastDay, now), SchedOutcome.done);
    });
    test('today or future, not done -> upcoming', () {
      expect(schedOutcome(today, null, now), SchedOutcome.upcoming);
      expect(schedOutcome(futureDay, null, now), SchedOutcome.upcoming);
    });
  });
}
