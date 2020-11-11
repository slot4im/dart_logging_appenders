import 'dart:async';
import 'dart:collection';

import 'package:logging/logging.dart';
import 'package:logging_appenders/logging_appenders.dart';
import 'package:logging_appenders/src/base_appender.dart';
import 'package:logging_appenders/src/internal/dummy_logger.dart';
import 'package:meta/meta.dart';

final _logger = DummyLogger('logging_appenders.base_remote_appender');

/// Base appender for services which should buffer log messages before
/// handling them. (eg. because they use network traffic which make it
/// unfeasible to send every log line on it's own).
///
abstract class BaseLogSender extends BaseLogAppender {
  BaseLogSender({
    LogRecordFormatter formatter,
    int bufferSize,
  })  : bufferSize = bufferSize ?? 500,
        super(formatter);

  Map<String, String> _userProperties = {};

  /// Maximum number of log entries to buffer before triggering sending
  /// of log entries. (default: 500)
  final int bufferSize;

  List<LogEntry> _logEvents = <LogEntry>[];
  Timer _timer;

  final SimpleJobQueue _sendQueue = SimpleJobQueue();

  set userProperties(Map<String, String> userProperties) {
    _userProperties = userProperties;
  }

  Future<void> log(DateTime time, String line, Map<String, String> lineLabels) {
    return _logEvent(LogEntry(ts: time, line: line, lineLabels: lineLabels));
  }

  Future<void> _logEvent(LogEntry log) {
    _timer?.cancel();
    _timer = null;
    _logEvents.add(log);
    if (_logEvents.length > bufferSize) {
      _triggerSendLogEvents();
    } else {
      _timer = Timer(const Duration(seconds: 10), () {
        _timer = null;
        _triggerSendLogEvents();
      });
    }
    return Future.value(null);
  }

  @protected
  Stream<void> sendLogEvents(
      List<LogEntry> logEntries, Map<String, String> userProperties);

  Future<void> _triggerSendLogEvents() => Future(() {
        final entries = _logEvents;
        _logEvents = [];
        _sendQueue.add(SimpleJobDef(
          runner: (job) => sendLogEvents(entries, _userProperties),
        ));
        return _sendQueue.triggerJobRuns().then((val) {
          _logger.finest('Sent log jobs: $val');
          return null;
        });
      });

  @override
  void handle(LogRecord record) {
    final message = formatter.format(record);
    final lineLabels = {
      'lvl': record.level.name,
      'logger': record.loggerName,
    };
    if (record.error != null) {
      lineLabels['e'] = record.error.toString();
      lineLabels['eType'] = record.error.runtimeType.toString();
    }
    log(record.time, message, lineLabels);
  }

  Future<void> flush() => _triggerSendLogEvents();
}

/// Helper base class to handle Dio errors during network requests.
abstract class BaseDioLogSender extends BaseLogSender {
  BaseDioLogSender({
    LogRecordFormatter formatter,
    int bufferSize,
  }) : super(formatter: formatter, bufferSize: bufferSize);

  Future<void> sendLogEventsWithHttpClient(
      List<LogEntry> entries, Map<String, String> userProperties);

  @override
  Stream<void> sendLogEvents(
      List<LogEntry> logEntries, Map<String, String> userProperties) {
    final streamController = StreamController<void>();
    streamController.onCancel = () {};
    streamController.onListen = () {
      sendLogEventsWithHttpClient(logEntries, userProperties).then((val) {
        if (!streamController.isClosed) {
          streamController.add(null);
          streamController.close();
        }
      }).catchError((Object err, StackTrace stackTrace) {
        // var message = err.runtimeType.toString();

        // if (err.response != null) {
        //   message = 'response:' + err.response.data?.toString();
        // }
        _logger.warning(
            'Error while sending logs. ${err.runtimeType}', err, stackTrace);
        if (!streamController.isClosed) {
          streamController.addError(err, stackTrace);
          streamController.close();
        }
      });
    };
    return streamController.stream;
  }
}

class LogEntry {
  LogEntry({@required this.ts, @required this.line, @required this.lineLabels});

  final DateTime ts;
  final String line;
  final Map<String, String> lineLabels;

  String get tsFormatted => ts.toUtc().toIso8601String();
}

typedef SimpleJobRunner = Stream<void> Function(SimpleJobDef job);

class SimpleJobDef {
  SimpleJobDef({@required this.runner});

  bool completedSuccessfully = false;

  final SimpleJobRunner runner;
}

class SimpleJobQueue {
  SimpleJobQueue({this.maxQueueSize = 100});

  final int maxQueueSize;

  final Queue<SimpleJobDef> _queue = Queue<SimpleJobDef>();

  StreamSubscription<void> _currentStream;

  int _errorCount = 0;
  DateTime _lastError;

  void add(SimpleJobDef job) {
    _queue.addLast(job);
  }

  Future<int> triggerJobRuns() {
    if (_currentStream != null) {
      _logger.info('Already running jobs. Ignoring trigger.');
      return Future.value(0);
    }
    _logger.finest('Triggering Job Runs. ${_queue.length}');
    final completer = Completer<int>();
    var successfulJobs = 0;
//    final job = _queue.removeFirst();
    _currentStream = (() async* {
      for (final job
          in _queue.where((job) => job.completedSuccessfully == false)) {
        await job.runner(job).drain(null);
        yield job;
      }
    })()
        .listen((successJob) {
      successJob.completedSuccessfully = true;

      successfulJobs++;
      _logger.finest(
          'Success job. remaining: ${_queue.length} - completed: $successfulJobs');
    }, onDone: () {
      _logger.finest('All jobs done.');
      _errorCount = 0;
      _lastError = null;
      _queue.removeWhere((job) => job.completedSuccessfully == true);
      _currentStream = null;
      completer.complete(successfulJobs);
    }, onError: (dynamic error, StackTrace stackTrace) {
      _logger.warning('Error while executing job', error, stackTrace);
      _errorCount++;
      _lastError = DateTime.now();
      _currentStream.cancel();
      _currentStream = null;
      completer.completeError(error, stackTrace);

      const errorWait = 10;
      final minWait =
          Duration(seconds: errorWait * (_errorCount * _errorCount + 1));
      if (_lastError.difference(DateTime.now()).abs().compareTo(minWait) < 0) {
        _logger.finest('There was an error. waiting at least $minWait');
        if (_queue.length > maxQueueSize) {
          _logger.finest('clearing log buffer. ${_queue.length}');
          _queue.clear();
        }
      }
      return Future.value(null);
    });

    return completer.future;
  }
}
