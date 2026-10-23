import 'package:flutter_test/flutter_test.dart';
import 'package:shinsoku/src/models/off_peak.dart';

int hm(int h, int m) => h * 60 + m;

// 2026-10-19 is a Monday
DateTime at(int day, int h, int m) => DateTime(2026, 10, 19 + day, h, m);

const mon = 0, fri = 4, sat = 5, sun = 6;

void main() {
  group('isOpen matches the engine', () {
    final night = OffPeakHours(startMin: hm(23, 0), endMin: hm(7, 0));

    test('hours wrap past midnight', () {
      expect(night.isOpen(at(mon, 0, 0)), isTrue);
      expect(night.isOpen(at(mon, 6, 59)), isTrue);
      expect(night.isOpen(at(mon, 23, 0)), isTrue);
      expect(night.isOpen(at(mon, 7, 0)), isFalse); // end is exclusive
      expect(night.isOpen(at(mon, 12, 0)), isFalse);
    });

    test('equal start and end never open', () {
      final empty = OffPeakHours(startMin: hm(5, 0), endMin: hm(5, 0));
      expect(empty.isOpen(at(mon, 5, 0)), isFalse);
      expect(empty.never, isTrue);
    });

    test('days pick when the hours begin', () {
      final friday = OffPeakHours(startMin: hm(23, 0), endMin: hm(7, 0), days: 1 << fri);
      expect(friday.isOpen(at(fri, 23, 30)), isTrue);
      expect(friday.isOpen(at(sat, 6, 0)), isTrue);
      expect(friday.isOpen(at(sat, 23, 30)), isFalse);
      expect(friday.isOpen(at(fri, 6, 0)), isFalse);
    });

    test('sunday night runs into monday', () {
      final sunday = OffPeakHours(startMin: hm(22, 0), endMin: hm(2, 0), days: 1 << sun);
      expect(sunday.isOpen(at(mon + 7, 1, 0)), isTrue);
      expect(sunday.isOpen(at(sun, 1, 0)), isFalse);
    });
  });

  group('nextStart', () {
    test('later today', () {
      final h = OffPeakHours(startMin: hm(23, 0), endMin: hm(7, 0));
      expect(h.nextStart(at(mon, 12, 0)), at(mon, 23, 0));
    });

    test('skips days the hours do not begin on', () {
      final weekend = OffPeakHours(
        startMin: hm(9, 0),
        endMin: hm(17, 0),
        days: (1 << sat) | (1 << sun),
      );
      expect(weekend.nextStart(at(mon, 12, 0)), at(sat, 9, 0));
      expect(weekend.nextStart(at(sat, 10, 0)), at(sun, 9, 0));
    });

    test('a week ahead when only today is picked and its start has passed', () {
      final monday = OffPeakHours(startMin: hm(1, 0), endMin: hm(5, 0), days: 1 << mon);
      expect(monday.nextStart(at(mon, 12, 0)), at(mon + 7, 1, 0));
    });

    test('none when no day is picked', () {
      final none = OffPeakHours(startMin: hm(1, 0), endMin: hm(5, 0), days: 0);
      expect(none.nextStart(at(mon, 12, 0)), isNull);
    });
  });

  group('scheduleHint', () {
    final night = OffPeakHours(startMin: hm(23, 0), endMin: hm(7, 0));

    test('inside the hours', () {
      expect(scheduleHint(night, at(mon, 1, 0)), 'Off-peak now: starts at once, stops at 07:00');
    });

    test('today, tomorrow and later in the week', () {
      expect(scheduleHint(night, at(mon, 12, 0)), 'Starts today at 23:00, stops at 07:00');
      final early = OffPeakHours(startMin: hm(1, 0), endMin: hm(5, 0));
      expect(scheduleHint(early, at(mon, 12, 0)), 'Starts tomorrow at 01:00, stops at 05:00');
      final saturday = OffPeakHours(startMin: hm(1, 0), endMin: hm(5, 0), days: 1 << sat);
      expect(scheduleHint(saturday, at(mon, 12, 0)), 'Starts on Saturday at 01:00, stops at 05:00');
    });

    test('hours that never open', () {
      final empty = OffPeakHours(startMin: hm(5, 0), endMin: hm(5, 0));
      expect(
        scheduleHint(empty, at(mon, 12, 0)),
        'Off-peak hours never open; set them in Settings',
      );
    });
  });
}
