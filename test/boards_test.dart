// Logic tests for the weekly PMS board close-out record.

import 'package:flutter_test/flutter_test.dart';
import 'package:grapheion/domain/boards.dart';

void main() {
  group('board close-out', () {
    test('keys by week + division and round-trips with incompletes', () {
      final b = BoardCloseout(
        id: BoardCloseout.makeId(1000, 'div-1'),
        weekStartMs: 1000,
        divisionId: 'div-1',
        closedBy: 'LT Jones',
        closedAtMs: 2000,
        total: 5,
        complete: 3,
        summary: 'two slipped for parts',
        incompletes: [
          BoardIncomplete(
            checkId: 'c1',
            label: 'M-1 chain',
            reason: 'awaiting chain',
          ),
          BoardIncomplete(checkId: 'c2', label: 'Q-1 wheels', reason: 'no access'),
        ],
        updatedAtMs: 2000,
      );
      expect(b.id, '1000|div-1');
      expect(b.incompleteCount, 2);

      final back = BoardCloseout.fromJson(b.toJson());
      expect(back.closedBy, 'LT Jones');
      expect(back.total, 5);
      expect(back.complete, 3);
      expect(back.summary, 'two slipped for parts');
      expect(back.incompletes.length, 2);
      expect(back.incompletes[0].reason, 'awaiting chain');
      expect(back.incompletes[1].label, 'Q-1 wheels');
    });

    test('a fully-complete board has no incompletes', () {
      final b = BoardCloseout(
        id: 'x',
        weekStartMs: 0,
        divisionId: 'd',
        closedBy: 'y',
        closedAtMs: 0,
        total: 4,
        complete: 4,
        updatedAtMs: 0,
      );
      expect(b.incompleteCount, 0);
    });
  });
}
