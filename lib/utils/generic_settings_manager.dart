import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mutex/mutex.dart';
import 'package:path/path.dart' as p;
import 'package:toml/toml.dart';
import 'package:trios/trios/constants.dart';
import 'package:trios/utils/extensions.dart';
import 'package:trios/utils/logging.dart'; // For path operations

/// Supported file formats for the settings file.
enum FileFormat { toml, json }
final Duration _debounceDuration = Duration(milliseconds: 300);

/// A generic class for managing settings stored in TOML or JSON files.
/// This class can be used independently of Riverpod.
abstract class GenericAsyncSettingsManager<T> {
  late File settingsFile;
  late String _fileName;
  final _mutex = Mutex();

  /// The current state of the settings.
  late T state;

  /// Specifies the file format for the settings file.
  FileFormat get fileFormat;

  /// Subclasses must provide a factory for default state creation.
  T Function() get createDefaultState;

  /// Subclasses must provide a function to serialize the settings to a map.
  Map<String, dynamic> Function(T obj) get toMap;

  /// Subclasses must provide a function to deserialize a map into the settings object.
  T Function(Map<String, dynamic> map) get fromMap;

  /// Override to do custom serialization
  Future<String> serialize(T obj) async {
    return fileFormat == FileFormat.toml
        ? TomlDocument.fromMap(toMap(obj).removeNullValues()).toString()
        : jsonEncode(toMap(obj));
  }

  /// Override to do custom deserialization
  Future<T> deserialize(String contents) async {
    return fileFormat == FileFormat.toml
        ? fromMap(TomlDocument.parse(contents).toMap())
        : fromMap(jsonDecode(contents) as Map<String, dynamic>);
  }

  /// The name of the file where settings will be stored.
  String get fileName;

  /// Resolves the path for the settings file and ensures the directory exists.
  Future<File> _getFile() async {
    final dir = await getConfigDataFolderPath();
    await dir.create(recursive: true);
    final path = p.join(dir.path, _fileName);
    Fimber.i("Settings file path resolved: $path");
    return File(path);
  }

  /// Implement this method to provide the configuration data folder path.
  Future<Directory> getConfigDataFolderPath() =>
      Future.value(Constants.configDataFolderPath);

  /// Initializes and loads the state from the settings file (TOML or JSON),
  /// or uses the default state if the file is missing or invalid.
  Future<T> readSettingsFromDisk() async {
    _fileName = fileName;
    settingsFile = await _getFile();

    return await _mutex.protect(() async {
      if (await settingsFile.exists()) {
        try {
          final contents = await settingsFile.readAsString();
          final loadedState = await deserialize(contents);
          Fimber.i("Settings successfully loaded from disk.");
          state = loadedState;
          return state;
        } catch (e, stacktrace) {
          Fimber.e("Error reading from disk, creating backup and then wiping: $e",
              ex: e, stacktrace: stacktrace);
          await _createBackup();
          state = createDefaultState();
          return state;
        }
      } else {
        Fimber.i("Settings file does not exist, creating default state.");
        state = createDefaultState();
        scheduleWriteSettingsToDisk();
        return state;
      }
    });
  }

  // Debouncing variables
  Timer? _debounceTimer;
  Completer<void>? _writeCompleter;

  /// Schedules a write operation to disk.
  Future<void> scheduleWriteSettingsToDisk() {
    // Cancel any existing timer
    _debounceTimer?.cancel();

    // Create a new completer if none exists or the previous one is completed
    if (_writeCompleter == null || _writeCompleter!.isCompleted) {
      _writeCompleter = Completer<void>();
    }

    _debounceTimer = Timer(_debounceDuration, () async {
      try {
        final serializedData = await serialize(state);
        await settingsFile.writeAsString(serializedData);
        Fimber.i("Settings successfully written to disk.");
        _writeCompleter?.complete();
      } catch (e, stackTrace) {
        Fimber.e("Error serializing and saving settings data: $e",
            ex: e, stacktrace: stackTrace);
        _writeCompleter?.completeError(e, stackTrace);
        rethrow;
      } finally {
        _writeCompleter = null;
      }
    });

    return _writeCompleter!.future;
  }

  /// Updates the current state using the provided mutator function and persists the updated state to disk.
  Future<T> update(
    FutureOr<T> Function(T currentState) mutator, {
    FutureOr<T> Function(Object, StackTrace)? onError,
  }) async {
    return await _mutex.protect(() async {
      final oldState = state;
      try {
        final newState = await mutator(oldState);

        if (newState != oldState) {
          state = newState;
          Fimber.i("Settings updated, writing to disk...");
          scheduleWriteSettingsToDisk();
        } else {
          Fimber.v(() => "No settings change detected.");
        }

        return state;
      } catch (e, stacktrace) {
        if (onError != null) {
          return await onError(e, stacktrace);
        } else {
          Fimber.e("Error during settings update: $e",
              ex: e, stacktrace: stacktrace);
          rethrow;
        }
      }
    });
  }

  /// Creates a backup of the current settings file with a `.bak` extension.
  Future<void> _createBackup() async {
    File backupFile;
    final backupFileName = "${_fileName}_backup.bak";
    backupFile = File(p.join(settingsFile.parent.path, backupFileName));

    await settingsFile.copy(backupFile.path);
    Fimber.i("Backup created at ${backupFile.path}");
  }
}

/// A simple synchronous lock for thread safety.
class SyncLock {
  bool _locked = false;

  void lock() {
    if (_locked) {
      throw StateError('Lock is already acquired');
    }
    _locked = true;
  }

  void unlock() {
    if (!_locked) {
      throw StateError('Lock is not acquired');
    }
    _locked = false;
  }

  T protectSync<T>(T Function() action) {
    lock();
    try {
      return action();
    } finally {
      unlock();
    }
  }
}

/// A generic class for managing settings stored in TOML or JSON files.
/// This class can be used independently of Riverpod.
abstract class GenericSettingsManager<T> {
  late File settingsFile;
  late String _fileName;
  final _lock = SyncLock();

  /// The current state of the settings.
  late T state;

  /// Specifies the file format for the settings file.
  FileFormat get fileFormat;

  /// Subclasses must provide a factory for default state creation.
  T Function() get createDefaultState;

  /// Subclasses must provide a function to serialize the settings to a map.
  Map<String, dynamic> Function(T obj) get toMap;

  /// Subclasses must provide a function to deserialize a map into the settings object.
  T Function(Map<String, dynamic> map) get fromMap;

  /// The name of the file where settings will be stored.
  String get fileName;

  /// Resolves the path for the settings file and ensures the directory exists.
  File _getFileSync() {
    final dir = getConfigDataFolderPathSync();
    dir.createSync(recursive: true);
    final path = p.join(dir.path, _fileName);
    Fimber.i("Settings file path resolved: $path");
    return File(path);
  }

  /// Implement this method to provide the configuration data folder path synchronously.
  Directory getConfigDataFolderPathSync() => Constants.configDataFolderPath;

  /// Initializes and loads the state from the settings file (TOML or JSON),
  /// or uses the default state if the file is missing or invalid.
  void loadSync() {
    _fileName = fileName;
    settingsFile = _getFileSync();

    _lock.protectSync(() {
      if (settingsFile.existsSync()) {
        try {
          final contents = settingsFile.readAsStringSync();
          final loadedState = fileFormat == FileFormat.toml
              ? fromMap(TomlDocument.parse(contents).toMap())
              : fromMap(jsonDecode(contents) as Map<String, dynamic>);
          Fimber.i("Settings successfully loaded from disk.");
          state = loadedState;
        } catch (e, stacktrace) {
          Fimber.e("Error reading from disk, creating backup: $e",
              ex: e, stacktrace: stacktrace);
          _createBackupSync();
          state = createDefaultState();
        }
      } else {
        Fimber.i("Settings file does not exist, creating default state.");
        state = createDefaultState();
        writeSettingsToDiskSync(state);
      }
    });
  }

  // Debouncing variables
  Timer? _debounceTimer;

  /// Writes the provided state to the settings file (TOML or JSON) on disk with debouncing.
  void writeSettingsToDiskSync(T currentState) {
    // Cancel any existing timer
    _debounceTimer?.cancel();

    // Schedule a new write
    _debounceTimer = Timer(_debounceDuration, () {
      try {
        final serializedData = fileFormat == FileFormat.toml
            ? TomlDocument.fromMap(toMap(currentState)).toString()
            : jsonEncode(toMap(currentState));
        settingsFile.writeAsStringSync(serializedData);
        Fimber.i("Settings successfully written to disk.");
      } catch (e, stackTrace) {
        Fimber.e("Error serializing and saving settings data: $e",
            ex: e, stacktrace: stackTrace);
        rethrow;
      }
    });
  }

  /// Updates the current state using the provided mutator function and persists the updated state to disk.
  T updateSync(
    T Function(T currentState) mutator, {
    T Function(Object, StackTrace)? onError,
  }) {
    return _lock.protectSync(() {
      final oldState = state;
      try {
        final newState = mutator(oldState);

        if (newState != oldState) {
          state = newState;
          Fimber.i("Settings updated, writing to disk...");
          writeSettingsToDiskSync(state);
        } else {
          Fimber.v(() => "No settings change detected.");
        }

        return state;
      } catch (e, stacktrace) {
        if (onError != null) {
          return onError(e, stacktrace);
        } else {
          Fimber.e("Error during settings update: $e",
              ex: e, stacktrace: stacktrace);
          rethrow;
        }
      }
    });
  }

  /// Creates a backup of the current settings file with a `.bak` extension synchronously.
  void _createBackupSync() {
    int backupNumber = 1;
    File backupFile;
    do {
      final backupFileName = "${_fileName}_backup_$backupNumber.bak";
      backupFile = File(p.join(settingsFile.parent.path, backupFileName));
      backupNumber++;
    } while (backupFile.existsSync());

    settingsFile.copySync(backupFile.path);
    Fimber.i("Backup created at ${backupFile.path}");
  }
}
