// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// @dart = 2.8

import 'dart:convert';
import 'dart:io' as io show Directory, File, Link, ProcessException, ProcessResult, ProcessSignal, systemEncoding, Process, ProcessStartMode;
import 'dart:typed_data';

import 'package:file/file.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p; // ignore: package_path_import
import 'package:process/process.dart';

import '../reporting/reporting.dart';
import 'common.dart' show throwToolExit;
import 'platform.dart';

// The Flutter tool hits file system and process errors that only the end-user can address.
// We would like these errors to not hit crash logging. In these cases, we
// should exit gracefully and provide potentially useful advice. For example, if
// a write fails because the target device is full, we can explain that with a
// ToolExit and a message that is more clear than the FileSystemException by
// itself.

/// A [FileSystem] that throws a [ToolExit] on certain errors.
///
/// If a [FileSystem] error is not caused by the Flutter tool, and can only be
/// addressed by the user, it should be caught by this [FileSystem] and thrown
/// as a [ToolExit] using [throwToolExit].
///
/// Cf. If there is some hope that the tool can continue when an operation fails
/// with an error, then that error/operation should not be handled here. For
/// example, the tool should generally be able to continue executing even if it
/// fails to delete a file.
class ErrorHandlingFileSystem extends ForwardingFileSystem {
  ErrorHandlingFileSystem({
    @required FileSystem delegate,
    @required Platform platform,
  }) :
      assert(delegate != null),
      assert(platform != null),
      _platform = platform,
      super(delegate);

  @visibleForTesting
  FileSystem get fileSystem => delegate;

  final Platform _platform;

  /// Allow any file system operations executed within the closure to fail with any
  /// operating system error, rethrowing an [Exception] instead of a [ToolExit].
  ///
  /// This should not be used with async file system operation.
  ///
  /// This can be used to bypass the [ErrorHandlingFileSystem] permission exit
  /// checks for situations where failure is acceptable, such as the flutter
  /// persistent settings cache.
  static void noExitOnFailure(void Function() operation) {
    final bool previousValue = ErrorHandlingFileSystem._noExitOnFailure;
    try {
      ErrorHandlingFileSystem._noExitOnFailure = true;
      operation();
    } finally {
      ErrorHandlingFileSystem._noExitOnFailure = previousValue;
    }
  }

  /// Delete the file or directory and return true if it exists, take no
  /// action and return false if it does not.
  ///
  /// This method should be preferred to checking if it exists and
  /// then deleting, because it handles the edge case where the file or directory
  /// is deleted by a different program between the two calls.
  static bool deleteIfExists(FileSystemEntity file, {bool recursive = false}) {
    if (!file.existsSync()) {
      return false;
    }
    try {
      file.deleteSync(recursive: recursive);
    } on FileSystemException catch (err) {
      // Certain error codes indicate the file could not be found. It could have
      // been deleted by a different program while the tool was running.
      // if it still exists, the file likely exists on a read-only volume.
      //
      // On windows this is error code 2: ERROR_FILE_NOT_FOUND, and on
      // macOS/Linux it is error code 2/ENOENT: No such file or directory.
      const int kSystemCannotFindFile = 2;
      if (err?.osError?.errorCode != kSystemCannotFindFile || _noExitOnFailure) {
        rethrow;
      }
      if (file.existsSync()) {
        throwToolExit(
          'The Flutter tool tried to delete the file or directory ${file.path} but was '
          'unable to. This may be due to the file and/or project\'s location on a read-only '
          'volume. Consider relocating the project and trying again',
        );
      }
    }
    return true;
  }

  static bool _noExitOnFailure = false;

  @override
  Directory get currentDirectory {
    return _runSync(() =>  directory(delegate.currentDirectory), platform: _platform);
  }

  @override
  File file(dynamic path) => ErrorHandlingFile(
    platform: _platform,
    fileSystem: delegate,
    delegate: delegate.file(path),
  );

  @override
  Directory directory(dynamic path) => ErrorHandlingDirectory(
    platform: _platform,
    fileSystem: delegate,
    delegate: delegate.directory(path),
  );

  @override
  Link link(dynamic path) => ErrorHandlingLink(
    platform: _platform,
    fileSystem: delegate,
    delegate: delegate.link(path),
  );

  // Caching the path context here and clearing when the currentDirectory setter
  // is updated works since the flutter tool restricts usage of dart:io directly
  // via the forbidden import tests. Otherwise, the path context's current
  // working directory might get out of sync, leading to unexpected results from
  // methods like `path.relative`.
  @override
  p.Context get path => _cachedPath ??= delegate.path;
  p.Context _cachedPath;

  @override
  set currentDirectory(dynamic path) {
    _cachedPath = null;
    delegate.currentDirectory = path;
  }

  @override
  String toString() => delegate.toString();
}

class ErrorHandlingFile
    extends ForwardingFileSystemEntity<File, io.File>
    with ForwardingFile {
  ErrorHandlingFile({
    @required Platform platform,
    @required this.fileSystem,
    @required this.delegate,
  }) :
    assert(platform != null),
    assert(fileSystem != null),
    assert(delegate != null),
    _platform = platform;

  @override
  final io.File delegate;

  @override
  final FileSystem fileSystem;

  final Platform _platform;

  @override
  File wrapFile(io.File delegate) => ErrorHandlingFile(
    platform: _platform,
    fileSystem: fileSystem,
    delegate: delegate,
  );

  @override
  Directory wrapDirectory(io.Directory delegate) => ErrorHandlingDirectory(
    platform: _platform,
    fileSystem: fileSystem,
    delegate: delegate,
  );

  @override
  Link wrapLink(io.Link delegate) => ErrorHandlingLink(
    platform: _platform,
    fileSystem: fileSystem,
    delegate: delegate,
  );

  @override
  Future<File> writeAsBytes(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) async {
    return _run<File>(
      () async => wrap(await delegate.writeAsBytes(
        bytes,
        mode: mode,
        flush: flush,
      )),
      platform: _platform,
      failureMessage: 'Flutter failed to write to a file at "${delegate.path}"',
    );
  }

  @override
  String readAsStringSync({Encoding encoding = utf8}) {
    return _runSync<String>(
      () => delegate.readAsStringSync(),
      platform: _platform,
      failureMessage: 'Flutter failed to read a file at "${delegate.path}"',
    );
  }

  @override
  void writeAsBytesSync(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) {
    _runSync<void>(
      () => delegate.writeAsBytesSync(bytes, mode: mode, flush: flush),
      platform: _platform,
      failureMessage: 'Flutter failed to write to a file at "${delegate.path}"',
    );
  }

  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) async {
    return _run<File>(
      () async => wrap(await delegate.writeAsString(
        contents,
        mode: mode,
        encoding: encoding,
        flush: flush,
      )),
      platform: _platform,
      failureMessage: 'Flutter failed to write to a file at "${delegate.path}"',
    );
  }

  @override
  void writeAsStringSync(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) {
    _runSync<void>(
      () => delegate.writeAsStringSync(
        contents,
        mode: mode,
        encoding: encoding,
        flush: flush,
      ),
      platform: _platform,
      failureMessage: 'Flutter failed to write to a file at "${delegate.path}"',
    );
  }

  @override
  void createSync({bool recursive = false}) {
    _runSync<void>(
      () => delegate.createSync(
        recursive: recursive,
      ),
      platform: _platform,
      failureMessage: 'Flutter failed to create file at "${delegate.path}"',
    );
  }

  @override
  RandomAccessFile openSync({FileMode mode = FileMode.read}) {
    return _runSync<RandomAccessFile>(
      () => delegate.openSync(
        mode: mode,
      ),
      platform: _platform,
      failureMessage: 'Flutter failed to open a file at "${delegate.path}"',
    );
  }

  /// This copy method attempts to handle file system errors from both reading
  /// and writing the copied file.
  @override
  File copySync(String newPath) {
    final File resultFile = fileSystem.file(newPath);
    // First check if the source file can be read. If not, bail through error
    // handling.
    _runSync<void>(
      () => delegate.openSync(mode: FileMode.read).closeSync(),
      platform: _platform,
      failureMessage: 'Flutter failed to copy $path to $newPath due to source location error'
    );
    // Next check if the destination file can be written. If not, bail through
    // error handling.
    _runSync<void>(
      () => resultFile.createSync(recursive: true),
      platform: _platform,
      failureMessage: 'Flutter failed to copy $path to $newPath due to destination location error'
    );
    // If both of the above checks passed, attempt to copy the file and catch
    // any thrown errors.
    try {
      return wrapFile(delegate.copySync(newPath));
    } on FileSystemException {
      // Proceed below
    }
    // If the copy failed but both of the above checks passed, copy the bytes
    // directly.
    _runSync(() {
      RandomAccessFile source;
      RandomAccessFile sink;
      try {
        source = delegate.openSync(mode: FileMode.read);
        sink = resultFile.openSync(mode: FileMode.writeOnly);
        // 64k is the same sized buffer used by dart:io for `File.openRead`.
        final Uint8List buffer = Uint8List(64 * 1024);
        final int totalBytes = source.lengthSync();
        int bytes = 0;
        while (bytes < totalBytes) {
          final int chunkLength = source.readIntoSync(buffer);
          sink.writeFromSync(buffer, 0, chunkLength);
          bytes += chunkLength;
        }
      } catch (err) { // ignore: avoid_catches_without_on_clauses
        ErrorHandlingFileSystem.deleteIfExists(resultFile, recursive: true);
        rethrow;
      } finally {
        source?.closeSync();
        sink?.closeSync();
      }
    }, platform: _platform, failureMessage: 'Flutter failed to copy $path to $newPath due to unknown error');
    // The original copy failed, but the manual copy worked. Report an analytics event to
    // track this to determine if this code path is actually hit.
    ErrorHandlingEvent('copy-fallback').send();
    return wrapFile(resultFile);
  }

  @override
  String toString() => delegate.toString();
}

class ErrorHandlingDirectory
    extends ForwardingFileSystemEntity<Directory, io.Directory>
    with ForwardingDirectory<Directory> {
  ErrorHandlingDirectory({
    @required Platform platform,
    @required this.fileSystem,
    @required this.delegate,
  }) :
    assert(platform != null),
    assert(fileSystem != null),
    assert(delegate != null),
    _platform = platform;

  @override
  final io.Directory delegate;

  @override
  final FileSystem fileSystem;

  final Platform _platform;

  @override
  File wrapFile(io.File delegate) => ErrorHandlingFile(
    platform: _platform,
    fileSystem: fileSystem,
    delegate: delegate,
  );

  @override
  Directory wrapDirectory(io.Directory delegate) => ErrorHandlingDirectory(
    platform: _platform,
    fileSystem: fileSystem,
    delegate: delegate,
  );

  @override
  Link wrapLink(io.Link delegate) => ErrorHandlingLink(
    platform: _platform,
    fileSystem: fileSystem,
    delegate: delegate,
  );

  // For the childEntity methods, we first obtain an instance of the entity
  // from the underlying file system, then invoke childEntity() on it, then
  // wrap in the ErrorHandling version.
  @override
  Directory childDirectory(String basename) =>
    wrapDirectory(fileSystem.directory(delegate).childDirectory(basename));

  @override
  File childFile(String basename) =>
    wrapFile(fileSystem.directory(delegate).childFile(basename));

  @override
  Link childLink(String basename) =>
    wrapLink(fileSystem.directory(delegate).childLink(basename));

  @override
  void createSync({bool recursive = false}) {
    return _runSync<void>(
      () => delegate.createSync(recursive: recursive),
      platform: _platform,
      failureMessage:
        'Flutter failed to create a directory at "${delegate.path}"',
    );
  }

  @override
  Future<Directory> createTemp([String prefix]) {
    return _run<Directory>(
      () async => wrap(await delegate.createTemp(prefix)),
      platform: _platform,
      failureMessage:
        'Flutter failed to create a temporary directory with prefix "$prefix"',
    );
  }

  @override
  Directory createTempSync([String prefix]) {
    return _runSync<Directory>(
      () => wrap(delegate.createTempSync(prefix)),
      platform: _platform,
      failureMessage:
        'Flutter failed to create a temporary directory with prefix "$prefix"',
    );
  }

  @override
  Future<Directory> create({bool recursive = false}) {
    return _run<Directory>(
      () async => wrap(await delegate.create(recursive: recursive)),
      platform: _platform,
      failureMessage:
        'Flutter failed to create a directory at "${delegate.path}"',
    );
  }

  @override
  Future<Directory> delete({bool recursive = false}) {
    return _run<Directory>(
      () async => wrap(fileSystem.directory((await delegate.delete(recursive: recursive)).path)),
      platform: _platform,
      failureMessage:
        'Flutter failed to delete a directory at "${delegate.path}"',
    );
  }

  @override
  void deleteSync({bool recursive = false}) {
    return _runSync<void>(
      () => delegate.deleteSync(recursive: recursive),
      platform: _platform,
      failureMessage:
        'Flutter failed to delete a directory at "${delegate.path}"',
    );
  }

  @override
  bool existsSync() {
    return _runSync<bool>(
      () => delegate.existsSync(),
      platform: _platform,
      failureMessage:
        'Flutter failed to check for directory existence at "${delegate.path}"',
    );
  }

  @override
  String toString() => delegate.toString();
}

class ErrorHandlingLink
    extends ForwardingFileSystemEntity<Link, io.Link>
    with ForwardingLink {
  ErrorHandlingLink({
    @required Platform platform,
    @required this.fileSystem,
    @required this.delegate,
  }) :
    assert(platform != null),
    assert(fileSystem != null),
    assert(delegate != null),
    _platform = platform;

  @override
  final io.Link delegate;

  @override
  final FileSystem fileSystem;

  final Platform _platform;

  @override
  File wrapFile(io.File delegate) => ErrorHandlingFile(
    platform: _platform,
    fileSystem: fileSystem,
    delegate: delegate,
  );

  @override
  Directory wrapDirectory(io.Directory delegate) => ErrorHandlingDirectory(
    platform: _platform,
    fileSystem: fileSystem,
    delegate: delegate,
  );

  @override
  Link wrapLink(io.Link delegate) => ErrorHandlingLink(
    platform: _platform,
    fileSystem: fileSystem,
    delegate: delegate,
  );

  @override
  String toString() => delegate.toString();
}

Future<T> _run<T>(Future<T> Function() op, {
  @required Platform platform,
  String failureMessage,
}) async {
  assert(platform != null);
  try {
    return await op();
  } on FileSystemException catch (e) {
    if (platform.isWindows) {
      _handleWindowsException(e, failureMessage, e.osError?.errorCode ?? 0);
    } else if (platform.isLinux || platform.isMacOS) {
      _handlePosixException(e, failureMessage, e.osError?.errorCode ?? 0);
    }
    rethrow;
  } on io.ProcessException catch (e) {
    if (platform.isWindows) {
      _handleWindowsException(e, failureMessage, e.errorCode ?? 0);
    } else if (platform.isLinux || platform.isMacOS) {
      _handlePosixException(e, failureMessage, e.errorCode ?? 0);
    }
    rethrow;
  }
}

T _runSync<T>(T Function() op, {
  @required Platform platform,
  String failureMessage,
}) {
  assert(platform != null);
  try {
    return op();
  } on FileSystemException catch (e) {
    if (platform.isWindows) {
      _handleWindowsException(e, failureMessage, e.osError?.errorCode ?? 0);
    } else if (platform.isLinux || platform.isMacOS) {
      _handlePosixException(e, failureMessage, e.osError?.errorCode ?? 0);
    }
    rethrow;
  } on io.ProcessException catch (e) {
    if (platform.isWindows) {
      _handleWindowsException(e, failureMessage, e.errorCode ?? 0);
    } else if (platform.isLinux || platform.isMacOS) {
      _handlePosixException(e, failureMessage, e.errorCode ?? 0);
    }
    rethrow;
  }
}

class _ProcessDelegate {
  const _ProcessDelegate();

  Future<io.Process> start(
    List<String> command, {
    String workingDirectory,
    Map<String, String> environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    io.ProcessStartMode mode = io.ProcessStartMode.normal,
  }) {
    return io.Process.start(
      command[0],
      command.skip(1).toList(),
      workingDirectory: workingDirectory,
      environment: environment,
      includeParentEnvironment: includeParentEnvironment,
      runInShell: runInShell,
    );
  }

  Future<io.ProcessResult> run(
    List<String> command, {
    String workingDirectory,
    Map<String, String> environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    Encoding stdoutEncoding = io.systemEncoding,
    Encoding stderrEncoding = io.systemEncoding,
  }) {
    return io.Process.run(
      command[0],
      command.skip(1).toList(),
      workingDirectory: workingDirectory,
      environment: environment,
      includeParentEnvironment: includeParentEnvironment,
      runInShell: runInShell,
      stdoutEncoding: stdoutEncoding,
      stderrEncoding: stderrEncoding,
    );
  }

  io.ProcessResult runSync(
    List<String> command, {
    String workingDirectory,
    Map<String, String> environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    Encoding stdoutEncoding = io.systemEncoding,
    Encoding stderrEncoding = io.systemEncoding,
  }) {
    return io.Process.runSync(
      command[0],
      command.skip(1).toList(),
      workingDirectory: workingDirectory,
      environment: environment,
      includeParentEnvironment: includeParentEnvironment,
      runInShell: runInShell,
      stdoutEncoding: stdoutEncoding,
      stderrEncoding: stderrEncoding,
    );
  }
}

/// A [ProcessManager] that throws a [ToolExit] on certain errors.
///
/// If a [ProcessException] is not caused by the Flutter tool, and can only be
/// addressed by the user, it should be caught by this [ProcessManager] and thrown
/// as a [ToolExit] using [throwToolExit].
///
/// See also:
///   * [ErrorHandlingFileSystem], for a similar file system strategy.
class ErrorHandlingProcessManager extends ProcessManager {
  ErrorHandlingProcessManager({
    @required ProcessManager delegate,
    @required Platform platform,
  }) : _delegate = delegate,
       _platform = platform;

  final ProcessManager _delegate;
  final Platform _platform;
  static const _ProcessDelegate _processDelegate = _ProcessDelegate();
  static bool _skipCommandLookup = false;

  /// Bypass package:process command lookup for all functions in this block.
  ///
  /// This required that the fully resolved executable path is provided.
  static Future<T> skipCommandLookup<T>(Future<T> Function() operation) async {
    final bool previousValue = ErrorHandlingProcessManager._skipCommandLookup;
    try {
      ErrorHandlingProcessManager._skipCommandLookup = true;
      return await operation();
    } finally {
      ErrorHandlingProcessManager._skipCommandLookup = previousValue;
    }
  }

  @override
  bool canRun(dynamic executable, {String workingDirectory}) {
    return _runSync(
      () => _delegate.canRun(executable, workingDirectory: workingDirectory),
      platform: _platform,
    );
  }

  @override
  bool killPid(int pid, [io.ProcessSignal signal = io.ProcessSignal.sigterm]) {
    return _runSync(
      () => _delegate.killPid(pid, signal),
      platform: _platform,
    );
  }

  @override
  Future<io.ProcessResult> run(
    List<dynamic> command, {
    String workingDirectory,
    Map<String, String> environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    Encoding stdoutEncoding = io.systemEncoding,
    Encoding stderrEncoding = io.systemEncoding,
  }) {
    return _run(() {
      if (_skipCommandLookup && _delegate is LocalProcessManager) {
       return _processDelegate.run(
          command.cast<String>(),
          workingDirectory: workingDirectory,
          environment: environment,
          includeParentEnvironment: includeParentEnvironment,
          runInShell: runInShell,
          stdoutEncoding: stdoutEncoding,
          stderrEncoding: stderrEncoding,
        );
      }
      return _delegate.run(
        command,
        workingDirectory: workingDirectory,
        environment: environment,
        includeParentEnvironment: includeParentEnvironment,
        runInShell: runInShell,
        stdoutEncoding: stdoutEncoding,
        stderrEncoding: stderrEncoding,
      );
    }, platform: _platform);
  }

  @override
  Future<io.Process> start(
    List<dynamic> command, {
    String workingDirectory,
    Map<String, String> environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    io.ProcessStartMode mode = io.ProcessStartMode.normal,
  }) {
    return _run(() {
      if (_skipCommandLookup && _delegate is LocalProcessManager) {
        return _processDelegate.start(
          command.cast<String>(),
          workingDirectory: workingDirectory,
          environment: environment,
          includeParentEnvironment: includeParentEnvironment,
          runInShell: runInShell,
        );
      }
      return _delegate.start(
        command,
        workingDirectory: workingDirectory,
        environment: environment,
        includeParentEnvironment: includeParentEnvironment,
        runInShell: runInShell,
      );
    }, platform: _platform);
  }

  @override
  io.ProcessResult runSync(
    List<dynamic> command, {
    String workingDirectory,
    Map<String, String> environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    Encoding stdoutEncoding = io.systemEncoding,
    Encoding stderrEncoding = io.systemEncoding,
  }) {
    return _runSync(() {
      if (_skipCommandLookup && _delegate is LocalProcessManager) {
        return _processDelegate.runSync(
          command.cast<String>(),
          workingDirectory: workingDirectory,
          environment: environment,
          includeParentEnvironment: includeParentEnvironment,
          runInShell: runInShell,
          stdoutEncoding: stdoutEncoding,
          stderrEncoding: stderrEncoding,
        );
      }
      return _delegate.runSync(
        command,
        workingDirectory: workingDirectory,
        environment: environment,
        includeParentEnvironment: includeParentEnvironment,
        runInShell: runInShell,
        stdoutEncoding: stdoutEncoding,
        stderrEncoding: stderrEncoding,
      );
    }, platform: _platform);
  }
}

void _handlePosixException(Exception e, String message, int errorCode) {
  // From:
  // https://github.com/torvalds/linux/blob/master/include/uapi/asm-generic/errno.h
  // https://github.com/torvalds/linux/blob/master/include/uapi/asm-generic/errno-base.h
  // https://github.com/apple/darwin-xnu/blob/master/bsd/dev/dtrace/scripts/errno.d
  const int eperm = 1;
  const int enospc = 28;
  const int eacces = 13;
  // Catch errors and bail when:
  String errorMessage;
  switch (errorCode) {
    case enospc:
      errorMessage =
        '$message. The target device is full.'
        '\n$e\n'
        'Free up space and try again.';
      break;
    case eperm:
    case eacces:
      errorMessage =
        '$message. The flutter tool cannot access the file or directory.\n'
        'Please ensure that the SDK and/or project is installed in a location '
        'that has read/write permissions for the current user.';
      break;
    default:
      // Caller must rethrow the exception.
      break;
  }
  _throwFileSystemException(errorMessage);
}

void _handleWindowsException(Exception e, String message, int errorCode) {
  // From:
  // https://docs.microsoft.com/en-us/windows/win32/debug/system-error-codes
  const int kDeviceFull = 112;
  const int kUserMappedSectionOpened = 1224;
  const int kAccessDenied = 5;
  const int kFatalDeviceHardwareError = 483;

  // Catch errors and bail when:
  String errorMessage;
  switch (errorCode) {
    case kAccessDenied:
      errorMessage =
        '$message. The flutter tool cannot access the file or directory.\n'
        'Please ensure that the SDK and/or project is installed in a location '
        'that has read/write permissions for the current user.';
      break;
    case kDeviceFull:
      errorMessage =
        '$message. The target device is full.'
        '\n$e\n'
        'Free up space and try again.';
      break;
    case kUserMappedSectionOpened:
      errorMessage =
        '$message. The file is being used by another program.'
        '\n$e\n'
        'Do you have an antivirus program running? '
        'Try disabling your antivirus program and try again.';
      break;
    case kFatalDeviceHardwareError:
      errorMessage =
        '$message. There is a problem with the device driver '
        'that this file or directory is stored on.';
      break;
    default:
      // Caller must rethrow the exception.
      break;
  }
  _throwFileSystemException(errorMessage);
}

void _throwFileSystemException(String errorMessage) {
  if (errorMessage == null) {
    return;
  }
  if (ErrorHandlingFileSystem._noExitOnFailure) {
    throw Exception(errorMessage);
  }
  throwToolExit(errorMessage);
}
