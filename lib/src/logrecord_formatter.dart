import 'package:logging/logging.dart';

/// Base class for formatters which are responsible for converting
/// [LogRecord]s to strings.
abstract class LogRecordFormatter {
  const LogRecordFormatter();

  /// Should write the formatted output of [rec] into [sb].
  StringBuffer formatToStringBuffer(LogRecord rec, StringBuffer sb);

  String format(LogRecord rec) =>
      formatToStringBuffer(rec, StringBuffer()).toString();
}

/// Formatter which can be easily configured using a function block.
class BlockFormatter extends LogRecordFormatter {
  BlockFormatter._(this.block);

  BlockFormatter.formatRecord(String Function(LogRecord rec) formatter)
      : this._((rec, sb) => sb.write(formatter(rec)));

  final void Function(LogRecord rec, StringBuffer sb) block;

  @override
  StringBuffer formatToStringBuffer(LogRecord rec, StringBuffer sb) {
    block(rec, sb);
    return sb;
  }
}

/// Opinionated log formatter which will give a decent format of [LogRecord]
/// and adds stack trace and error messages if they are available.
class DefaultLogRecordFormatter extends LogRecordFormatter {
  const DefaultLogRecordFormatter();

  @override
  StringBuffer formatToStringBuffer(LogRecord rec, StringBuffer sb) {
    sb.write('${rec.time} ${rec.level.name} '
        '${rec.loggerName} - ${rec.message}');

    if (rec.error != null) {
      sb.writeln();
      sb.write('### ${rec.error?.runtimeType}: ');
      sb.write(rec.error);
    }
    // ignore: avoid_as
    final stackTrace = rec.stackTrace ??
        (rec.error is Error ? (rec.error as Error).stackTrace : null);
    if (stackTrace != null) {
      sb.writeln();
      sb.write(stackTrace);
    }
    return sb;
  }
}
