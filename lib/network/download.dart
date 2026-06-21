import 'dart:async';
import 'dart:isolate';

import 'package:flutter/widgets.dart' show ChangeNotifier;
import 'package:flutter_saf/flutter_saf.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/network/images.dart';
import 'package:venera/utils/ext.dart';
import 'package:venera/utils/file_type.dart';
import 'package:venera/utils/io.dart';
import 'package:zip_flutter/zip_flutter.dart';

import 'file_downloader.dart';

abstract class DownloadTask with ChangeNotifier {
  /// 0-1
  double get progress;

  bool get isError;

  bool get isPaused;

  /// bytes per second
  int get speed;

  void cancel();

  void pause();

  void resume();

  String get title;

  String? get cover;

  String get message;

  /// root path for the comic. If null, the task is not scheduled.
  String? path;

  /// convert current state to json, which can be used to restore the task
  Map<String, dynamic> toJson();

  LocalComic toLocalComic();

  String get id;

  ComicType get comicType;

  /// Whether scheduler should auto-resume after entering error state.
  bool shouldAutoRetryOnError() => true;

  /// Source key used to open comic details from download list.
  String? get sourceKey => null;

  static DownloadTask? fromJson(Map<String, dynamic> json) {
    switch (json["type"]) {
      case "ImagesDownloadTask":
        return ImagesDownloadTask.fromJson(json);
      default:
        return null;
    }
  }

  @override
  bool operator ==(Object other) {
    return other is DownloadTask &&
        other.id == id &&
        other.comicType == comicType;
  }

  @override
  int get hashCode => Object.hash(id, comicType);
}

class ImagesDownloadTask extends DownloadTask with _TransferSpeedMixin {
  final ComicSource source;

  final String comicId;

  /// comic details. If null, the comic details will be fetched from the source.
  ComicDetails? comic;

  /// chapters to download. If null, all chapters will be downloaded.
  final List<String>? chapters;

  final bool skipRawChapters;

  @override
  String get id => comicId;

  @override
  ComicType get comicType => ComicType(source.key.hashCode);

  @override
  String? get sourceKey => source.key;

  String? comicTitle;

  ImagesDownloadTask({
    required this.source,
    required this.comicId,
    this.comic,
    this.chapters,
    this.comicTitle,
    this.skipRawChapters = true,
  });

  @override
  void cancel() {
    _isRunning = false;
    stopRecorder();
    final runningTasks = tasks.values.toList();
    for (final t in runningTasks) {
      if (!t.isComplete) {
        t.cancel();
      }
    }
    tasks.clear();

    final inBatchCancel = LocalManager().isBatchCancellingTasks;
    LocalManager().removeTask(this);

    if (inBatchCancel) {
      // Large batch cancel mode: skip heavy per-task file cleanup to avoid
      // massive IO/memory spikes and potential app crash.
      return;
    }

    var local = LocalManager().find(id, comicType);
    if (path != null) {
      if (local == null) {
        Future.sync(() async {
          for (var i = 0; i < runningTasks.length; i++) {
            if (!runningTasks[i].isComplete) {
              await runningTasks[i].wait();
            }
          }
          try {
            await Directory(path!).delete(recursive: true);
          } catch (e) {
            Log.error("Download", "Failed to delete directory: $e");
          }
        });
      } else if (chapters != null) {
        for (var c in chapters!) {
          var dir = Directory(FilePath.join(path!, c));
          if (dir.existsSync()) {
            dir.deleteSync(recursive: true);
          }
        }
      }
    }
  }

  @override
  String? get cover => _cover ?? comic?.cover;

  @override
  String get message => _message;

  @override
  bool shouldAutoRetryOnError() {
    final m = _message.toLowerCase();
    if (m.contains('failed to create chapter directory') ||
        m.contains('pathnotfoundexception') ||
        m.contains('creation failed') ||
        m.contains('under review') ||
        m.contains('format of accept header is invalid') ||
        m.contains('invalid status code: 400') ||
        m.contains('invalid status code: 404') ||
        m.contains('status code of 400') ||
        m.contains('status code of 404')) {
      return false;
    }
    return true;
  }

  @override
  void pause() {
    if (isPaused) {
      return;
    }
    _isRunning = false;
    _message = "Paused";
    _currentSpeed = 0;
    var shouldMove = <int>[];
    for (var entry in tasks.entries) {
      if (!entry.value.isComplete) {
        entry.value.cancel();
        shouldMove.add(entry.key);
      }
    }
    for (var i in shouldMove) {
      tasks.remove(i);
    }
    stopRecorder();
    notifyListeners();
  }

  @override
  double get progress => _totalCount == 0 ? 0 : _downloadedCount / _totalCount;

  bool _isRunning = false;

  bool _isError = false;

  String _message = "Fetching comic info...";

  String? _cover;

  /// All images to download, key is chapter name
  Map<String, List<String>>? _images;

  /// Downloaded image count
  int _downloadedCount = 0;

  /// Total image count
  int _totalCount = 0;

  /// Current downloading image index
  int _index = 0;

  /// Current downloading chapter, index of [_images]
  int _chapter = 0;

  var tasks = <int, _ImageDownloadWrapper>{};
  final Set<String> _completedImageKeys = {};
  final Map<String, Set<int>> _existingImageIndexesByChapter = {};
  final Map<String, String> _chapterDirNameOverrides = {};

  int _lastPersistDownloadedCount = 0;
  DateTime _lastPersistTime = DateTime.now();

  int get _maxConcurrentTasks =>
      (appdata.settings["downloadThreads"] as num).toInt();

  String _shortHash(String input) {
    int hash = 0;
    for (final c in input.codeUnits) {
      hash = ((hash * 31) + c) & 0x7fffffff;
    }
    return hash.toRadixString(36);
  }

  String _normalizeWindowsPath(String p) {
    if (!App.isWindows) {
      return p;
    }
    final source = p.replaceAll('/', '\\');
    final hasDrive = source.length >= 2 && source[1] == ':';
    final parts = source.split('\\');
    final normalized = <String>[];
    for (int i = 0; i < parts.length; i++) {
      var part = parts[i];
      if (i == 0 && hasDrive) {
        normalized.add(part);
        continue;
      }
      if (part.isEmpty) {
        continue;
      }
      while (part.endsWith(' ') || part.endsWith('.')) {
        part = part.substring(0, part.length - 1);
      }
      if (part.isEmpty) {
        continue;
      }
      normalized.add(part);
    }
    if (normalized.isEmpty) {
      return source;
    }
    return normalized.join('\\');
  }

  String _normalizeChapterFolderName(String raw, int maxLength) {
    var name = LocalManager.getChapterDirectoryName(raw).trim();
    while (name.endsWith(' ') || name.endsWith('.')) {
      name = name.substring(0, name.length - 1);
    }
    if (name.isEmpty) {
      name = '_';
    }
    if (maxLength > 0 && name.length > maxLength) {
      name = name.substring(0, maxLength);
      while (name.endsWith(' ') || name.endsWith('.')) {
        name = name.substring(0, name.length - 1);
      }
      if (name.isEmpty) {
        name = '_';
      }
    }
    return name;
  }

  List<String> _chapterFolderCandidates(String chapterId) {
    final chapterTitle = comic?.chapters?.allChapters[chapterId] ?? chapterId;
    int maxLength = 80;
    if (App.isWindows && path != null) {
      // Keep chapter directory short enough for nested image files on Win32.
      final budget = 220 - path!.length;
      if (budget < 16) {
        maxLength = 16;
      } else if (budget < maxLength) {
        maxLength = budget;
      }
    }
    if (maxLength < 12) {
      maxLength = 12;
    }

    final hash = _shortHash(chapterId);
    final base = _normalizeChapterFolderName(chapterTitle, maxLength);
    final alt = _normalizeChapterFolderName(chapterTitle, maxLength - 10);
    final candidates = <String>[base, '${alt}_$hash', 'cp_$hash'];
    final dedup = <String>[];
    for (final c in candidates) {
      if (c.isNotEmpty && !dedup.contains(c)) {
        dedup.add(c);
      }
    }
    return dedup;
  }

  String _chapterFolderName(String chapterId) {
    final override = _chapterDirNameOverrides[chapterId];
    if (override != null) {
      return override;
    }
    final candidates = _chapterFolderCandidates(chapterId);
    for (final candidate in candidates) {
      final dir = Directory(FilePath.join(path!, candidate));
      if (dir.existsSync()) {
        _chapterDirNameOverrides[chapterId] = candidate;
        return candidate;
      }
    }
    _chapterDirNameOverrides[chapterId] = candidates.first;
    return candidates.first;
  }

  Directory _chapterSaveDir(String chapterId) {
    if (comic?.chapters != null) {
      return Directory(FilePath.join(path!, _chapterFolderName(chapterId)));
    }
    return Directory(path!);
  }

  Directory? _tryCreateChapterDirAtCurrentPath(String chapterId) {
    if (path == null) {
      return null;
    }
    if (comic?.chapters == null) {
      final root = Directory(path!);
      try {
        if (!root.existsSync()) {
          root.createSync(recursive: true);
        }
        return root;
      } catch (_) {
        return null;
      }
    }

    final ordered = <String>[];
    final current = _chapterDirNameOverrides[chapterId];
    if (current != null) {
      ordered.add(current);
    }
    ordered.addAll(_chapterFolderCandidates(chapterId));

    final seen = <String>{};
    for (final candidate in ordered) {
      if (candidate.isEmpty || !seen.add(candidate)) {
        continue;
      }
      final dir = Directory(FilePath.join(path!, candidate));
      try {
        if (!dir.existsSync()) {
          dir.createSync(recursive: true);
        }
        _chapterDirNameOverrides[chapterId] = candidate;
        return dir;
      } catch (_) {}
    }
    return null;
  }

  Directory? _ensureChapterSaveDir(String chapterId) {
    final firstTry = _tryCreateChapterDirAtCurrentPath(chapterId);
    if (firstTry != null) {
      return firstTry;
    }

    final oldPath = path;
    if (oldPath != null) {
      final normalized = _normalizeWindowsPath(oldPath);
      if (normalized != oldPath) {
        path = normalized;
        _chapterDirNameOverrides.clear();
        final secondTry = _tryCreateChapterDirAtCurrentPath(chapterId);
        if (secondTry != null) {
          return secondTry;
        }
      }
    }

    if (comic != null) {
      try {
        final localRoot = LocalManager().path;
        final safeTitle = sanitizeFileName(comic!.title, maxLength: 40);
        final hash = _shortHash('${comicId}_${source.key}');
        final fallbackNames = <String>[
          '${safeTitle}_$hash',
          'comic_$hash',
          'comic_$comicId',
        ];
        for (final name in fallbackNames) {
          final root = Directory(FilePath.join(localRoot, name));
          try {
            if (!root.existsSync()) {
              root.createSync(recursive: true);
            }
            path = root.path;
            _chapterDirNameOverrides.clear();
            final tryWithFallbackPath = _tryCreateChapterDirAtCurrentPath(
              chapterId,
            );
            if (tryWithFallbackPath != null) {
              return tryWithFallbackPath;
            }
          } catch (_) {}
        }
      } catch (_) {}
    }

    final target = _chapterSaveDir(chapterId).path;
    final errorMessage = 'Failed to create chapter directory: $target';
    Log.error("Download", errorMessage);
    _setError(errorMessage);
    return null;
  }

  bool _isImageAlreadyDownloaded(Directory dir, int index) {
    final chapterKey = dir.path;
    var indexes = _existingImageIndexesByChapter[chapterKey];
    if (indexes == null) {
      indexes = <int>{};
      try {
        if (dir.existsSync()) {
          for (final entity in dir.listSync()) {
            if (entity is! File) continue;
            final name = entity.name;
            final dot = name.indexOf('.');
            if (dot <= 0) continue;
            final idx = int.tryParse(name.substring(0, dot));
            if (idx != null) {
              indexes.add(idx);
            }
          }
        }
      } catch (e, s) {
        Log.error(
          "Download",
          "Failed to scan chapter directory: ${dir.path}, $e",
          s,
        );
      }
      _existingImageIndexesByChapter[chapterKey] = indexes;
    }
    return indexes.contains(index);
  }

  int _chapterPriority(String title) {
    final t = title.toLowerCase();
    bool has(List<String> keys) => keys.any((k) => t.contains(k));
    final uncensored = has([
      '无码',
      '無碼',
      '无修正',
      '無修正',
      '无修',
      '無修',
      'uncensored',
    ]);
    final translated = has([
      '汉化',
      '漢化',
      '熟肉',
      '中文',
      '中字',
      'translated',
      'translation',
    ]);
    final raw = has(['raw', '生肉']);
    int score = 0;
    if (uncensored) score += 100;
    if (translated) score += 50;
    if (raw) score -= 20;
    return score;
  }

  String? _extractEpisodeKey(String input) {
    final text = input.toLowerCase();
    final patterns = <RegExp>[
      RegExp(r'第\s*([0-9]+)\s*(?:话|話|章|卷|回|篇)'),
      RegExp(r'(?:chapter|ch|ep|episode)\s*([0-9]+)'),
    ];
    for (final p in patterns) {
      final m = p.firstMatch(text);
      if (m != null) {
        final n = m.group(1);
        if (n != null && n.isNotEmpty) {
          return n;
        }
      }
    }
    return null;
  }

  List<String> _deduplicatePreferredChapters(List<String> chapterIds) {
    final chapterMap = comic?.chapters?.allChapters;
    if (chapterMap == null || chapterIds.length <= 1) {
      return chapterIds;
    }
    final best = <String, String>{};
    final bestScore = <String, int>{};
    final bestIndex = <String, int>{};

    for (int i = 0; i < chapterIds.length; i++) {
      final id = chapterIds[i];
      final title = chapterMap[id] ?? id;
      // Only deduplicate when we can confidently identify the same episode.
      // If episode key cannot be extracted, keep chapter as-is to avoid over-dedup.
      final episodeKey = _extractEpisodeKey(title) ?? _extractEpisodeKey(id);
      if (episodeKey == null) {
        final uniqueKey = 'unique::$id';
        best[uniqueKey] = id;
        bestScore[uniqueKey] = _chapterPriority(title);
        bestIndex[uniqueKey] = i;
        continue;
      }

      final key = 'ep::$episodeKey';
      final score = _chapterPriority(title);
      if (!best.containsKey(key) ||
          score > bestScore[key]! ||
          (score == bestScore[key]! && i < bestIndex[key]!)) {
        best[key] = id;
        bestScore[key] = score;
        bestIndex[key] = i;
      }
    }

    final kept = best.values.toSet();
    return chapterIds.where((id) => kept.contains(id)).toList();
  }

  bool _isRawChapterTitle(String title) {
    final lower = title.toLowerCase();
    return lower.contains('raw') || title.contains('生肉');
  }

  List<String> _applyChapterDownloadFilters(List<String> chapterIds) {
    if (!skipRawChapters) {
      return chapterIds;
    }
    final chapterMap = comic?.chapters?.allChapters;
    if (chapterMap == null) {
      return chapterIds;
    }
    return chapterIds.where((id) {
      final title = chapterMap[id] ?? id;
      return !_isRawChapterTitle(title);
    }).toList();
  }

  void _scheduleTasks() {
    if (!_isRunning) {
      return;
    }
    final chapterId = _images!.keys.elementAt(_chapter);
    var images = _images![chapterId]!;
    var downloading = 0;
    for (var i = _index; i < images.length; i++) {
      if (downloading >= _maxConcurrentTasks) {
        return;
      }

      final saveTo = _ensureChapterSaveDir(chapterId);
      if (saveTo == null) {
        return;
      }
      if (_isImageAlreadyDownloaded(saveTo, i)) {
        _onImageCompleted(chapterId, i);
        continue;
      }

      if (tasks[i] != null) {
        if (!tasks[i]!.isComplete) {
          downloading++;
        }
        if (tasks[i]!.error == null) {
          continue;
        }
      }
      var task = _ImageDownloadWrapper(this, chapterId, images[i], saveTo, i);
      tasks[i] = task;
      task.wait().then((task) {
        if (task.isComplete) {
          _scheduleTasks();
        }
      });
      downloading++;
    }
  }

  String _makeImageKey(String chapterId, int index) => '$chapterId::$index';

  void _syncCompletedKeysFromCursor() {
    if (_images == null) return;
    _completedImageKeys.clear();
    final chapterKeys = _images!.keys.toList();
    for (int c = 0; c < chapterKeys.length; c++) {
      final chapterId = chapterKeys[c];
      final len = _images![chapterId]!.length;
      final end = c < _chapter ? len : (c == _chapter ? _index : 0);
      for (int i = 0; i < end; i++) {
        _completedImageKeys.add(_makeImageKey(chapterId, i));
      }
    }
    _downloadedCount = _completedImageKeys.length;
  }

  void _onImageCompleted(String chapterId, int index) {
    final key = _makeImageKey(chapterId, index);
    if (_completedImageKeys.contains(key)) {
      return;
    }
    _completedImageKeys.add(key);
    _downloadedCount = _completedImageKeys.length;
    if (_downloadedCount > _totalCount) {
      _downloadedCount = _totalCount;
    }
    _message = "$_downloadedCount/$_totalCount";
    notifyListeners();

    if (path != null) {
      final chapterDir = _chapterSaveDir(chapterId).path;
      (_existingImageIndexesByChapter[chapterDir] ??= <int>{}).add(index);
    }
  }

  Future<void> _persistTaskStateThrottled() async {
    final now = DateTime.now();
    final delta = _downloadedCount - _lastPersistDownloadedCount;
    final shouldPersist =
        delta >= 20 ||
        now.difference(_lastPersistTime) >= const Duration(seconds: 2);
    if (!shouldPersist) {
      return;
    }
    // Defer persistence until real download progress starts to avoid
    // resume-phase IO storms when many tasks start in parallel.
    _lastPersistDownloadedCount = _downloadedCount;
    _lastPersistTime = now;
  }

  @override
  void resume() async {
    if (_isRunning) return;
    _isError = false;
    _message = "Resuming...";
    _isRunning = true;
    notifyListeners();
    runRecorder();

    if (comic == null) {
      _message = "Fetching comic info...";
      notifyListeners();
      var res = await _runWithRetry(() async {
        var r = await source.loadComicInfo!(comicId);
        if (r.error) {
          throw r.errorMessage!;
        } else {
          return r.data;
        }
      });
      if (!_isRunning) {
        return;
      }
      if (res.error) {
        _setError("Error: ${res.errorMessage}");
        return;
      } else {
        comic = res.data;
      }
    }

    if (path == null) {
      try {
        var dir = await LocalManager().findValidDirectory(
          comicId,
          comicType,
          comic!.title,
        );
        if (!(await dir.exists())) {
          await dir.create();
        }
        path = dir.path;
      } catch (e, s) {
        Log.error("Download", e.toString(), s);
        _setError("Error: $e");
        return;
      }
    } else {
      try {
        final dir = Directory(path!);
        if (!(await dir.exists())) {
          await dir.create(recursive: true);
        }
      } catch (e, s) {
        Log.error("Download", "Invalid existing task path: $path, $e", s);
        try {
          final dir = await LocalManager().findValidDirectory(
            comicId,
            comicType,
            comic!.title,
          );
          if (!(await dir.exists())) {
            await dir.create(recursive: true);
          }
          path = dir.path;
        } catch (e2, s2) {
          Log.error("Download", "Failed to recover task path: $e2", s2);
          _setError("Error: $e2");
          return;
        }
      }
    }

    // Skip persistence during resume phase to avoid UI freezes on large queues.

    if (_cover == null) {
      _message = "Downloading cover...";
      notifyListeners();
      var res = await _runWithRetry(() async {
        Uint8List? data;
        await for (var progress in ImageDownloader.loadThumbnail(
          comic!.cover,
          source.key,
        )) {
          if (progress.imageBytes != null) {
            data = progress.imageBytes;
          }
        }
        if (data == null) {
          throw "Failed to download cover";
        }
        var fileType = detectFileType(data);
        var file = File(FilePath.join(path!, "cover${fileType.ext}"));
        file.writeAsBytesSync(data);
        return "file://${file.path}";
      });
      if (res.error) {
        // Cover URL may expire or be unavailable (eg. 404).
        // Do not fail the whole comic download because of cover only.
        Log.error(
          "Download",
          "Cover download failed, continue without local cover: ${res.errorMessage}",
        );
        _cover = comic?.cover;
      } else {
        _cover = res.data;
        notifyListeners();
      }
      // Defer persistence until progress updates.
    }

    if (_images == null) {
      if (comic!.chapters == null) {
        _message = "Fetching image list...";
        notifyListeners();
        var res = await _runWithRetry(() async {
          var r = await source.loadComicPages!(comicId, null);
          if (r.error) {
            throw r.errorMessage!;
          } else {
            return r.data;
          }
        });
        if (!_isRunning) {
          return;
        }
        if (res.error) {
          Log.error("Download", res.errorMessage!);
          _setError("Error: ${res.errorMessage}");
          return;
        } else {
          _images = {'': res.data};
          _totalCount = _images!['']!.length;
        }
      } else {
        _images = {};
        _totalCount = 0;
        int cpCount = 0;
        var chapterIds = _deduplicatePreferredChapters(
          chapters?.toList() ?? comic!.chapters!.allChapters.keys.toList(),
        );
        chapterIds = _applyChapterDownloadFilters(chapterIds);
        if (chapterIds.isEmpty) {
          _setError("No chapters matched download options");
          return;
        }
        int totalCpCount = chapterIds.length;
        for (var i in chapterIds) {
          if (_images![i] != null) {
            _totalCount += _images![i]!.length;
            cpCount++;
            continue;
          }
          _message = "Fetching image list ($cpCount/$totalCpCount)...";
          notifyListeners();
          var res = await _runWithRetry(() async {
            var r = await source.loadComicPages!(comicId, i);
            if (r.error) {
              throw r.errorMessage!;
            } else {
              return r.data;
            }
          });
          if (!_isRunning) {
            return;
          }
          if (res.error) {
            Log.error("Download", res.errorMessage!);
            _setError("Error: ${res.errorMessage}");
            return;
          } else {
            _images![i] = res.data;
            _totalCount += _images![i]!.length;
            cpCount++;
          }
        }
      }
      _message = "$_downloadedCount/$_totalCount";
      _syncCompletedKeysFromCursor();
      _existingImageIndexesByChapter.clear();
      final shouldReset = await LocalManager().prepareDirectoryForDownload(
        path!,
        comic!,
        comic!.chapters == null ? const [] : _images!.keys.toList(),
        _totalCount,
      );
      if (shouldReset) {
        _completedImageKeys.clear();
        _existingImageIndexesByChapter.clear();
        _downloadedCount = 0;
        _index = 0;
        _chapter = 0;
        _message = "0/$_totalCount";
      }
      _message = "$_downloadedCount/$_totalCount";
      notifyListeners();
      // Defer persistence until progress updates.
    }

    while (_chapter < _images!.length) {
      final chapterId = _images!.keys.elementAt(_chapter);
      final chapterSaveDir = _chapterSaveDir(chapterId);
      var images = _images![chapterId]!;
      tasks.clear();
      while (_index < images.length) {
        if (!_isRunning) {
          return;
        }
        if (_isImageAlreadyDownloaded(chapterSaveDir, _index)) {
          _onImageCompleted(chapterId, _index);
          _index++;
          await _persistTaskStateThrottled();
          continue;
        }

        _scheduleTasks();
        var task = tasks[_index];
        if (task == null) {
          // Task may be removed by cancellation/pause race.
          if (!_isRunning) {
            return;
          }
          await Future.delayed(const Duration(milliseconds: 30));
          continue;
        }
        await task.wait();
        if (isPaused) {
          return;
        }
        if (task.error != null) {
          Log.error("Download", task.error.toString());
          _setError("Error: ${task.error}");
          return;
        }
        _index++;
        await _persistTaskStateThrottled();
      }

      // Skip chapter-level persistence during active downloading.
      _lastPersistDownloadedCount = _downloadedCount;
      _lastPersistTime = DateTime.now();
      _index = 0;
      _chapter++;
    }

    LocalManager().completeTask(this);
    stopRecorder();
  }

  @override
  void onNextSecond(Timer t) {
    notifyListeners();
    super.onNextSecond(t);
  }

  void _setError(String message) {
    _isRunning = false;
    _isError = true;
    _message = message;
    notifyListeners();
    stopRecorder();
  }

  @override
  int get speed => currentSpeed;

  @override
  String get title => comic?.title ?? comicTitle ?? "Loading...";

  @override
  Map<String, dynamic> toJson() {
    // Heuristic: avoid serializing extremely large image lists to prevent
    // huge JSON files that may crash when exporting task state.
    // If total image count exceeds threshold, redact the heavy field.
    final base = <String, dynamic>{
      "type": "ImagesDownloadTask",
      "source": source.key,
      "comicId": comicId,
      "comic": comic?.toJson(),
      "chapters": chapters,
      "skipRawChapters": skipRawChapters,
      "path": path,
      "cover": _cover,
      "downloadedCount": _downloadedCount,
      "totalCount": _totalCount,
      "index": _index,
      "chapter": _chapter,
    };

    // Compute total image count only if we have data
    int totalImages = 0;
    if (_images != null) {
      for (var list in _images!.values) {
        totalImages += list.length;
      }
    }

    const redactThreshold = 2000; // tune as needed for performance
    if (_images != null && totalImages > redactThreshold) {
      // Drop heavy payload to keep the JSON small
      base.remove("images");
      base["imagesRedacted"] = true;
    } else {
      // Keep images when small enough
      base["images"] = _images;
    }

    return base;
  }

  static ImagesDownloadTask? fromJson(Map<String, dynamic> json) {
    if (json["type"] != "ImagesDownloadTask") {
      return null;
    }

    Map<String, List<String>>? images;
    if (json["images"] != null) {
      images = {};
      for (var entry in json["images"].entries) {
        images[entry.key] = List<String>.from(entry.value);
      }
    }

    return ImagesDownloadTask(
        source: ComicSource.find(json["source"])!,
        comicId: json["comicId"],
        comic: json["comic"] == null
            ? null
            : ComicDetails.fromJson(json["comic"]),
        chapters: ListOrNull.from(json["chapters"]),
        skipRawChapters: json["skipRawChapters"] != false,
      )
      ..path = json["path"]
      .._cover = json["cover"]
      .._images = images
      .._downloadedCount = json["downloadedCount"]
      .._totalCount = json["totalCount"]
      .._index = json["index"]
      .._chapter = json["chapter"];
  }

  @override
  bool get isError => _isError;

  @override
  bool get isPaused => !_isRunning;

  @override
  LocalComic toLocalComic() {
    return LocalComic(
      id: comic!.id,
      title: title,
      subtitle: comic!.subTitle ?? '',
      tags: comic!.tags.entries.expand((e) {
        return e.value.map((v) => "${e.key}:$v");
      }).toList(),
      directory: Directory(path!).name,
      chapters: comic!.chapters,
      cover: File(_cover!.split("file://").last).name,
      comicType: ComicType(source.key.hashCode),
      downloadedChapters: comic!.chapters == null
          ? []
          : (_images?.keys.toList() ?? chapters ?? []),
      createdAt: DateTime.now(),
    );
  }

  @override
  bool operator ==(Object other) {
    if (other is ImagesDownloadTask) {
      return other.comicId == comicId && other.source.key == source.key;
    }
    return false;
  }

  @override
  int get hashCode => Object.hash(comicId, source.key);
}

Future<Res<T>> _runWithRetry<T>(
  Future<T> Function() task, {
  int retry = 3,
}) async {
  for (var i = 0; i < retry; i++) {
    try {
      return Res(await task());
    } catch (e) {
      if (i == retry - 1) {
        return Res.error(e.toString());
      }
      await Future.delayed(Duration(seconds: i + 1));
    }
  }
  throw UnimplementedError();
}

class _ImageDownloadWrapper {
  final ImagesDownloadTask task;

  final String chapter;

  final int index;

  final String image;

  final Directory saveTo;

  _ImageDownloadWrapper(
    this.task,
    this.chapter,
    this.image,
    this.saveTo,
    this.index,
  ) {
    start();
  }

  bool isComplete = false;

  bool _counted = false;

  String? error;

  bool isCancelled = false;

  void cancel() {
    isCancelled = true;
  }

  var completers = <Completer<_ImageDownloadWrapper>>[];

  var retry = 3;

  void start() async {
    int lastBytes = 0;
    try {
      await for (var p in ImageDownloader.loadComicImageUnwrapped(
        image,
        task.source.key,
        task.comicId,
        chapter,
      )) {
        if (isCancelled) {
          return;
        }
        task.onData(p.currentBytes - lastBytes);
        lastBytes = p.currentBytes;
        if (p.imageBytes != null) {
          var fileType = detectFileType(p.imageBytes!);
          var file = saveTo.joinFile("$index${fileType.ext}");
          try {
            if (!saveTo.existsSync()) {
              saveTo.createSync(recursive: true);
            }
            await file.writeAsBytes(p.imageBytes!);
          } on FileSystemException {
            // Directory may disappear due to external changes/races.
            // Recreate and retry once.
            if (!saveTo.existsSync()) {
              saveTo.createSync(recursive: true);
            }
            await file.writeAsBytes(p.imageBytes!);
          }
          isComplete = true;
          if (!_counted) {
            _counted = true;
            task._onImageCompleted(chapter, index);
          }
          for (var c in completers) {
            c.complete(this);
          }
          completers.clear();
        }
      }
    } catch (e, s) {
      if (isCancelled) {
        return;
      }
      Log.error("Download", e.toString(), s);
      retry--;
      if (retry > 0) {
        start();
        return;
      }
      error = e.toString();
      for (var c in completers) {
        if (!c.isCompleted) {
          c.complete(this);
        }
      }
    }
  }

  Future<_ImageDownloadWrapper> wait() {
    if (isComplete) {
      return Future.value(this);
    }
    var c = Completer<_ImageDownloadWrapper>();
    completers.add(c);
    return c.future;
  }
}

abstract mixin class _TransferSpeedMixin {
  int _bytesSinceLastSecond = 0;

  int _currentSpeed = 0;

  int get currentSpeed => _currentSpeed;

  Timer? timer;

  void onData(int length) {
    if (timer == null) return;
    if (length < 0) {
      return;
    }
    _bytesSinceLastSecond += length;
  }

  void onNextSecond(Timer t) {
    _currentSpeed = _bytesSinceLastSecond;
    _bytesSinceLastSecond = 0;
  }

  void runRecorder() {
    if (timer != null) {
      timer!.cancel();
    }
    _bytesSinceLastSecond = 0;
    timer = Timer.periodic(const Duration(seconds: 1), onNextSecond);
  }

  void stopRecorder() {
    timer?.cancel();
    timer = null;
    _currentSpeed = 0;
    _bytesSinceLastSecond = 0;
  }
}

class ArchiveDownloadTask extends DownloadTask {
  final String archiveUrl;

  final ComicDetails comic;

  late ComicSource source;

  /// Download comic by archive url
  ///
  /// Currently only support zip file and comics without chapters
  ArchiveDownloadTask(this.archiveUrl, this.comic) {
    source = ComicSource.find(comic.sourceKey)!;
  }

  FileDownloader? _downloader;

  String _message = "Fetching comic info...";

  bool _isRunning = false;

  bool _isError = false;

  void _setError(String message) {
    _isRunning = false;
    _isError = true;
    _message = message;
    notifyListeners();
    Log.error("Download", message);
  }

  @override
  void cancel() async {
    _isRunning = false;
    await _downloader?.stop();
    if (path != null) {
      Directory(path!).deleteIgnoreError(recursive: true);
    }
    path = null;
    LocalManager().removeTask(this);
  }

  @override
  ComicType get comicType => ComicType(source.key.hashCode);

  @override
  String? get cover => comic.cover;

  @override
  String get id => comic.id;

  @override
  String? get sourceKey => source.key;

  @override
  bool get isError => _isError;

  @override
  bool get isPaused => !_isRunning;

  @override
  String get message => _message;

  int _currentBytes = 0;

  int _expectedBytes = 0;

  int _speed = 0;

  @override
  bool shouldAutoRetryOnError() {
    final m = _message.toLowerCase();
    if (m.contains('under review') ||
        m.contains('format of accept header is invalid') ||
        m.contains('invalid status code: 400') ||
        m.contains('invalid status code: 404') ||
        m.contains('status code of 400') ||
        m.contains('status code of 404')) {
      return false;
    }
    return true;
  }

  @override
  void pause() {
    _isRunning = false;
    _message = "Paused";
    _downloader?.stop();
    notifyListeners();
  }

  @override
  double get progress =>
      _expectedBytes == 0 ? 0 : _currentBytes / _expectedBytes;

  @override
  void resume() async {
    if (_isRunning) {
      return;
    }
    _isError = false;
    _isRunning = true;
    notifyListeners();
    _message = "Downloading...";

    if (path == null) {
      var dir = await LocalManager().findValidDirectory(
        comic.id,
        comicType,
        comic.title,
      );
      if (!(await dir.exists())) {
        try {
          await dir.create();
        } catch (e) {
          _setError("Error: $e");
          return;
        }
      }
      path = dir.path;
    }

    var archiveFile = File(
      FilePath.join(App.dataPath, "archive_downloading.zip"),
    );

    Log.info("Download", "Downloading $archiveUrl");

    _downloader = FileDownloader(archiveUrl, archiveFile.path);

    bool isDownloaded = false;

    try {
      await for (var status in _downloader!.start()) {
        _currentBytes = status.downloadedBytes;
        _expectedBytes = status.totalBytes;
        _message =
            "${bytesToReadableString(_currentBytes)}/${bytesToReadableString(_expectedBytes)}";
        _speed = status.bytesPerSecond;
        isDownloaded = status.isFinished;
        notifyListeners();
      }
    } catch (e) {
      _setError("Error: $e");
      return;
    }

    if (!_isRunning) {
      return;
    }

    if (!isDownloaded) {
      _setError("Error: Download failed");
      return;
    }

    try {
      await _extractArchive(archiveFile.path, path!);
    } catch (e) {
      _setError("Failed to extract archive: $e");
      return;
    }

    await archiveFile.deleteIgnoreError();

    LocalManager().completeTask(this);
  }

  static Future<void> _extractArchive(String archive, String outDir) async {
    var out = Directory(outDir);
    if (out is AndroidDirectory) {
      // Saf directory can't be accessed by native code.
      var cacheDir = FilePath.join(App.cachePath, "archive_downloading");
      Directory(cacheDir).forceCreateSync();
      await Isolate.run(() {
        ZipFile.openAndExtract(archive, cacheDir);
      });
      await copyDirectoryIsolate(Directory(cacheDir), Directory(outDir));
      await Directory(cacheDir).deleteIgnoreError(recursive: true);
    } else {
      await Isolate.run(() {
        ZipFile.openAndExtract(archive, outDir);
      });
    }
  }

  @override
  int get speed => _speed;

  @override
  String get title => comic.title;

  @override
  Map<String, dynamic> toJson() {
    return {
      "type": "ArchiveDownloadTask",
      "archiveUrl": archiveUrl,
      "comic": comic.toJson(),
      "path": path,
    };
  }

  static ArchiveDownloadTask? fromJson(Map<String, dynamic> json) {
    if (json["type"] != "ArchiveDownloadTask") {
      return null;
    }
    return ArchiveDownloadTask(
      json["archiveUrl"],
      ComicDetails.fromJson(json["comic"]),
    )..path = json["path"];
  }

  String _findCover() {
    var files = Directory(path!).listSync();
    for (var f in files) {
      if (f.name.startsWith('cover')) {
        return f.name;
      }
    }
    files.sort((a, b) {
      return a.name.compareTo(b.name);
    });
    return files.first.name;
  }

  @override
  LocalComic toLocalComic() {
    return LocalComic(
      id: comic.id,
      title: title,
      subtitle: comic.subTitle ?? '',
      tags: comic.tags.entries.expand((e) {
        return e.value.map((v) => "${e.key}:$v");
      }).toList(),
      directory: Directory(path!).name,
      chapters: null,
      cover: _findCover(),
      comicType: ComicType(source.key.hashCode),
      downloadedChapters: [],
      createdAt: DateTime.now(),
    );
  }
}
