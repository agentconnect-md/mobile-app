import 'package:timezone/data/latest_10y.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

// Reads cron expressions for display: the plain-words reading of the simple
// ones and a preview of the next run. The daemon that fires a schedule stays
// the authority; this follows the same rules as its library (croner) so the
// preview agrees with it.

/// The shapes the console's schedule builder writes.
enum CronPresetKind { hourly, daily, weekdays, weekly }

class CronPreset {
  const CronPreset(this.kind, {required this.minute, this.hour = 0, this.weekday = 0});
  final CronPresetKind kind;
  final int minute;

  /// 0–23; unused for [CronPresetKind.hourly].
  final int hour;

  /// 0–6 with Sunday = 0; only for [CronPresetKind.weekly].
  final int weekday;

  /// The preset behind a five-field expression such as `0 9 * * 1-5`, or null
  /// for anything else (steps, lists, a day of the month, seconds, …).
  static CronPreset? of(String expression) {
    final f = expression.trim().split(RegExp(r'\s+'));
    if (f.length != 5 || f[2] != '*' || f[3] != '*') return null;
    final minute = _plain(f[0], 59);
    if (minute == null) return null;
    if (f[1] == '*') return f[4] == '*' ? CronPreset(CronPresetKind.hourly, minute: minute) : null;
    final hour = _plain(f[1], 23);
    if (hour == null) return null;
    if (f[4] == '*') return CronPreset(CronPresetKind.daily, minute: minute, hour: hour);
    if (f[4] == '1-5') return CronPreset(CronPresetKind.weekdays, minute: minute, hour: hour);
    final weekday = _plain(f[4], 6);
    return weekday == null ? null : CronPreset(CronPresetKind.weekly, minute: minute, hour: hour, weekday: weekday);
  }

  static int? _plain(String s, int max) {
    if (!RegExp(r'^\d{1,2}$').hasMatch(s)) return null;
    final n = int.parse(s);
    return n <= max ? n : null;
  }
}

const _nicknames = {
  '@yearly': '0 0 1 1 *',
  '@annually': '0 0 1 1 *',
  '@monthly': '0 0 1 * *',
  '@weekly': '0 0 * * 0',
  '@daily': '0 0 * * *',
  '@midnight': '0 0 * * *',
  '@hourly': '0 * * * *',
};
const _months = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];
const _days = ['sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat'];

/// "Last" in a weekday's nth-of-the-month set.
const _last = 0;

/// A parsed cron expression: five fields, or six with seconds first, or seven
/// with a year last; `*` `?` lists, ranges, steps, month and day names, `L`
/// and `nW` and `LW` in the day of the month, `#n` / `#L` on a weekday, and a
/// leading `+` on the weekday to require the day of the month as well.
class CronExpr {
  CronExpr._();

  final _seconds = <int>{};
  final _minutes = <int>{};
  final _hours = <int>{};
  final _daysOfMonth = <int>{};
  final _nearestWeekday = <int>{};
  final _monthsSet = <int>{};

  /// Weekday (0 = Sunday) → which of its occurrences in a month match:
  /// empty = every one, else 1–5 and [_last].
  final _weekdays = <int, Set<int>>{};
  Set<int>? _years;
  bool _anyDay = false;
  bool _anyWeekday = false;
  bool _lastDay = false;
  bool _lastWorkday = false;
  bool _both = false;

  /// Null when [expression] is not a cron expression.
  static CronExpr? tryParse(String expression) {
    try {
      return CronExpr._().._parse(expression);
    } on FormatException {
      return null;
    }
  }

  void _parse(String expression) {
    var text = expression.trim().toLowerCase();
    if (text.contains('@')) text = _nicknames[text] ?? (throw const FormatException('nickname'));
    final f = text.split(RegExp(r'\s+')).map((p) => p.replaceAll('?', '*')).toList();
    if (f.length < 5 || f.length > 7) throw const FormatException('fields');
    if (f.length == 5) f.insert(0, '0');
    if (f.length == 6) f.add('*');

    var day = f[3];
    if (day == 'lw') {
      _lastWorkday = true;
      day = '';
    } else if (day.contains('l')) {
      _lastDay = true;
      day = day.replaceAll('l', '');
    }
    _anyDay = day == '*';
    var weekday = _names(f[5], _days, 0);
    if (weekday.startsWith('+')) {
      _both = true;
      weekday = weekday.substring(1);
      if (weekday.isEmpty) throw const FormatException('weekday');
    }
    _anyWeekday = weekday == '*';

    _field(f[0], 0, 59, _seconds.add);
    _field(f[1], 0, 59, _minutes.add);
    _field(f[2], 0, 23, _hours.add);
    if (day.isNotEmpty || !(_lastDay || _lastWorkday)) {
      for (final part in day.split(',')) {
        if (part.endsWith('w')) {
          _nearestWeekday.add(_number(part.substring(0, part.length - 1), 1, 31));
        } else {
          _field(part, 1, 31, _daysOfMonth.add);
        }
      }
    }
    _field(_names(f[4], _months, 1), 1, 12, _monthsSet.add);
    for (final part in weekday.split(',')) {
      var range = part;
      int? nth;
      final hash = part.indexOf('#');
      if (hash >= 0) {
        final n = part.substring(hash + 1);
        nth = n == 'l' ? _last : _number(n, 1, 5);
        range = part.substring(0, hash);
      } else if (part.length > 1 && part.endsWith('l')) {
        nth = _last;
        range = part.substring(0, part.length - 1);
      }
      _field(range, 0, 7, (d) {
        final set = _weekdays.putIfAbsent(d % 7, () => <int>{});
        if (nth != null) set.add(nth);
      });
    }
    if (f[6] != '*') {
      final years = <int>{};
      _field(f[6], 1, 9999, years.add);
      _years = years;
    }
  }

  static String _names(String field, List<String> names, int first) {
    if (field.length < 3) return field;
    var out = field;
    for (var i = 0; i < names.length; i++) {
      out = out.replaceAll(names[i], '${i + first}');
    }
    return out;
  }

  static int _number(String s, int min, int max) {
    if (!RegExp(r'^\d{1,4}$').hasMatch(s)) throw const FormatException('number');
    final n = int.parse(s);
    if (n < min || n > max) throw const FormatException('range');
    return n;
  }

  /// One field: comma-separated `*`, `n`, `a-b`, each optionally `/step`.
  static void _field(String field, int min, int max, void Function(int) add) {
    if (field.isEmpty) throw const FormatException('empty');
    for (final part in field.split(',')) {
      final slash = part.split('/');
      if (slash.length > 2) throw const FormatException('step');
      final step = slash.length == 2 ? _number(slash[1], 1, max) : 1;
      final range = slash[0];
      int from, to;
      if (range == '*') {
        from = min;
        to = max;
      } else if (range.contains('-')) {
        final ends = range.split('-');
        if (ends.length != 2) throw const FormatException('range');
        from = _number(ends[0], min, max);
        to = _number(ends[1], min, max);
        if (from > to) throw const FormatException('range');
      } else {
        from = _number(range, min, max);
        // "5/15" runs from 5 to the end of the field.
        to = slash.length == 2 ? max : from;
      }
      for (var v = from; v <= to; v += step) {
        add(v);
      }
    }
  }

  bool _dayMatches(int year, int month, int day) {
    final last = DateTime.utc(year, month + 1, 0).day;
    var hit = _anyDay || _daysOfMonth.contains(day);
    if (!hit) hit = _nearestWeekday.any((d) => _nearestWorkday(year, month, d, last) == day);
    if (_lastWorkday && _nearestWorkday(year, month, last, last) == day) hit = true;
    if (_lastDay && day == last) hit = true;
    if (_anyWeekday) return hit;
    final nths = _weekdays[DateTime.utc(year, month, day).weekday % 7];
    final onWeekday = nths != null &&
        (nths.isEmpty || nths.contains((day - 1) ~/ 7 + 1) || (nths.contains(_last) && day + 7 > last));
    // A day of the month and a weekday together mean either one, unless the
    // weekday starts with "+"; with only the weekday given, just the weekday.
    return _both || _anyDay ? hit && onWeekday : hit || onWeekday;
  }

  /// The working day closest to [day] without leaving the month; null when
  /// the month has no such day.
  static int? _nearestWorkday(int year, int month, int day, int last) {
    if (day > last) return null;
    switch (DateTime.utc(year, month, day).weekday) {
      case DateTime.saturday:
        return day > 1 ? day - 1 : day + 2;
      case DateTime.sunday:
        return day < last ? day + 1 : day - 2;
      default:
        return day;
    }
  }

  /// The first run after [after] (default: now) with the expression read in
  /// [timezone], as a local time. Null when the zone is unknown here or
  /// nothing matches in the next ten years. A time that a clock change skips
  /// does not run.
  DateTime? next(String timezone, {DateTime? after}) {
    final zone = cronZone(timezone);
    if (zone == null) return null;
    final from = tz.TZDateTime.from(after ?? DateTime.now(), zone);
    final hours = _hours.toList()..sort();
    final minutes = _minutes.toList()..sort();
    final seconds = _seconds.toList()..sort();
    final startOfDay = from.hour * 3600 + from.minute * 60 + from.second;
    var day = DateTime.utc(from.year, from.month, from.day);
    for (var i = 0; i < 3660; i++, day = day.add(const Duration(days: 1))) {
      final years = _years;
      if (years != null && !years.contains(day.year)) {
        if (years.every((y) => y < day.year)) return null;
        continue;
      }
      if (!_monthsSet.contains(day.month) || !_dayMatches(day.year, day.month, day.day)) continue;
      for (final h in hours) {
        if (i == 0 && h < from.hour) continue;
        for (final m in minutes) {
          for (final s in seconds) {
            if (i == 0 && h * 3600 + m * 60 + s <= startOfDay) continue;
            final at = tz.TZDateTime(zone, day.year, day.month, day.day, h, m, s);
            if (at.hour != h || at.minute != m) continue;
            if (at.isAfter(from)) return DateTime.fromMillisecondsSinceEpoch(at.millisecondsSinceEpoch);
          }
        }
      }
    }
    return null;
  }
}

/// The next run of [expression] in [timezone]; null when either can't be read.
DateTime? nextCronRun(String expression, String timezone, {DateTime? after}) =>
    CronExpr.tryParse(expression)?.next(timezone, after: after);

bool _zonesLoaded = false;

// Zone names browsers still report that the bundled table lists under their
// current name.
const _zoneAliases = {
  'Asia/Calcutta': 'Asia/Kolkata',
  'Asia/Saigon': 'Asia/Ho_Chi_Minh',
  'Asia/Katmandu': 'Asia/Kathmandu',
  'Asia/Rangoon': 'Asia/Yangon',
  'Europe/Kiev': 'Europe/Kyiv',
  'America/Buenos_Aires': 'America/Argentina/Buenos_Aires',
  'America/Indianapolis': 'America/Indiana/Indianapolis',
  'Atlantic/Faeroe': 'Atlantic/Faroe',
  'America/Godthab': 'America/Nuuk',
  'Pacific/Enderbury': 'Pacific/Kanton',
};

/// The zone called [name] (an IANA name), or null when this build's zone
/// table doesn't have it.
tz.Location? cronZone(String name) {
  if (!_zonesLoaded) {
    tzdata.initializeTimeZones();
    _zonesLoaded = true;
  }
  final n = name.trim();
  if (const {'UTC', 'Etc/UTC', 'Etc/GMT', 'GMT', 'Z', ''}.contains(n)) return tz.UTC;
  try {
    return tz.getLocation(_zoneAliases[n] ?? n);
  } on tz.LocationNotFoundException {
    return null;
  }
}

/// Whether clocks in [timezone] read the same as this device's at [at]
/// (default: now). False for a zone unknown here.
bool cronZoneMatchesDevice(String timezone, {DateTime? at}) {
  final zone = cronZone(timezone);
  if (zone == null) return false;
  final t = at ?? DateTime.now();
  return tz.TZDateTime.from(t, zone).timeZoneOffset == t.toLocal().timeZoneOffset;
}
