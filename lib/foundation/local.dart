import 'dart:convert';
import 'dart:async';
import 'dart:math';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart' show ChangeNotifier;
import 'package:flutter_saf/flutter_saf.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/download.dart';
import 'package:venera/network/images.dart';
import 'package:venera/pages/reader/reader.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/file_type.dart';
import 'package:venera/utils/translations.dart';

import 'app.dart';
import 'history.dart';

class LocalComic with HistoryMixin implements Comic {
  @override
  final String id;

  @override
  final String title;

  @override
  final String subtitle;

  @override
  final List<String> tags;

  /// The name of the directory where the comic is stored
  final String directory;

  /// key: chapter id, value: chapter title
  ///
  /// chapter id is the name of the directory in `LocalManager.path/$directory`
  final ComicChapters? chapters;

  bool get hasChapters => chapters != null;

  /// relative path to the cover image
  @override
  final String cover;

  final ComicType comicType;

  final List<String> downloadedChapters;

  final DateTime createdAt;

  const LocalComic({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.tags,
    required this.directory,
    required this.chapters,
    required this.cover,
    required this.comicType,
    required this.downloadedChapters,
    required this.createdAt,
  });

  LocalComic.fromRow(Row row)
    : id = row[0] as String,
      title = row[1] as String,
      subtitle = row[2] as String,
      tags = List.from(jsonDecode(row[3] as String)),
      directory = row[4] as String,
      chapters = ComicChapters.fromJsonOrNull(jsonDecode(row[5] as String)),
      cover = row[6] as String,
      comicType = ComicType(row[7] as int),
      downloadedChapters = List.from(jsonDecode(row[8] as String)),
      createdAt = DateTime.fromMillisecondsSinceEpoch(row[9] as int);

  File get coverFile => File(FilePath.join(baseDir, cover));

  String get baseDir => (directory.contains('/') || directory.contains('\\'))
      ? directory
      : FilePath.join(LocalManager().path, directory);

  @override
  String get description => "";

  @override
  String get sourceKey =>
      comicType == ComicType.local ? "local" : comicType.sourceKey;

  @override
  Map<String, dynamic> toJson() {
    return {
      "title": title,
      "cover": cover,
      "id": id,
      "subTitle": subtitle,
      "tags": tags,
      "description": description,
      "sourceKey": sourceKey,
      "chapters": chapters?.toJson(),
    };
  }

  @override
  int? get maxPage => null;

  void read() {
    var history = HistoryManager().find(id, comicType);
    int? firstDownloadedChapter;
    int? firstDownloadedChapterGroup;
    if (downloadedChapters.isNotEmpty && chapters != null) {
      final chapters = this.chapters!;
      if (chapters.isGrouped) {
        for (int i = 0; i < chapters.groupCount; i++) {
          var group = chapters.getGroupByIndex(i);
          var keys = group.keys.toList();
          for (int j = 0; j < keys.length; j++) {
            var chapterId = keys[j];
            if (downloadedChapters.contains(chapterId)) {
              firstDownloadedChapter = j + 1;
              firstDownloadedChapterGroup = i + 1;
              break;
            }
          }
        }
      } else {
        var keys = chapters.allChapters.keys;
        for (int i = 0; i < keys.length; i++) {
          if (downloadedChapters.contains(keys.elementAt(i))) {
            firstDownloadedChapter = i + 1;
            break;
          }
        }
      }
    }
    App.rootContext.to(
      () => Reader(
        type: comicType,
        cid: id,
        name: title,
        chapters: chapters,
        initialChapter: history?.ep ?? firstDownloadedChapter,
        initialPage: history?.page,
        initialChapterGroup: history?.group ?? firstDownloadedChapterGroup,
        history: history ?? History.fromModel(model: this, ep: 0, page: 0),
        author: subtitle,
        tags: tags,
      ),
    );
  }

  @override
  HistoryType get historyType => comicType;

  @override
  String? get subTitle => subtitle;

  @override
  String? get language => null;

  @override
  String? get favoriteId => null;

  @override
  double? get stars => null;
}

class LocalManager with ChangeNotifier {
  static LocalManager? _instance;

  LocalManager._();

  factory LocalManager() {
    return _instance ??= LocalManager._();
  }

  late Database _db;

  /// path to the directory where all the comics are stored
  late String path;

  Directory get directory => Directory(path);

  static const _comicInfoFileName = 'comic_info.json';
  final Map<String, Map<String, dynamic>> _comicInfoItems = {};
  final Set<String> _dirtyComicInfoKeys = {};
  final Set<String> _invalidDownloadedComicKeys = {};
  Timer? _comicInfoFlushTimer;
  bool _comicInfoFlushing = false;
  bool _removeLegacyComicInfoFile = false;
  Future<void>? _startupDownloadValidationTask;
  bool _isBackgroundValidatingDownloads = false;
  DateTime? _lastPruneAt;
  bool _isPruningMissingComics = false;
  Future<void>? _savingDownloadingTasks;
  bool _pendingSaveDownloadingTasks = false;
  bool _pendingSaveDownloadingTasksFull = false;

  String _comicInfoKey(ComicType type, String id) => '${type.value}::$id';

  void _checkNoMedia() {
    if (App.isAndroid) {
      var file = File(FilePath.join(path, '.nomedia'));
      if (!file.existsSync()) {
        file.createSync();
      }
    }
  }

  File get _legacyComicInfoFile =>
      File(FilePath.join(path, _comicInfoFileName));

  File _comicInfoFileForBaseDir(String baseDir) =>
      File(FilePath.join(baseDir, _comicInfoFileName));

  File _comicInfoFileForComic(LocalComic comic) =>
      _comicInfoFileForBaseDir(comic.baseDir);

  File? _comicInfoFileForItem(Map<String, dynamic> item) {
    final directory = item['directory']?.toString();
    if (directory == null || directory.isEmpty) {
      return null;
    }
    final baseDir = (directory.contains('/') || directory.contains('\\'))
        ? directory
        : FilePath.join(path, directory);
    return _comicInfoFileForBaseDir(baseDir);
  }

  Future<Map<String, Map<String, dynamic>>> _loadLegacyComicInfo() async {
    final items = <String, Map<String, dynamic>>{};
    try {
      if (!_legacyComicInfoFile.existsSync()) {
        return items;
      }
      final raw = await _legacyComicInfoFile.readAsString();
      if (raw.trim().isEmpty) {
        return items;
      }
      final json = jsonDecode(raw);
      final payload = (json is Map<String, dynamic>) ? json['items'] : json;
      if (payload is! List) {
        return items;
      }
      for (final item in payload) {
        if (item is! Map<String, dynamic>) {
          continue;
        }
        final sourceKey = item['sourceKey'];
        final comicId = item['comicId'];
        if (sourceKey is! String || comicId is! String) {
          continue;
        }
        final type = ComicType.fromKey(sourceKey);
        items[_comicInfoKey(type, comicId)] = Map<String, dynamic>.from(item);
      }
    } catch (e, s) {
      Log.error('LocalManager', 'Failed to load legacy comic_info.json: $e', s);
    }
    return items;
  }

  Future<Map<String, dynamic>?> _readComicInfoFile(File file) async {
    try {
      if (!file.existsSync()) {
        return null;
      }
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) {
        return null;
      }
      final json = jsonDecode(raw);
      if (json is Map<String, dynamic>) {
        return json;
      }
    } catch (e, s) {
      Log.error('LocalManager', 'Failed to load comic info file: $e', s);
    }
    return null;
  }

  Map<String, dynamic> _normalizeComicInfo(
    LocalComic comic,
    Map<String, dynamic> item,
  ) {
    final actualDownloadedChapters = comic.hasChapters
        ? _inferDownloadedChaptersFromDirectory(comic)
        : comic.downloadedChapters;
    return {
      ...item,
      'sourceKey': comic.comicType.sourceKey,
      'comicId': comic.id,
      'title': item['title'] ?? comic.title,
      'subtitle': item['subtitle'] ?? comic.subtitle,
      'directory': comic.directory,
      'downloadedChapters':
          item['downloadedChapters'] ?? actualDownloadedChapters,
      'chapterCount':
          item['chapterCount'] ??
          (comic.hasChapters ? actualDownloadedChapters.length : 0),
      'pageCount': item['pageCount'] ?? _countComicPagesSync(comic),
      'tags': item['tags'] ?? comic.tags,
      'updatedAt': item['updatedAt'] ?? DateTime.now().toIso8601String(),
    };
  }

  bool _sameStringList(List<String> left, List<String> right) {
    if (left.length != right.length) {
      return false;
    }
    for (int i = 0; i < left.length; i++) {
      if (left[i] != right[i]) {
        return false;
      }
    }
    return true;
  }

  void _syncDownloadedChaptersInDatabaseIfNeeded(
    LocalComic comic,
    List<String> actualDownloadedChapters,
  ) {
    if (!comic.hasChapters ||
        _sameStringList(comic.downloadedChapters, actualDownloadedChapters)) {
      return;
    }
    _db.execute(
      'UPDATE comics SET downloadedChapters = ? WHERE id = ? AND comic_type = ?;',
      [jsonEncode(actualDownloadedChapters), comic.id, comic.comicType.value],
    );
  }

  Future<void> _loadComicInfo() async {
    _comicInfoItems.clear();
    _dirtyComicInfoKeys.clear();
    final legacyItems = await _loadLegacyComicInfo();
    bool shouldMigrateLegacy = false;

    for (final comic in getComics(LocalSortType.timeDesc)) {
      final key = _comicInfoKey(comic.comicType, comic.id);
      final file = _comicInfoFileForComic(comic);
      final item = await _readComicInfoFile(file) ?? legacyItems[key];
      if (item == null) {
        continue;
      }
      final normalized = _normalizeComicInfo(comic, item);
      _comicInfoItems[key] = normalized;
      final actualDownloadedChapters =
          (normalized['downloadedChapters'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          comic.downloadedChapters;
      _syncDownloadedChaptersInDatabaseIfNeeded(
        comic,
        actualDownloadedChapters,
      );
      if (!file.existsSync()) {
        _dirtyComicInfoKeys.add(key);
        shouldMigrateLegacy = true;
      } else if (item['downloadedChapters'] == null) {
        _dirtyComicInfoKeys.add(key);
      }
    }

    for (final dir in _listLocalComicDirectories()) {
      final file = _comicInfoFileForBaseDir(dir.path);
      final item = await _readComicInfoFile(file);
      if (item == null) {
        continue;
      }
      final sourceKey = item['sourceKey']?.toString();
      final comicId = item['comicId']?.toString();
      if (sourceKey == null || sourceKey.isEmpty || comicId == null) {
        continue;
      }
      final key = _comicInfoKey(ComicType.fromKey(sourceKey), comicId);
      final old = _comicInfoItems[key];
      _comicInfoItems[key] = {
        ...?old,
        ...item,
        'directory': item['directory'] ?? dir.name,
      };
    }

    if (shouldMigrateLegacy && _legacyComicInfoFile.existsSync()) {
      _removeLegacyComicInfoFile = true;
      _scheduleComicInfoFlush();
    }
  }

  void _scheduleComicInfoFlush([Iterable<String>? keys]) {
    if (keys != null) {
      _dirtyComicInfoKeys.addAll(keys);
    }
    _comicInfoFlushTimer?.cancel();
    _comicInfoFlushTimer = Timer(const Duration(milliseconds: 500), () {
      unawaited(_flushComicInfo());
    });
  }

  Future<void> _flushComicInfo() async {
    if (_comicInfoFlushing ||
        (_dirtyComicInfoKeys.isEmpty && !_removeLegacyComicInfoFile)) {
      return;
    }
    _comicInfoFlushing = true;
    final keys = _dirtyComicInfoKeys.toList();
    _dirtyComicInfoKeys.removeAll(keys);
    final shouldDeleteLegacy = _removeLegacyComicInfoFile;
    _removeLegacyComicInfoFile = false;
    try {
      for (final key in keys) {
        final item = _comicInfoItems[key];
        if (item == null) {
          continue;
        }
        final file = _comicInfoFileForItem(item);
        if (file == null) {
          continue;
        }
        try {
          if (!file.parent.existsSync()) {
            file.parent.createSync(recursive: true);
          }
          await file.writeAsString(jsonEncode(item));
        } catch (e, s) {
          _dirtyComicInfoKeys.add(key);
          Log.error('LocalManager', 'Failed to write comic info file: $e', s);
        }
      }
      if (shouldDeleteLegacy) {
        await _legacyComicInfoFile.deleteIgnoreError();
      }
    } finally {
      _comicInfoFlushing = false;
      if (_dirtyComicInfoKeys.isNotEmpty || _removeLegacyComicInfoFile) {
        unawaited(_flushComicInfo());
      }
    }
  }

  bool _isComicPageFile(File file) {
    final lower = file.name.toLowerCase();
    if (lower.startsWith('cover.') || file.name.startsWith('.')) {
      return false;
    }
    return _isSupportedImageExt(file.extension);
  }

  int _countImageFilesInDirectorySync(Directory dir) {
    if (!dir.existsSync()) {
      return 0;
    }
    int count = 0;
    try {
      for (final entity in dir.listSync(followLinks: false)) {
        if (entity is File && _isComicPageFile(entity)) {
          count++;
        }
      }
    } catch (_) {
      return count;
    }
    return count;
  }

  Future<int> _countImageFilesInDirectoryAsync(Directory dir) async {
    if (!dir.existsSync()) {
      return 0;
    }
    int count = 0;
    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is File && _isComicPageFile(entity)) {
          count++;
        }
      }
    } catch (_) {
      return count;
    }
    return count;
  }

  Directory? _chapterDirectoryForComic(LocalComic comic, String chapterId) {
    final base = Directory(comic.baseDir);
    if (!base.existsSync()) {
      return null;
    }
    final chapterTitle = comic.chapters?.allChapters[chapterId] ?? chapterId;
    final titleDir = Directory(
      FilePath.join(comic.baseDir, getChapterDirectoryName(chapterTitle)),
    );
    if (titleDir.existsSync()) {
      return titleDir;
    }
    final idDir = Directory(
      FilePath.join(comic.baseDir, getChapterDirectoryName(chapterId)),
    );
    if (idDir.existsSync()) {
      return idDir;
    }
    return null;
  }

  Future<List<Directory>> _chapterDirectoriesAsync(LocalComic comic) async {
    final base = Directory(comic.baseDir);
    if (!base.existsSync()) {
      return const [];
    }
    final dirs = <Directory>[];
    try {
      await for (final entity in base.list(followLinks: false)) {
        if (entity is Directory && !entity.name.startsWith('.')) {
          dirs.add(entity);
        }
      }
    } catch (_) {
      return const [];
    }
    dirs.sort((a, b) => a.name.compareTo(b.name));
    return dirs;
  }

  int _countComicPagesSync(LocalComic comic) {
    if (comic.hasChapters) {
      final chapterIds = _inferDownloadedChaptersFromDirectory(comic);
      int count = 0;
      for (final chapterId in chapterIds) {
        final chapterDir = _chapterDirectoryForComic(comic, chapterId);
        if (chapterDir == null) {
          continue;
        }
        count += _countImageFilesInDirectorySync(chapterDir);
      }
      return count;
    }
    return _countImageFilesInDirectorySync(Directory(comic.baseDir));
  }

  Future<int> _countComicPagesAsync(LocalComic comic) async {
    if (comic.hasChapters) {
      final chapterIds = _inferDownloadedChaptersFromDirectory(comic);
      int count = 0;
      for (final chapterId in chapterIds) {
        final chapterDir = _chapterDirectoryForComic(comic, chapterId);
        if (chapterDir == null) {
          continue;
        }
        count += await _countImageFilesInDirectoryAsync(chapterDir);
      }
      return count;
    }
    return _countImageFilesInDirectoryAsync(Directory(comic.baseDir));
  }

  Future<int> _countComicChaptersAsync(LocalComic comic) async {
    if (!comic.hasChapters) {
      return 0;
    }
    return _inferDownloadedChaptersFromDirectory(comic).length;
  }

  Future<List<Directory>> _chapterDirectoriesByBaseDir(String baseDir) async {
    final base = Directory(baseDir);
    if (!base.existsSync()) {
      return const [];
    }
    final dirs = <Directory>[];
    try {
      await for (final entity in base.list(followLinks: false)) {
        if (entity is Directory && !entity.name.startsWith('.')) {
          dirs.add(entity);
        }
      }
    } catch (_) {
      return const [];
    }
    dirs.sort((a, b) => a.name.compareTo(b.name));
    return dirs;
  }

  Future<int> _countPagesByBaseDir(
    String baseDir, {
    required bool hasChapters,
  }) async {
    if (!hasChapters) {
      return _countImageFilesInDirectoryAsync(Directory(baseDir));
    }
    int count = 0;
    for (final dir in await _chapterDirectoriesByBaseDir(baseDir)) {
      count += await _countImageFilesInDirectoryAsync(dir);
    }
    return count;
  }

  ({int latestModifiedMs, int totalBytes}) _scanDirectoryScore(Directory dir) {
    int latest = 0;
    int bytes = 0;
    try {
      final stat = dir.statSync();
      latest = stat.modified.millisecondsSinceEpoch;
    } catch (_) {}
    try {
      for (final entity in dir.listSync(recursive: true, followLinks: false)) {
        if (entity is File) {
          try {
            final stat = entity.statSync();
            final m = stat.modified.millisecondsSinceEpoch;
            if (m > latest) latest = m;
            bytes += stat.size;
          } catch (_) {}
        }
      }
    } catch (_) {}
    return (latestModifiedMs: latest, totalBytes: bytes);
  }

  Future<Directory?> _findDirectoryByStoredComicInfo(
    String id,
    ComicType type,
  ) async {
    Directory? bestDir;
    int bestLatest = -1;
    int bestSize = -1;
    for (final dir in _listLocalComicDirectories()) {
      final info = await _readComicInfoFile(_comicInfoFileForBaseDir(dir.path));
      if (info == null) {
        continue;
      }
      if (info['sourceKey']?.toString() != type.sourceKey ||
          info['comicId']?.toString() != id) {
        continue;
      }
      final key = _comicInfoKey(type, id);
      _comicInfoItems[key] = {
        ...?_comicInfoItems[key],
        ...info,
        'directory': info['directory'] ?? dir.name,
      };
      final score = _scanDirectoryScore(dir);
      if (score.latestModifiedMs > bestLatest ||
          (score.latestModifiedMs == bestLatest &&
              score.totalBytes > bestSize)) {
        bestDir = dir;
        bestLatest = score.latestModifiedMs;
        bestSize = score.totalBytes;
      }
    }
    return bestDir;
  }

  Future<bool> prepareDirectoryForDownload(
    String directoryPath,
    ComicDetails comic,
    List<String> chapterIds,
    int pageCount,
  ) async {
    final dir = Directory(directoryPath);
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }

    final info = await _readComicInfoFile(_comicInfoFileForBaseDir(dir.path));
    final expectedChapterCount = comic.chapters == null ? 0 : chapterIds.length;
    final actualChapterCount = comic.chapters == null
        ? 0
        : (await _chapterDirectoriesByBaseDir(dir.path)).length;
    final actualPageCount = await _countPagesByBaseDir(
      dir.path,
      hasChapters: comic.chapters != null,
    );

    bool shouldReset = false;
    if (info != null) {
      if (info['sourceKey']?.toString() != comic.sourceKey ||
          info['comicId']?.toString() != comic.id ||
          !_titlesMatch(
            info['title']?.toString() ?? comic.title,
            comic.title,
          )) {
        shouldReset = true;
      }
    }

    if (!shouldReset) {
      if (expectedChapterCount > 0 &&
          actualChapterCount > expectedChapterCount) {
        shouldReset = true;
      }
      if (pageCount > 0 && actualPageCount > pageCount) {
        shouldReset = true;
      }
    }

    if (shouldReset) {
      try {
        for (final entity in dir.listSync(followLinks: false)) {
          await entity.deleteIgnoreError(recursive: true);
        }
      } catch (_) {}
    }

    cacheDownloadingComicInfo(
      comic,
      dir.path,
      downloadedChapters: chapterIds,
      chapterCount: expectedChapterCount,
      pageCount: pageCount,
    );
    return shouldReset;
  }

  void _upsertComicInfo(LocalComic comic, {String? url}) {
    final key = _comicInfoKey(comic.comicType, comic.id);
    final old = _comicInfoItems[key] ?? <String, dynamic>{};
    final sourceKey = comic.comicType.sourceKey;
    final actualDownloadedChapters = comic.hasChapters
        ? _inferDownloadedChaptersFromDirectory(comic)
        : comic.downloadedChapters;
    _syncDownloadedChaptersInDatabaseIfNeeded(comic, actualDownloadedChapters);
    _comicInfoItems[key] = {
      ...old,
      'sourceKey': sourceKey,
      'comicId': comic.id,
      'title': comic.title,
      'subtitle': comic.subtitle,
      'directory': comic.directory,
      'downloadedChapters': actualDownloadedChapters,
      'chapterCount': actualDownloadedChapters.length,
      'pageCount': _countComicPagesSync(comic),
      'tags': comic.tags,
      'url': url ?? old['url'],
      'updatedAt': DateTime.now().toIso8601String(),
    };
    _invalidDownloadedComicKeys.remove(key);
    _scheduleComicInfoFlush([key]);
  }

  Future<void> _upsertComicInfoAsync(LocalComic comic, {String? url}) async {
    final key = _comicInfoKey(comic.comicType, comic.id);
    final old = _comicInfoItems[key] ?? <String, dynamic>{};
    final sourceKey = comic.comicType.sourceKey;
    final actualDownloadedChapters = comic.hasChapters
        ? _inferDownloadedChaptersFromDirectory(comic)
        : comic.downloadedChapters;
    _syncDownloadedChaptersInDatabaseIfNeeded(comic, actualDownloadedChapters);
    final pageCount = await _countComicPagesAsync(comic);
    _comicInfoItems[key] = {
      ...old,
      'sourceKey': sourceKey,
      'comicId': comic.id,
      'title': comic.title,
      'subtitle': comic.subtitle,
      'directory': comic.directory,
      'downloadedChapters': actualDownloadedChapters,
      'chapterCount': actualDownloadedChapters.length,
      'pageCount': pageCount,
      'tags': comic.tags,
      'url': url ?? old['url'],
      'updatedAt': DateTime.now().toIso8601String(),
    };
    _invalidDownloadedComicKeys.remove(key);
    _scheduleComicInfoFlush([key]);
  }

  List<String> _flattenComicTags(ComicDetails comic) {
    return comic.tags.entries.expand((e) {
      return e.value.map((v) => '${e.key}:$v');
    }).toList();
  }

  void cacheDownloadingComicInfo(
    ComicDetails comic,
    String directoryPath, {
    required List<String> downloadedChapters,
    required int chapterCount,
    required int pageCount,
  }) {
    final dir = Directory(directoryPath);
    final key = _comicInfoKey(comic.comicType, comic.id);
    final old = _comicInfoItems[key] ?? <String, dynamic>{};
    _comicInfoItems[key] = {
      ...old,
      'sourceKey': comic.sourceKey,
      'comicId': comic.id,
      'title': comic.title,
      'subtitle': comic.subTitle ?? '',
      'directory': dir.name,
      'downloadedChapters': downloadedChapters,
      'chapterCount': chapterCount,
      'pageCount': pageCount,
      'tags': _flattenComicTags(comic),
      'url': comic.url ?? old['url'],
      'updatedAt': DateTime.now().toIso8601String(),
    };
    _scheduleComicInfoFlush([key]);
  }

  Future<bool> _isImageBroken(File file) async {
    try {
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) return true;
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      frame.image.dispose();
      codec.dispose();
      return false;
    } catch (_) {
      return true;
    }
  }

  // return error message if failed
  Future<String?> setNewPath(String newPath) async {
    String normalizePath(String p) {
      var normalized = Directory(p).absolute.path.replaceAll('\\', '/');
      while (normalized.endsWith('/')) {
        normalized = normalized.substring(0, normalized.length - 1);
      }
      if (App.isWindows) {
        normalized = normalized.toLowerCase();
      }
      return normalized;
    }

    bool isInside(String child, String parent) {
      var c = normalizePath(child);
      var p = normalizePath(parent);
      return c == p || c.startsWith('$p/');
    }

    var sourcePath = normalizePath(path);
    var targetDir = Directory(newPath);
    if (!await targetDir.exists()) {
      return "Directory does not exist";
    }
    var targetPath = normalizePath(targetDir.path);
    if (targetPath == sourcePath) {
      return null;
    }
    if (isInside(targetPath, sourcePath)) {
      return "Target directory cannot be inside current storage path";
    }

    final comics = getComics(LocalSortType.name);

    try {
      for (final comic in comics) {
        final sourceComicDir = Directory(FilePath.join(path, comic.directory));
        if (!sourceComicDir.existsSync()) {
          continue;
        }
        final targetComicDir = Directory(
          FilePath.join(targetDir.path, comic.directory),
        );
        if (targetComicDir.existsSync() &&
            targetComicDir.listSync().isNotEmpty) {
          return 'Target has existing folder: ${comic.directory}';
        }
      }
    } catch (e) {
      return e.toString();
    }

    try {
      for (final comic in comics) {
        final sourceComicDir = Directory(FilePath.join(path, comic.directory));
        if (!sourceComicDir.existsSync()) {
          continue;
        }
        final targetComicDir = Directory(
          FilePath.join(targetDir.path, comic.directory),
        );
        targetComicDir.createSync(recursive: true);
        await copyDirectoryIsolate(sourceComicDir, targetComicDir);
      }

      final sourceInfo = File(FilePath.join(path, _comicInfoFileName));
      if (sourceInfo.existsSync()) {
        await sourceInfo.copy(
          FilePath.join(targetDir.path, _comicInfoFileName),
        );
      }

      await File(
        FilePath.join(App.dataPath, 'local_path'),
      ).writeAsString(newPath);
    } catch (e, s) {
      Log.error("IO", e, s);
      return e.toString();
    }

    for (final comic in comics) {
      final sourceComicDir = Directory(FilePath.join(path, comic.directory));
      await sourceComicDir.deleteIgnoreError(recursive: true);
    }
    await File(FilePath.join(path, _comicInfoFileName)).deleteIgnoreError();

    path = newPath;
    _checkNoMedia();
    await _loadComicInfo();
    return null;
  }

  Future<String> findDefaultPath() async {
    if (App.isAndroid) {
      var external = await getExternalStorageDirectories();
      if (external != null && external.isNotEmpty) {
        return FilePath.join(external.first.path, 'local');
      } else {
        return FilePath.join(App.dataPath, 'local');
      }
    } else if (App.isIOS) {
      var oldPath = FilePath.join(App.dataPath, 'local');
      if (Directory(oldPath).existsSync() &&
          Directory(oldPath).listSync().isNotEmpty) {
        return oldPath;
      } else {
        var directory = await getApplicationDocumentsDirectory();
        return FilePath.join(directory.path, 'local');
      }
    } else {
      return FilePath.join(App.dataPath, 'local');
    }
  }

  Future<void> _checkPathValidation() async {
    var testFile = File(FilePath.join(path, 'venera_test'));
    try {
      testFile.createSync();
      testFile.deleteSync();
    } catch (e) {
      Log.error(
        "IO",
        "Failed to create test file in local path: $e\nUsing default path instead.",
      );
      path = await findDefaultPath();
    }
  }

  Future<void> init() async {
    _db = sqlite3.open('${App.dataPath}/local.db');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS comics (
        id TEXT NOT NULL,
        title TEXT NOT NULL,
        subtitle TEXT NOT NULL,
        tags TEXT NOT NULL,
        directory TEXT NOT NULL,
        chapters TEXT NOT NULL,
        cover TEXT NOT NULL,
        comic_type INTEGER NOT NULL,
        downloadedChapters TEXT NOT NULL,
        created_at INTEGER,
        PRIMARY KEY (id, comic_type)
      );
    ''');
    if (File(FilePath.join(App.dataPath, 'local_path')).existsSync()) {
      path = File(FilePath.join(App.dataPath, 'local_path')).readAsStringSync();
      if (!directory.existsSync()) {
        path = await findDefaultPath();
      }
    } else {
      path = await findDefaultPath();
    }
    try {
      if (!directory.existsSync()) {
        await directory.create();
      }
    } catch (e, s) {
      Log.error("IO", "Failed to create local folder: $e", s);
    }
    _checkPathValidation();
    _checkNoMedia();
    await _loadComicInfo();
    await ComicSourceManager().ensureInit();
    restoreDownloadingTasks();
    scheduleStartupDownloadValidation();
  }

  String findValidId(ComicType type) {
    final res = _db.select(
      '''
      SELECT id FROM comics WHERE comic_type = ?
      ORDER BY CAST(id AS INTEGER) DESC
      LIMIT 1;
      ''',
      [type.value],
    );
    if (res.isEmpty) {
      return '1';
    }
    return (int.parse((res.first[0])) + 1).toString();
  }

  Future<void> add(LocalComic comic, [String? id]) async {
    var old = find(id ?? comic.id, comic.comicType);
    var downloaded = comic.downloadedChapters;
    if (old != null) {
      downloaded.addAll(old.downloadedChapters);
    }
    _db.execute(
      'INSERT OR REPLACE INTO comics VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
      [
        id ?? comic.id,
        comic.title,
        comic.subtitle,
        jsonEncode(comic.tags),
        comic.directory,
        jsonEncode(comic.chapters),
        comic.cover,
        comic.comicType.value,
        jsonEncode(downloaded),
        comic.createdAt.millisecondsSinceEpoch,
      ],
    );
    final persisted = LocalComic(
      id: id ?? comic.id,
      title: comic.title,
      subtitle: comic.subtitle,
      tags: comic.tags,
      directory: comic.directory,
      chapters: comic.chapters,
      cover: comic.cover,
      comicType: comic.comicType,
      downloadedChapters: downloaded,
      createdAt: comic.createdAt,
    );
    _upsertComicInfo(persisted);
    notifyListeners();
  }

  void remove(String id, ComicType comicType) async {
    _db.execute('DELETE FROM comics WHERE id = ? AND comic_type = ?;', [
      id,
      comicType.value,
    ]);
    notifyListeners();
  }

  void removeComic(LocalComic comic) {
    remove(comic.id, comic.comicType);
    notifyListeners();
  }

  List<LocalComic> getComics(LocalSortType sortType) {
    var res = _db.select('''
      SELECT * FROM comics
      ORDER BY
        ${sortType.value == 'name' ? 'title' : 'created_at'}
        ${sortType.value == 'time_asc' ? 'ASC' : 'DESC'}
      ;
    ''');
    return res.map((row) => LocalComic.fromRow(row)).toList();
  }

  LocalComic? find(String id, ComicType comicType) {
    final res = _db.select(
      'SELECT * FROM comics WHERE id = ? AND comic_type = ?;',
      [id, comicType.value],
    );
    if (res.isEmpty) {
      return null;
    }
    return LocalComic.fromRow(res.first);
  }

  @override
  void dispose() {
    super.dispose();
    _comicInfoFlushTimer?.cancel();
    _idleRecoveryTimer?.cancel();
    final tasks = _taskListeners.keys.toList();
    for (final task in tasks) {
      _detachTaskState(task);
    }
    _startupDownloadValidationTask = null;
    unawaited(_flushComicInfo());
    _db.dispose();
  }

  List<LocalComic> getRecent() {
    final res = _db.select('''
      SELECT * FROM comics
      ORDER BY created_at DESC
      LIMIT 20;
    ''');
    return res.map((row) => LocalComic.fromRow(row)).toList();
  }

  int get count {
    final res = _db.select('''
      SELECT COUNT(*) FROM comics;
    ''');
    return res.first[0] as int;
  }

  LocalComic? findByName(String name) {
    final res = _db.select(
      '''
      SELECT * FROM comics
      WHERE title = ? OR directory = ?;
    ''',
      [name, name],
    );
    if (res.isEmpty) {
      return null;
    }
    return LocalComic.fromRow(res.first);
  }

  List<LocalComic> search(String keyword) {
    final res = _db.select(
      '''
      SELECT * FROM comics
      WHERE title LIKE ? OR tags LIKE ? OR subtitle LIKE ?
      ORDER BY created_at DESC;
    ''',
      ['%$keyword%', '%$keyword%', '%$keyword%'],
    );
    return res.map((row) => LocalComic.fromRow(row)).toList();
  }

  Future<List<String>> getImages(String id, ComicType type, Object ep) async {
    if (ep is! String && ep is! int) {
      throw "Invalid ep";
    }
    var comic = find(id, type) ?? (throw "Comic Not Found");
    var directory = Directory(comic.baseDir);
    if (comic.hasChapters) {
      var cid = ep is int
          ? comic.chapters!.ids.elementAt(ep - 1)
          : (ep as String);
      var chapterTitle = comic.chapters!.allChapters[cid] ?? cid;
      var chapterDirName = getChapterDirectoryName(chapterTitle);
      var chapterDirectory = Directory(
        FilePath.join(directory.path, chapterDirName),
      );
      if (!chapterDirectory.existsSync()) {
        // Compatibility with old downloads that used chapter id as folder name.
        chapterDirectory = Directory(
          FilePath.join(directory.path, getChapterDirectoryName(cid)),
        );
      }
      directory = chapterDirectory;
    }
    var files = <File>[];
    await for (var entity in directory.list()) {
      if (entity is File) {
        // Do not exclude comic.cover, since it may be the first page of the chapter.
        // A file with name starting with 'cover.' is not a comic page.
        if (entity.name.startsWith('cover.')) {
          continue;
        }
        //Hidden file in some file system
        if (entity.name.startsWith('.')) {
          continue;
        }
        files.add(entity);
      }
    }
    files.sort((a, b) {
      var ai = int.tryParse(a.name.split('.').first);
      var bi = int.tryParse(b.name.split('.').first);
      if (ai != null && bi != null) {
        return ai.compareTo(bi);
      }
      return a.name.compareTo(b.name);
    });
    return files.map((e) => "file://${e.path}").toList();
  }

  bool isDownloaded(
    String id,
    ComicType type, [
    int? ep,
    ComicChapters? chapters,
  ]) {
    if (type != ComicType.local &&
        _invalidDownloadedComicKeys.contains(_comicInfoKey(type, id))) {
      return false;
    }
    var comic = find(id, type);
    if (comic == null) return false;
    if (comic.chapters == null || ep == null) return true;
    if (chapters != null) {
      if (comic.chapters?.length != chapters.length) {
        // update
        add(
          LocalComic(
            id: comic.id,
            title: comic.title,
            subtitle: comic.subtitle,
            tags: comic.tags,
            directory: comic.directory,
            chapters: chapters,
            cover: comic.cover,
            comicType: comic.comicType,
            downloadedChapters: comic.downloadedChapters,
            createdAt: comic.createdAt,
          ),
        );
      }
    }
    return comic.downloadedChapters.contains(
      (chapters ?? comic.chapters)!.ids.elementAtOrNull(ep - 1),
    );
  }

  bool shouldShowDownloadedBadge(String id, ComicType type) {
    if (type == ComicType.local) {
      return false;
    }
    return isDownloaded(id, type);
  }

  List<DownloadTask> downloadingTasks = [];
  bool _isBatchCancellingTasks = false;
  final Set<DownloadTask> _pendingRetryTasks = {};
  final Set<DownloadTask> _manualRetryTasks = {};
  final Map<DownloadTask, int> _autoRetryCount = {};
  final Map<DownloadTask, bool> _lastTaskErrorState = {};
  final Map<DownloadTask, void Function()> _taskListeners = {};
  Timer? _idleRecoveryTimer;
  bool _isRebalancingTasks = false;

  bool get isBatchCancellingTasks => _isBatchCancellingTasks;

  bool isTaskPendingRetry(DownloadTask task) =>
      _pendingRetryTasks.contains(task);

  bool isTaskManualRetryRequired(DownloadTask task) =>
      _manualRetryTasks.contains(task);

  static const int _maxAutoRetryTimes = 3;

  void _attachTaskListener(DownloadTask task) {
    if (_taskListeners.containsKey(task)) return;
    _lastTaskErrorState[task] = task.isError;
    _autoRetryCount.putIfAbsent(task, () => 0);
    void listener() => _onTaskStateChanged(task);
    _taskListeners[task] = listener;
    task.addListener(listener);
  }

  void _detachTaskState(DownloadTask task) {
    final listener = _taskListeners.remove(task);
    if (listener != null) {
      task.removeListener(listener);
    }
    _pendingRetryTasks.remove(task);
    _manualRetryTasks.remove(task);
    _autoRetryCount.remove(task);
    _lastTaskErrorState.remove(task);
  }

  void _onTaskStateChanged(DownloadTask task) {
    final wasError = _lastTaskErrorState[task] ?? false;
    final isError = task.isError;
    _lastTaskErrorState[task] = isError;

    if (!wasError && isError) {
      if (!task.shouldAutoRetryOnError()) {
        _pendingRetryTasks.remove(task);
        _manualRetryTasks.add(task);
        _scheduleIdleRecoveryCheck();
        notifyListeners();
        return;
      }
      final tried = _autoRetryCount[task] ?? 0;
      if (tried < _maxAutoRetryTimes) {
        _autoRetryCount[task] = tried + 1;
        _pendingRetryTasks.add(task);
        _manualRetryTasks.remove(task);
      } else {
        _pendingRetryTasks.remove(task);
        _manualRetryTasks.add(task);
      }
      _rebalanceDownloadingTasks(startPaused: true);
      _scheduleIdleRecoveryCheck();
      notifyListeners();
      return;
    }

    if (wasError && !isError) {
      _pendingRetryTasks.remove(task);
      _manualRetryTasks.remove(task);
      _autoRetryCount[task] = 0;
      _scheduleIdleRecoveryCheck();
      notifyListeners();
    }
  }

  void _scheduleIdleRecoveryCheck() {
    _idleRecoveryTimer?.cancel();
    if (hasRunningDownloads || downloadingTasks.isEmpty) {
      return;
    }
    final waitSeconds = 10 + Random().nextInt(21);
    _idleRecoveryTimer = Timer(Duration(seconds: waitSeconds), () {
      if (hasRunningDownloads || downloadingTasks.isEmpty) {
        return;
      }
      final snapshot = List<DownloadTask>.from(downloadingTasks);
      for (final task in snapshot) {
        if (_manualRetryTasks.contains(task)) {
          continue;
        }
        if (task.isError) {
          _pendingRetryTasks.add(task);
        }
      }
      _rebalanceDownloadingTasks(startPaused: true);
      notifyListeners();
    });
  }

  int get _maxParallelDownloadTasks {
    final raw = appdata.settings['downloadTaskThreads'] ?? 1;
    if (raw is num) {
      return raw.toInt().clamp(1, 8);
    }
    return 1;
  }

  bool get hasRunningDownloads =>
      downloadingTasks.any((task) => !task.isPaused && !task.isError);

  void _rebalanceDownloadingTasks({bool startPaused = false}) {
    if (_isRebalancingTasks) return;
    _isRebalancingTasks = true;
    try {
      if (downloadingTasks.isEmpty) return;

      final snapshot = List<DownloadTask>.from(downloadingTasks);
      final runnable = snapshot
          .where(
            (task) =>
                downloadingTasks.contains(task) &&
                (!task.isError || _pendingRetryTasks.contains(task)),
          )
          .toList();
      final target = runnable.take(_maxParallelDownloadTasks).toSet();

      for (final task in snapshot) {
        if (!downloadingTasks.contains(task)) {
          continue;
        }
        final shouldRun = target.contains(task);
        if (shouldRun) {
          if (startPaused &&
              task.isError &&
              _pendingRetryTasks.contains(task)) {
            task.resume();
            _pendingRetryTasks.remove(task);
          } else if (startPaused && task.isPaused && !task.isError) {
            task.resume();
          }
        } else {
          if (!task.isPaused) {
            task.pause();
          }
        }
      }
    } finally {
      _isRebalancingTasks = false;
      _scheduleIdleRecoveryCheck();
    }
  }

  void pauseQueue() {
    for (final task in downloadingTasks) {
      if (!task.isPaused) {
        task.pause();
      }
    }
    notifyListeners();
  }

  void resumeQueue() {
    // Start should also pick up recoverable error tasks so users don't need to
    // manually press Retry for each one.
    for (final task in downloadingTasks) {
      if (task.isError && !_manualRetryTasks.contains(task)) {
        _pendingRetryTasks.add(task);
      }
    }
    _rebalanceDownloadingTasks(startPaused: true);
    notifyListeners();
  }

  int _runningTaskCount() {
    return downloadingTasks
        .where((task) => !task.isPaused && !task.isError)
        .length;
  }

  bool resumeTask(DownloadTask task) {
    if (!downloadingTasks.contains(task)) {
      return false;
    }
    if (!task.isPaused && !task.isError) {
      return true;
    }

    if (_runningTaskCount() >= _maxParallelDownloadTasks) {
      return false;
    }

    _manualRetryTasks.remove(task);
    _autoRetryCount[task] = 0;
    task.resume();
    notifyListeners();
    return true;
  }

  bool retryTask(DownloadTask task) {
    if (!downloadingTasks.contains(task) || !task.isError) {
      return false;
    }
    _manualRetryTasks.remove(task);
    _autoRetryCount[task] = 0;
    if (_runningTaskCount() >= _maxParallelDownloadTasks) {
      _pendingRetryTasks.add(task);
      notifyListeners();
      return true;
    }
    task.resume();
    _pendingRetryTasks.remove(task);
    notifyListeners();
    return true;
  }

  void retryAllFailedTasks() {
    for (final task in downloadingTasks) {
      if (task.isError) {
        _manualRetryTasks.remove(task);
        _autoRetryCount[task] = 0;
        _pendingRetryTasks.add(task);
      }
    }
    _rebalanceDownloadingTasks(startPaused: true);
    notifyListeners();
  }

  bool isDownloading(String id, ComicType type) {
    return downloadingTasks.any(
      (element) => element.id == id && element.comicType == type,
    );
  }

  Future<Directory> findValidDirectory(
    String id,
    ComicType type,
    String name,
  ) async {
    var comic = find(id, type);
    if (comic != null) {
      return Directory(FilePath.join(path, comic.directory));
    }
    final draftDir = await _findDirectoryByStoredComicInfo(id, type);
    if (draftDir != null) {
      return draftDir;
    }
    const comicDirectoryMaxLength = 80;
    if (name.length > comicDirectoryMaxLength) {
      name = name.substring(0, comicDirectoryMaxLength);
    }

    bool canReuseDirectoryName(String dirName) {
      final exists = _db.select(
        'SELECT id, comic_type FROM comics WHERE directory = ? LIMIT 1;',
        [dirName],
      );
      return exists.isEmpty ||
          (exists.first['id'] == id &&
              exists.first['comic_type'] == type.value);
    }

    bool isVariantName(String base, String candidate) {
      if (candidate == base) return true;
      if (!candidate.startsWith('$base(') || !candidate.endsWith(')')) {
        return false;
      }
      final number = candidate.substring(base.length + 1, candidate.length - 1);
      if (number.isEmpty) return false;
      return int.tryParse(number) != null;
    }

    // Prefer reusing existing directory from variants:
    // 1) latest modified time
    // 2) larger total size as tie-breaker
    try {
      final preferredName = sanitizeFileName(name, dir: path);

      Directory? bestDir;
      int bestLatest = -1;
      int bestSize = -1;

      final root = Directory(path);
      if (root.existsSync()) {
        for (final entity in root.listSync(followLinks: false)) {
          if (entity is! Directory) continue;
          final dirName = entity.name;
          if (!isVariantName(preferredName, dirName)) continue;
          if (!canReuseDirectoryName(dirName)) continue;

          final score = _scanDirectoryScore(entity);
          final latest = score.latestModifiedMs;
          final size = score.totalBytes;
          if (latest > bestLatest ||
              (latest == bestLatest && size > bestSize)) {
            bestDir = entity;
            bestLatest = latest;
            bestSize = size;
          }
        }
      }

      if (bestDir != null) {
        return bestDir;
      }

      // If no reusable existing variant, and preferred name is not occupied,
      // use the preferred directory name directly.
      if (canReuseDirectoryName(preferredName)) {
        return Directory(
          FilePath.join(path, preferredName),
        ).create().then((value) => value);
      }
    } catch (_) {
      // fallback to original naming strategy
    }

    var dir = findValidDirectoryName(path, name);
    return Directory(FilePath.join(path, dir)).create().then((value) => value);
  }

  void completeTask(DownloadTask task) {
    final localComic = task.toLocalComic();
    add(localComic);
    if (task is ImagesDownloadTask) {
      _upsertComicInfo(localComic, url: task.comic?.url);
    } else if (task is ArchiveDownloadTask) {
      _upsertComicInfo(localComic, url: task.comic.url ?? task.archiveUrl);
    } else {
      _upsertComicInfo(localComic);
    }
    _pendingRetryTasks.remove(task);
    _manualRetryTasks.remove(task);
    _autoRetryCount.remove(task);
    _lastTaskErrorState.remove(task);
    _detachTaskState(task);
    downloadingTasks.remove(task);
    notifyListeners();
    saveCurrentDownloadingTasks();
    _rebalanceDownloadingTasks(startPaused: true);
  }

  void removeTask(DownloadTask task) {
    _detachTaskState(task);
    if (_isBatchCancellingTasks) {
      downloadingTasks.remove(task);
      return;
    }
    downloadingTasks.remove(task);
    notifyListeners();
    saveCurrentDownloadingTasks();
    _rebalanceDownloadingTasks(startPaused: true);
  }

  void cancelAllTasks() {
    if (downloadingTasks.isEmpty) return;

    _isBatchCancellingTasks = true;
    try {
      final tasks = downloadingTasks.toList();
      for (final task in tasks) {
        try {
          _detachTaskState(task);
          task.cancel();
        } catch (e, s) {
          Log.error('LocalManager', 'Failed to cancel task: $e', s);
        }
      }
      _pendingRetryTasks.clear();
      _manualRetryTasks.clear();
      _autoRetryCount.clear();
      _lastTaskErrorState.clear();
      downloadingTasks.clear();
    } finally {
      _isBatchCancellingTasks = false;
    }
    notifyListeners();
    unawaited(saveCurrentDownloadingTasks());
  }

  void moveToFirst(DownloadTask task) {
    if (downloadingTasks.first != task) {
      downloadingTasks.remove(task);
      downloadingTasks.insert(0, task);
      notifyListeners();
      saveCurrentDownloadingTasks();
      _rebalanceDownloadingTasks(startPaused: true);
    }
  }

  Future<void> saveCurrentDownloadingTasks({bool full = true}) async {
    if (_savingDownloadingTasks != null) {
      _pendingSaveDownloadingTasks = true;
      _pendingSaveDownloadingTasksFull =
          _pendingSaveDownloadingTasksFull || full;
      return _savingDownloadingTasks!;
    }
    final completer = Completer<void>();
    _savingDownloadingTasks = completer.future;
    try {
      await _saveCurrentDownloadingTasksImpl(full: full);
      while (_pendingSaveDownloadingTasks) {
        final nextFull = _pendingSaveDownloadingTasksFull;
        _pendingSaveDownloadingTasks = false;
        _pendingSaveDownloadingTasksFull = false;
        await _saveCurrentDownloadingTasksImpl(full: nextFull);
      }
      completer.complete();
    } catch (e, s) {
      if (!completer.isCompleted) {
        completer.completeError(e, s);
      }
      rethrow;
    } finally {
      _savingDownloadingTasks = null;
      _pendingSaveDownloadingTasksFull = false;
    }
  }

  Future<void> _writeJsonAtomic(String path, Object data) async {
    final file = File(path);
    final tmp = File('$path.tmp');
    await tmp.writeAsString(jsonEncode(data));
    if (file.existsSync()) {
      await file.deleteIgnoreError();
    }
    await tmp.rename(path);
  }

  Future<void> _saveCurrentDownloadingTasksImpl({bool full = true}) async {
    // Persist tasks in two formats:
    // 1) Per-manga files (full mode)
    // 2) Legacy single-file JSON (always)
    var perMangaDir = Directory(
      FilePath.join(App.dataPath, 'downloading_tasks_by_manga'),
    );
    if (full) {
      perMangaDir.createSync(recursive: true);
    }
    final activeFileNames = <String>{};

    String sanitize(String s) {
      // Replace characters invalid in file names with '_'
      final invalid = RegExp(r'[\\/:*?"<>|]');
      return s.replaceAll(invalid, '_');
    }

    final tasksSnapshot = List<DownloadTask>.from(downloadingTasks);

    if (full) {
      for (var task in tasksSnapshot) {
        var jsonObj = task.toJson();
        var title = task.title;
        var sanitizedTitle = sanitize(title);
        // Use id and type for uniqueness
        var idPart = task.id;
        var typePart = jsonObj['type'] ?? task.runtimeType.toString();
        var fileName = '${sanitizedTitle}_${idPart}_$typePart.json';
        activeFileNames.add(fileName);
        var taskPath = FilePath.join(perMangaDir.path, fileName);
        try {
          await _writeJsonAtomic(taskPath, jsonObj);
        } catch (_) {
          // Best-effort persistence; do not crash the app on failure
        }
      }
    }

    if (full) {
      // Remove stale files for tasks that are already finished/removed.
      try {
        for (var entity in perMangaDir.listSync()) {
          if (entity is File &&
              entity.name.endsWith('.json') &&
              !activeFileNames.contains(entity.name)) {
            entity.deleteSync();
          }
        }
      } catch (_) {
        // Ignore cleanup errors to avoid blocking download flow.
      }
    }

    // Keep legacy file for compatibility
    var legacy = tasksSnapshot.map((e) => e.toJson()).toList();
    await _writeJsonAtomic(
      FilePath.join(App.dataPath, 'downloading_tasks.json'),
      legacy,
    );
  }

  void restoreDownloadingTasks() {
    var seen = <String>{};
    // 1) Legacy single file
    var legacyFile = File(
      FilePath.join(App.dataPath, 'downloading_tasks.json'),
    );
    if (legacyFile.existsSync()) {
      try {
        var tasks = jsonDecode(legacyFile.readAsStringSync()) as List<dynamic>;
        for (var e in tasks) {
          var task = DownloadTask.fromJson(e);
          if (task != null) {
            var key = '${task.id}_${task.comicType.value}';
            if (!seen.contains(key)) {
              downloadingTasks.add(task);
              _attachTaskListener(task);
              seen.add(key);
            }
          }
        }
      } catch (e) {
        legacyFile.delete();
        Log.error("LocalManager", "Failed to restore downloading tasks: $e");
      }
    }

    // 2) Per-manga task files
    var perMangaDir = Directory(
      FilePath.join(App.dataPath, 'downloading_tasks_by_manga'),
    );
    if (perMangaDir.existsSync()) {
      for (var entity in perMangaDir.listSync()) {
        if (entity is File) {
          try {
            var raw = entity.readAsStringSync();
            if (raw.trim().isEmpty) {
              entity.deleteSync();
              continue;
            }
            var json = jsonDecode(raw) as Map<String, dynamic>;
            var task = DownloadTask.fromJson(json);
            if (task != null) {
              var key = '${task.id}_${task.comicType.value}';
              if (!seen.contains(key)) {
                downloadingTasks.add(task);
                _attachTaskListener(task);
                seen.add(key);
              }
            }
          } catch (e) {
            // Corrupted/partial task file, remove it to prevent repeated restore failures.
            entity.deleteIgnoreError();
            Log.error("LocalManager", "Failed to restore per-manga task: $e");
          }
        }
      }
    }
  }

  void addTask(DownloadTask task) {
    downloadingTasks.add(task);
    _attachTaskListener(task);
    notifyListeners();
    saveCurrentDownloadingTasks();
    _rebalanceDownloadingTasks(startPaused: true);
  }

  void deleteComic(LocalComic c, [bool removeFileOnDisk = true]) {
    if (removeFileOnDisk) {
      var dir = Directory(FilePath.join(path, c.directory));
      dir.deleteIgnoreError(recursive: true);
    }
    // Deleting a local comic means that it's no longer available, thus both favorite and history should be deleted.
    if (c.comicType == ComicType.local) {
      if (HistoryManager().find(c.id, c.comicType) != null) {
        HistoryManager().remove(c.id, c.comicType);
      }
      var folders = LocalFavoritesManager().find(c.id, c.comicType);
      for (var f in folders) {
        LocalFavoritesManager().deleteComicWithId(f, c.id, c.comicType);
      }
    }
    remove(c.id, c.comicType);
    final key = _comicInfoKey(c.comicType, c.id);
    _comicInfoItems.remove(key);
    _invalidDownloadedComicKeys.remove(key);
    unawaited(_comicInfoFileForComic(c).deleteIgnoreError());
    notifyListeners();
  }

  void deleteComicChapters(LocalComic c, List<String> chapters) {
    if (chapters.isEmpty) {
      return;
    }
    var newDownloadedChapters = c.downloadedChapters
        .where((e) => !chapters.contains(e))
        .toList();
    if (newDownloadedChapters.isNotEmpty) {
      _db.execute(
        'UPDATE comics SET downloadedChapters = ? WHERE id = ? AND comic_type = ?;',
        [jsonEncode(newDownloadedChapters), c.id, c.comicType.value],
      );
    } else {
      _db.execute('DELETE FROM comics WHERE id = ? AND comic_type = ?;', [
        c.id,
        c.comicType.value,
      ]);
    }
    var shouldRemovedDirs = <Directory>[];
    final removedPaths = <String>{};
    int removedPageCount = 0;
    for (var chapter in chapters) {
      var chapterTitle = c.chapters?.allChapters[chapter] ?? chapter;
      var newDir = Directory(
        FilePath.join(c.baseDir, getChapterDirectoryName(chapterTitle)),
      );
      if (newDir.existsSync()) {
        shouldRemovedDirs.add(newDir);
        if (removedPaths.add(newDir.path)) {
          removedPageCount += _countImageFilesInDirectorySync(newDir);
        }
      }
      var oldDir = Directory(
        FilePath.join(c.baseDir, getChapterDirectoryName(chapter)),
      );
      if (oldDir.existsSync() && oldDir.path != newDir.path) {
        shouldRemovedDirs.add(oldDir);
        if (removedPaths.add(oldDir.path)) {
          removedPageCount += _countImageFilesInDirectorySync(oldDir);
        }
      }
    }
    if (shouldRemovedDirs.isNotEmpty) {
      _deleteDirectories(shouldRemovedDirs);
    }
    final key = _comicInfoKey(c.comicType, c.id);
    if (newDownloadedChapters.isEmpty) {
      _comicInfoItems.remove(key);
      _invalidDownloadedComicKeys.remove(key);
      unawaited(_comicInfoFileForComic(c).deleteIgnoreError());
    } else {
      final oldInfo = _comicInfoItems[key] ?? <String, dynamic>{};
      final currentPageCount =
          (oldInfo['pageCount'] as num?)?.toInt() ?? _countComicPagesSync(c);
      _comicInfoItems[key] = {
        ...oldInfo,
        'sourceKey': c.comicType.sourceKey,
        'comicId': c.id,
        'title': c.title,
        'subtitle': c.subtitle,
        'directory': c.directory,
        'chapterCount': newDownloadedChapters.length,
        'pageCount': max(currentPageCount - removedPageCount, 0),
        'tags': c.tags,
        'updatedAt': DateTime.now().toIso8601String(),
      };
      _invalidDownloadedComicKeys.remove(key);
      _scheduleComicInfoFlush([key]);
    }
    notifyListeners();
  }

  void batchDeleteComics(
    List<LocalComic> comics, [
    bool removeFileOnDisk = true,
    bool removeFavoriteAndHistory = true,
  ]) {
    if (comics.isEmpty) {
      return;
    }

    var shouldRemovedDirs = <Directory>[];
    _db.execute('BEGIN TRANSACTION;');
    try {
      for (var c in comics) {
        if (removeFileOnDisk) {
          var dir = Directory(FilePath.join(path, c.directory));
          if (dir.existsSync()) {
            shouldRemovedDirs.add(dir);
          }
        }
        _db.execute('DELETE FROM comics WHERE id = ? AND comic_type = ?;', [
          c.id,
          c.comicType.value,
        ]);
      }
    } catch (e, s) {
      Log.error("LocalManager", "Failed to batch delete comics: $e", s);
      _db.execute('ROLLBACK;');
      return;
    }
    _db.execute('COMMIT;');

    var comicIDs = comics.map((e) => ComicID(e.comicType, e.id)).toList();

    if (removeFavoriteAndHistory) {
      LocalFavoritesManager().batchDeleteComicsInAllFolders(comicIDs);
      HistoryManager().batchDeleteHistories(comicIDs);
    }

    for (final comic in comics) {
      final key = _comicInfoKey(comic.comicType, comic.id);
      _comicInfoItems.remove(key);
      _invalidDownloadedComicKeys.remove(key);
      unawaited(_comicInfoFileForComic(comic).deleteIgnoreError());
    }

    notifyListeners();

    if (removeFileOnDisk) {
      _deleteDirectories(shouldRemovedDirs);
    }
  }

  /// Remove database entries whose comic directory no longer exists on disk.
  /// Uses batch checks to reduce UI stalls on large libraries.
  /// Returns number of removed items.
  Future<int> pruneMissingLocalComics({
    int batchSize = 200,
    Duration minInterval = const Duration(minutes: 10),
  }) async {
    if (_isPruningMissingComics) {
      return 0;
    }
    final now = DateTime.now();
    if (_lastPruneAt != null && now.difference(_lastPruneAt!) < minInterval) {
      return 0;
    }
    _isPruningMissingComics = true;
    _lastPruneAt = now;

    final comics = getComics(LocalSortType.name);
    final missing = <LocalComic>[];

    try {
      for (int i = 0; i < comics.length; i += batchSize) {
        final end = (i + batchSize < comics.length)
            ? i + batchSize
            : comics.length;
        final batch = comics.sublist(i, end);
        final exists = await Future.wait(
          batch.map((comic) => Directory(comic.baseDir).exists()),
        );
        for (int j = 0; j < batch.length; j++) {
          if (!exists[j]) {
            missing.add(batch[j]);
          }
        }
        // Yield to event loop between batches to keep UI responsive.
        if (end < comics.length) {
          await Future.delayed(const Duration(milliseconds: 1));
        }
      }

      if (missing.isEmpty) {
        return 0;
      }

      _db.execute('BEGIN TRANSACTION;');
      for (final comic in missing) {
        _db.execute('DELETE FROM comics WHERE id = ? AND comic_type = ?;', [
          comic.id,
          comic.comicType.value,
        ]);
        final key = _comicInfoKey(comic.comicType, comic.id);
        _comicInfoItems.remove(key);
        _invalidDownloadedComicKeys.remove(key);
      }
      _db.execute('COMMIT;');
      notifyListeners();
      return missing.length;
    } catch (e, s) {
      _db.execute('ROLLBACK;');
      Log.error('LocalManager', 'Failed to prune missing comics: $e', s);
      return 0;
    } finally {
      _isPruningMissingComics = false;
    }
  }

  /// Deletes the directories in a separate isolate to avoid blocking the UI thread.
  static void _deleteDirectories(List<Directory> directories) {
    Isolate.run(() async {
      await SAFTaskWorker().init();
      for (var dir in directories) {
        try {
          if (dir.existsSync()) {
            await dir.delete(recursive: true);
          }
        } catch (e) {
          continue;
        }
      }
    });
  }

  Future<List<File>> _collectComicImages(LocalComic comic) async {
    final files = <File>[];
    if (comic.hasChapters) {
      for (final chapterDir in await _chapterDirectoriesAsync(comic)) {
        await for (final entity in chapterDir.list(followLinks: false)) {
          if (entity is File && _isComicPageFile(entity)) {
            files.add(entity);
          }
        }
      }
    } else {
      final base = Directory(comic.baseDir);
      if (!base.existsSync()) {
        return files;
      }
      await for (final entity in base.list(followLinks: false)) {
        if (entity is File && _isComicPageFile(entity)) {
          files.add(entity);
        }
      }
    }
    return files;
  }

  String _normalizeTitle(String value) {
    return value.toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9\u4e00-\u9fa5]+'),
      '',
    );
  }

  bool _titlesMatch(String left, String right) {
    final a = _normalizeTitle(left);
    final b = _normalizeTitle(right);
    if (a.isEmpty || b.isEmpty) {
      return true;
    }
    return a.contains(b) || b.contains(a);
  }

  String? _titleFromUrl(String? url) {
    if (url == null || url.isEmpty) return null;
    try {
      final uri = Uri.parse(url);
      final segment = uri.pathSegments.isEmpty ? '' : uri.pathSegments.last;
      if (segment.isEmpty) return null;
      return Uri.decodeComponent(segment);
    } catch (_) {
      return null;
    }
  }

  Future<List<String>> _findComicValidationReasons(
    LocalComic comic,
    Map<String, dynamic>? info, {
    bool checkStoredTitle = true,
    bool checkTitleFromUrl = true,
    bool checkBrokenImages = false,
  }) async {
    if (info == null) {
      return const ['missing comic info entry'];
    }

    final reasons = <String>[];

    List<String>? expectedDownloadedChapters;
    final rawDownloadedChapters = info['downloadedChapters'];
    if (rawDownloadedChapters is List) {
      expectedDownloadedChapters = rawDownloadedChapters
          .whereType<Object>()
          .map((e) => e.toString())
          .where((e) => e.isNotEmpty)
          .toList();
    }

    if (checkStoredTitle) {
      final storedTitle = info['title']?.toString();
      if (storedTitle != null &&
          storedTitle.isNotEmpty &&
          !_titlesMatch(comic.title, storedTitle)) {
        reasons.add('title mismatch');
      }
    }

    if (checkTitleFromUrl) {
      final expectedTitle = _titleFromUrl(info['url']?.toString());
      if (expectedTitle != null &&
          expectedTitle.isNotEmpty &&
          !_titlesMatch(comic.title, expectedTitle)) {
        reasons.add('title mismatch');
      }
    }

    final expectedChapterCount = (info['chapterCount'] as num?)?.toInt();
    final expectedPageCount = (info['pageCount'] as num?)?.toInt();
    final localPages = await _countComicPagesAsync(comic);
    final localChapters = await _countComicChaptersAsync(comic);
    final actualDownloadedChapters = _inferDownloadedChaptersFromDirectory(
      comic,
    );

    if (comic.hasChapters &&
        expectedDownloadedChapters != null &&
        expectedDownloadedChapters
            .toSet()
            .difference(actualDownloadedChapters.toSet())
            .isNotEmpty) {
      reasons.add('downloaded chapters mismatch');
    } else if (comic.hasChapters &&
        expectedDownloadedChapters != null &&
        actualDownloadedChapters
            .toSet()
            .difference(expectedDownloadedChapters.toSet())
            .isNotEmpty) {
      reasons.add('downloaded chapters mismatch');
    }

    if (expectedChapterCount != null && expectedChapterCount != localChapters) {
      reasons.add('chapter count mismatch');
    }
    if (expectedPageCount != null && expectedPageCount != localPages) {
      reasons.add('page count mismatch');
    }

    if (checkBrokenImages) {
      final imageFiles = await _collectComicImages(comic);
      for (final file in imageFiles) {
        if (await _isImageBroken(file)) {
          reasons.add('broken image detected');
          break;
        }
      }
    }

    return reasons;
  }

  bool _sameInvalidDownloadSet(Set<String> next) {
    if (_invalidDownloadedComicKeys.length != next.length) {
      return false;
    }
    for (final key in next) {
      if (!_invalidDownloadedComicKeys.contains(key)) {
        return false;
      }
    }
    return true;
  }

  void _emitValidationProgress(
    LocalValidationProgressCallback? onProgress, {
    required String stage,
    required String message,
    required int current,
    required int total,
    double? progress,
  }) {
    if (onProgress == null) {
      return;
    }
    onProgress(
      LocalValidationProgress(
        stage: stage,
        message: message,
        current: current,
        total: total,
        progress: progress ?? (total <= 0 ? null : current / total),
      ),
    );
  }

  String _directoryBaseName(String name) {
    return name.replaceFirst(RegExp(r'\s*\(\d+\)$'), '').trimRight();
  }

  bool _isVariantDirectoryName(String name) {
    return RegExp(r'\s*\(\d+\)$').hasMatch(name);
  }

  Future<int> _countImageFilesRecursive(Directory dir) async {
    if (!dir.existsSync()) {
      return 0;
    }
    int count = 0;
    try {
      await for (final entity in dir.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is File && _isComicPageFile(entity)) {
          count++;
        }
      }
    } catch (_) {
      return count;
    }
    return count;
  }

  List<String> _inferDownloadedChaptersFromDirectory(LocalComic comic) {
    if (!comic.hasChapters) {
      return comic.downloadedChapters;
    }
    final base = Directory(comic.baseDir);
    if (!base.existsSync()) {
      return comic.downloadedChapters;
    }
    final chapterDirNames = <String>{};
    try {
      for (final entity in base.listSync(followLinks: false)) {
        if (entity is Directory && !entity.name.startsWith('.')) {
          chapterDirNames.add(entity.name);
        }
      }
    } catch (_) {
      return comic.downloadedChapters;
    }
    final chapterIds = <String>[];
    comic.chapters!.allChapters.forEach((id, title) {
      final titleDir = getChapterDirectoryName(title);
      final idDir = getChapterDirectoryName(id);
      if (chapterDirNames.contains(titleDir) ||
          chapterDirNames.contains(idDir)) {
        chapterIds.add(id);
      }
    });
    return chapterIds.isEmpty ? comic.downloadedChapters : chapterIds;
  }

  String _fileStem(String name) {
    final dot = name.lastIndexOf('.');
    if (dot <= 0) {
      return name;
    }
    return name.substring(0, dot);
  }

  String _fileExt(String name) {
    final dot = name.lastIndexOf('.');
    if (dot <= 0) {
      return '';
    }
    return name.substring(dot);
  }

  Future<String> _nextMergeFilePath(Directory dir, File source) async {
    final stem = _fileStem(source.name);
    final ext = _fileExt(source.name);
    final numericStem = int.tryParse(stem);
    if (numericStem != null) {
      int nextIndex = 0;
      try {
        await for (final entity in dir.list(followLinks: false)) {
          if (entity is! File || !_isComicPageFile(entity)) {
            continue;
          }
          final index = int.tryParse(_fileStem(entity.name));
          if (index != null && index >= nextIndex) {
            nextIndex = index + 1;
          }
        }
      } catch (_) {}
      while (File(FilePath.join(dir.path, '$nextIndex$ext')).existsSync()) {
        nextIndex++;
      }
      return FilePath.join(dir.path, '$nextIndex$ext');
    }

    int i = 1;
    while (true) {
      final path = FilePath.join(dir.path, '${stem}_merged_$i$ext');
      if (!File(path).existsSync()) {
        return path;
      }
      i++;
    }
  }

  Future<bool> _moveFileWithMerge(File source, Directory targetDir) async {
    if (!targetDir.existsSync()) {
      targetDir.createSync(recursive: true);
    }

    if (source.name == _comicInfoFileName) {
      return false;
    }

    if (source.name.toLowerCase().startsWith('cover.')) {
      File? existingCover;
      for (final entity in targetDir.listSync(followLinks: false)) {
        if (entity is File && entity.name.toLowerCase().startsWith('cover.')) {
          existingCover = entity;
          break;
        }
      }
      if (existingCover != null) {
        await source.deleteIgnoreError();
        return false;
      }
    }

    var targetPath = FilePath.join(targetDir.path, source.name);
    final targetFile = File(targetPath);
    if (targetFile.existsSync()) {
      try {
        final sourceStat = await source.stat();
        final targetStat = await targetFile.stat();
        if (sourceStat.size == targetStat.size) {
          await source.deleteIgnoreError();
          return false;
        }
      } catch (_) {}

      if (_isComicPageFile(source)) {
        targetPath = await _nextMergeFilePath(targetDir, source);
      } else {
        await source.deleteIgnoreError();
        return false;
      }
    }

    try {
      await source.rename(targetPath);
    } catch (_) {
      await source.copy(targetPath);
      await source.deleteIgnoreError();
    }
    return true;
  }

  Future<int> _mergeDirectoryContents(
    Directory source,
    Directory target,
  ) async {
    if (!target.existsSync()) {
      target.createSync(recursive: true);
    }
    int mergedFiles = 0;
    List<FileSystemEntity> entries;
    try {
      entries = source.listSync(followLinks: false);
    } catch (_) {
      return 0;
    }

    for (final entity in entries) {
      if (entity is File) {
        if (await _moveFileWithMerge(entity, target)) {
          mergedFiles++;
        }
        continue;
      }
      if (entity is! Directory) {
        continue;
      }
      final targetSubDir = Directory(FilePath.join(target.path, entity.name));
      if (!targetSubDir.existsSync()) {
        try {
          await entity.rename(targetSubDir.path);
        } catch (_) {
          await targetSubDir.create(recursive: true);
          mergedFiles += await _mergeDirectoryContents(entity, targetSubDir);
          await entity.deleteIgnoreError(recursive: true);
        }
        continue;
      }
      mergedFiles += await _mergeDirectoryContents(entity, targetSubDir);
      await entity.deleteIgnoreError(recursive: true);
    }

    return mergedFiles;
  }

  Future<void> _updateComicDirectoryReference(
    _LocalDuplicateDirectoryGroup group,
    Directory canonicalDir,
  ) async {
    if (group.comicId == null || group.comicType == null) {
      return;
    }
    final comic = find(group.comicId!, group.comicType!);
    if (comic == null) {
      return;
    }

    final updatedDirectory = canonicalDir.name;
    final updatedDownloadedChapters = _inferDownloadedChaptersFromDirectory(
      LocalComic(
        id: comic.id,
        title: comic.title,
        subtitle: comic.subtitle,
        tags: comic.tags,
        directory: updatedDirectory,
        chapters: comic.chapters,
        cover: comic.cover,
        comicType: comic.comicType,
        downloadedChapters: comic.downloadedChapters,
        createdAt: comic.createdAt,
      ),
    );

    _db.execute(
      'UPDATE comics SET directory = ?, downloadedChapters = ? WHERE id = ? AND comic_type = ?;',
      [
        updatedDirectory,
        jsonEncode(updatedDownloadedChapters),
        comic.id,
        comic.comicType.value,
      ],
    );

    final updatedComic = LocalComic(
      id: comic.id,
      title: comic.title,
      subtitle: comic.subtitle,
      tags: comic.tags,
      directory: updatedDirectory,
      chapters: comic.chapters,
      cover: comic.cover,
      comicType: comic.comicType,
      downloadedChapters: updatedDownloadedChapters,
      createdAt: comic.createdAt,
    );
    _upsertComicInfo(
      updatedComic,
      url: _comicInfoItems[group.key]?['url']?.toString(),
    );
  }

  Future<List<_LocalDuplicateDirectoryGroup>> _findDuplicateDirectoryGroups({
    List<LocalComic>? targetComics,
  }) async {
    final dirs = _listLocalComicDirectories();
    final currentComics = targetComics ?? getComics(LocalSortType.timeDesc);
    final infoKeyByPath = <String, String?>{};
    final comicTypeByPath = <String, ComicType?>{};
    final comicIdByPath = <String, String?>{};
    final baseGroups = <String, List<Directory>>{};

    for (final dir in dirs) {
      baseGroups.putIfAbsent(_directoryBaseName(dir.name), () => []).add(dir);
      final info = await _readComicInfoFile(_comicInfoFileForBaseDir(dir.path));
      final sourceKey = info?['sourceKey']?.toString();
      final comicId = info?['comicId']?.toString();
      if (sourceKey != null && comicId != null) {
        final comicType = ComicType.fromKey(sourceKey);
        infoKeyByPath[dir.path] = _comicInfoKey(comicType, comicId);
        comicTypeByPath[dir.path] = comicType;
        comicIdByPath[dir.path] = comicId;
      }
    }

    final groups = <_LocalDuplicateDirectoryGroup>[];
    final added = <String>{};

    for (final entry in baseGroups.entries) {
      if (entry.value.length <= 1) {
        continue;
      }
      final dirsInGroup = entry.value.toList()
        ..sort((a, b) => a.name.compareTo(b.name));
      final infoKeys = dirsInGroup
          .map((dir) => infoKeyByPath[dir.path])
          .whereType<String>()
          .toSet();
      if (infoKeys.isEmpty) {
        final matchedComics = currentComics.where((comic) {
          if (_directoryBaseName(comic.directory) == entry.key) {
            return true;
          }
          return dirsInGroup.any(
            (dir) =>
                _normalizePathForCompare(comic.baseDir) ==
                _normalizePathForCompare(dir.path),
          );
        }).toList();
        final matchedKeys = matchedComics
            .map((comic) => _comicInfoKey(comic.comicType, comic.id))
            .toSet();
        if (matchedKeys.length == 1 && matchedComics.isNotEmpty) {
          final comic = matchedComics.first;
          groups.add(
            _LocalDuplicateDirectoryGroup(
              label: entry.key,
              key: _comicInfoKey(comic.comicType, comic.id),
              comicType: comic.comicType,
              comicId: comic.id,
              directories: dirsInGroup,
            ),
          );
          for (final dir in dirsInGroup) {
            added.add(dir.path);
          }
        }
        continue;
      }

      if (infoKeys.length == 1) {
        final firstDir = dirsInGroup.firstWhere(
          (dir) => infoKeyByPath[dir.path] != null,
        );
        final key = infoKeyByPath[firstDir.path]!;
        groups.add(
          _LocalDuplicateDirectoryGroup(
            label: entry.key,
            key: key,
            comicType: comicTypeByPath[firstDir.path],
            comicId: comicIdByPath[firstDir.path],
            directories: dirsInGroup,
          ),
        );
        for (final dir in dirsInGroup) {
          added.add(dir.path);
        }
        continue;
      }

      for (final infoKey in infoKeys) {
        final matched = dirsInGroup
            .where((dir) => infoKeyByPath[dir.path] == infoKey)
            .toList();
        if (matched.length <= 1) {
          continue;
        }
        final firstDir = matched.first;
        groups.add(
          _LocalDuplicateDirectoryGroup(
            label: entry.key,
            key: infoKey,
            comicType: comicTypeByPath[firstDir.path],
            comicId: comicIdByPath[firstDir.path],
            directories: matched,
          ),
        );
        for (final dir in matched) {
          added.add(dir.path);
        }
      }
    }

    final metaGroups = <String, List<Directory>>{};
    for (final dir in dirs) {
      final key = infoKeyByPath[dir.path];
      if (key == null) {
        continue;
      }
      metaGroups.putIfAbsent(key, () => []).add(dir);
    }
    for (final entry in metaGroups.entries) {
      final unmatched = entry.value
          .where((dir) => !added.contains(dir.path))
          .toList();
      if (unmatched.length <= 1) {
        continue;
      }
      final firstDir = unmatched.first;
      groups.add(
        _LocalDuplicateDirectoryGroup(
          label: _directoryBaseName(firstDir.name),
          key: entry.key,
          comicType: comicTypeByPath[firstDir.path],
          comicId: comicIdByPath[firstDir.path],
          directories: unmatched,
        ),
      );
    }

    if (targetComics == null) {
      return groups;
    }

    final targetKeys = targetComics
        .map((comic) => _comicInfoKey(comic.comicType, comic.id))
        .toSet();
    final targetPaths = targetComics
        .map((comic) => _normalizePathForCompare(comic.baseDir))
        .toSet();
    final targetBaseNames = targetComics
        .map((comic) => _directoryBaseName(comic.directory))
        .toSet();

    return groups.where((group) {
      if (group.key.isNotEmpty && targetKeys.contains(group.key)) {
        return true;
      }
      for (final dir in group.directories) {
        if (targetPaths.contains(_normalizePathForCompare(dir.path))) {
          return true;
        }
        if (targetBaseNames.contains(_directoryBaseName(dir.name))) {
          return true;
        }
      }
      return false;
    }).toList();
  }

  Future<LocalDuplicateMergeReport> _mergeDuplicateDirectories({
    List<LocalComic>? targetComics,
    LocalValidationProgressCallback? onProgress,
  }) async {
    final report = LocalDuplicateMergeReport();
    final groups = await _findDuplicateDirectoryGroups(
      targetComics: targetComics,
    );
    report.groupsFound = groups.length;
    if (groups.isEmpty) {
      return report;
    }

    for (int i = 0; i < groups.length; i++) {
      final group = groups[i];
      _emitValidationProgress(
        onProgress,
        stage: 'merge-duplicates',
        message:
            '${'Merging duplicate folders'.tl} ${i + 1}/${groups.length}: ${group.label}',
        current: i,
        total: groups.length,
      );

      Directory? canonicalDir;
      int bestCount = -1;
      bool bestIsVariant = true;
      for (final dir in group.directories) {
        final count = await _countImageFilesRecursive(dir);
        final isVariant = _isVariantDirectoryName(dir.name);
        if (count > bestCount ||
            (count == bestCount && bestIsVariant && !isVariant)) {
          canonicalDir = dir;
          bestCount = count;
          bestIsVariant = isVariant;
        }
      }

      if (canonicalDir == null) {
        continue;
      }

      int mergedFiles = 0;
      int mergedDirs = 0;
      for (final dir in group.directories) {
        if (_normalizePathForCompare(dir.path) ==
            _normalizePathForCompare(canonicalDir.path)) {
          continue;
        }
        mergedFiles += await _mergeDirectoryContents(dir, canonicalDir);
        await dir.deleteIgnoreError(recursive: true);
        mergedDirs++;
      }

      await _updateComicDirectoryReference(group, canonicalDir);
      report.groupsMerged++;
      report.directoriesMerged += mergedDirs;
      report.filesMerged += mergedFiles;
      if (report.samples.length < 20) {
        report.samples.add(group.label);
      }

      _emitValidationProgress(
        onProgress,
        stage: 'merge-duplicates',
        message:
            '${'Merging duplicate folders'.tl} ${i + 1}/${groups.length}: ${group.label}',
        current: i + 1,
        total: groups.length,
      );
    }

    return report;
  }

  void scheduleStartupDownloadValidation({
    Duration delay = const Duration(seconds: 2),
  }) {
    if (_startupDownloadValidationTask != null) {
      return;
    }
    _startupDownloadValidationTask =
        Future<void>(() async {
          await Future.delayed(delay);
          await _runBackgroundDownloadValidation();
        }).whenComplete(() {
          _startupDownloadValidationTask = null;
        });
  }

  Future<void> _runBackgroundDownloadValidation() async {
    if (_isBackgroundValidatingDownloads) {
      return;
    }
    _isBackgroundValidatingDownloads = true;
    try {
      final invalidKeys = <String>{};
      final comics = getComics(LocalSortType.timeDesc);

      for (int i = 0; i < comics.length; i++) {
        final comic = comics[i];
        if (comic.comicType == ComicType.local ||
            isDownloading(comic.id, comic.comicType)) {
          continue;
        }

        final key = _comicInfoKey(comic.comicType, comic.id);
        final info = _comicInfoItems[key];
        if (info == null) {
          _upsertComicInfo(comic);
          continue;
        }

        final reasons = await _findComicValidationReasons(
          comic,
          info,
          checkStoredTitle: true,
          checkTitleFromUrl: false,
          checkBrokenImages: false,
        );
        if (reasons.isNotEmpty) {
          invalidKeys.add(key);
        }

        if (i % 8 == 0 && i > 0) {
          await Future.delayed(const Duration(milliseconds: 1));
        }
      }

      if (!_sameInvalidDownloadSet(invalidKeys)) {
        _invalidDownloadedComicKeys
          ..clear()
          ..addAll(invalidKeys);
        notifyListeners();
      }
    } finally {
      _isBackgroundValidatingDownloads = false;
    }
  }

  Future<LocalValidationReport> validateAndRepairLocalComics({
    int maxRetries = 3,
    bool repair = true,
    bool checkTitleFromUrl = true,
    bool checkBrokenImages = false,
    List<LocalComic>? targetComics,
    List<LocalValidationIssue>? issues,
    LocalValidationProgressCallback? onProgress,
  }) async {
    final report = LocalValidationReport();
    if (repair && downloadingTasks.isNotEmpty) {
      report.messages.add(
        'Skipped: there are active download tasks. Please retry after downloads finish.',
      );
      return report;
    }

    final issueList = issues ?? <LocalValidationIssue>[];

    if (issues == null) {
      final duplicateReport = await _mergeDuplicateDirectories(
        targetComics: targetComics,
        onProgress: onProgress,
      );
      report.duplicateGroupsFound = duplicateReport.groupsFound;
      report.duplicateGroupsMerged = duplicateReport.groupsMerged;
      report.duplicateDirectoriesMerged = duplicateReport.directoriesMerged;
      report.duplicateFilesMerged = duplicateReport.filesMerged;
      report.duplicateSamples.addAll(duplicateReport.samples);

      final comics = targetComics == null
          ? getComics(LocalSortType.timeDesc)
          : targetComics
                .map((comic) => find(comic.id, comic.comicType) ?? comic)
                .toList();
      report.total = comics.length;
      report.dbComics = comics.length;

      if (targetComics == null) {
        final diskDirs = _listLocalComicDirectories();
        report.diskDirectories = diskDirs.length;
        final dbDirSet = <String>{};
        for (final comic in comics) {
          dbDirSet.add(_normalizePathForCompare(comic.baseDir));
        }
        for (final dir in diskDirs) {
          if (!dbDirSet.contains(_normalizePathForCompare(dir.path))) {
            report.unindexedDirectories++;
            if (report.unindexedDirectorySamples.length < 20) {
              report.unindexedDirectorySamples.add(dir.name);
            }
          }
        }
      }

      _emitValidationProgress(
        onProgress,
        stage: 'validate',
        message: '${'Validating local comics'.tl} 0/${comics.length}',
        current: 0,
        total: comics.length,
      );
      for (final comic in comics) {
        report.checked++;
        _emitValidationProgress(
          onProgress,
          stage: 'validate',
          message:
              '${'Validating local comics'.tl} ${report.checked}/${comics.length}: ${comic.title}',
          current: report.checked,
          total: comics.length,
        );
        final info = _comicInfoItems[_comicInfoKey(comic.comicType, comic.id)];
        final reasons = await _findComicValidationReasons(
          comic,
          info,
          checkStoredTitle: true,
          checkTitleFromUrl: checkTitleFromUrl,
          checkBrokenImages: checkBrokenImages,
        );

        if (reasons.isEmpty) {
          report.verified++;
          continue;
        }

        issueList.add(
          LocalValidationIssue(
            comic: comic,
            info: info ?? const {},
            reason: reasons.join(', '),
          ),
        );
      }
    }

    report.issues.addAll(issueList);
    report.invalid = issueList.length;

    if (!repair) {
      final invalidKeys = issueList
          .where((issue) => issue.comic.comicType != ComicType.local)
          .map((issue) => _comicInfoKey(issue.comic.comicType, issue.comic.id))
          .toSet();
      if (!_sameInvalidDownloadSet(invalidKeys)) {
        _invalidDownloadedComicKeys
          ..clear()
          ..addAll(invalidKeys);
        notifyListeners();
      }
    }

    if (!repair) {
      await _flushComicInfo();
      return report;
    }

    _emitValidationProgress(
      onProgress,
      stage: 'repair',
      message: '${'Repairing local comics'.tl} 0/${issueList.length}',
      current: 0,
      total: issueList.length,
    );
    for (int issueIndex = 0; issueIndex < issueList.length; issueIndex++) {
      final issue = issueList[issueIndex];
      final comic = issue.comic;
      final info = issue.info;

      _emitValidationProgress(
        onProgress,
        stage: 'repair',
        message:
            '${'Repairing local comics'.tl} ${issueIndex + 1}/${issueList.length}: ${comic.title}',
        current: issueIndex,
        total: issueList.length,
      );

      if (issue.reason.contains('missing comic info entry')) {
        await _upsertComicInfoAsync(comic);
        report.repaired++;
        _emitValidationProgress(
          onProgress,
          stage: 'repair',
          message:
              '${'Repairing local comics'.tl} ${issueIndex + 1}/${issueList.length}: ${comic.title}',
          current: issueIndex + 1,
          total: issueList.length,
        );
        if (issueIndex % 5 == 0) {
          await Future.delayed(const Duration(milliseconds: 1));
        }
        continue;
      }

      if (comic.comicType == ComicType.local) {
        await _upsertComicInfoAsync(comic);
        report.repaired++;
        _emitValidationProgress(
          onProgress,
          stage: 'repair',
          message:
              '${'Repairing local comics'.tl} ${issueIndex + 1}/${issueList.length}: ${comic.title}',
          current: issueIndex + 1,
          total: issueList.length,
        );
        if (issueIndex % 5 == 0) {
          await Future.delayed(const Duration(milliseconds: 1));
        }
        continue;
      }

      final sourceKey = info['sourceKey']?.toString();
      final comicId = info['comicId']?.toString();
      if (sourceKey == null || comicId == null) {
        report.failed++;
        report.messages.add('Cannot repair (missing source): ${comic.title}');
        _emitValidationProgress(
          onProgress,
          stage: 'repair',
          message:
              '${'Repairing local comics'.tl} ${issueIndex + 1}/${issueList.length}: ${comic.title}',
          current: issueIndex + 1,
          total: issueList.length,
        );
        continue;
      }

      final source = ComicSource.find(sourceKey);
      if (source?.loadComicInfo == null || source?.loadComicPages == null) {
        report.failed++;
        report.messages.add(
          'Cannot repair (source unsupported): ${comic.title}',
        );
        _emitValidationProgress(
          onProgress,
          stage: 'repair',
          message:
              '${'Repairing local comics'.tl} ${issueIndex + 1}/${issueList.length}: ${comic.title}',
          current: issueIndex + 1,
          total: issueList.length,
        );
        continue;
      }

      bool repaired = false;
      for (int i = 1; i <= maxRetries; i++) {
        try {
          final dir = Directory(comic.baseDir);
          await dir.deleteIgnoreError(recursive: true);
          await dir.create(recursive: true);

          final task = ImagesDownloadTask(
            source: source!,
            comicId: comicId,
            comicTitle: comic.title,
          );
          addTask(task);

          while (isDownloading(comic.id, comic.comicType)) {
            _emitValidationProgress(
              onProgress,
              stage: 'repair',
              message:
                  '${'Repairing local comics'.tl} ${issueIndex + 1}/${issueList.length}: ${comic.title}',
              current: issueIndex,
              total: issueList.length,
              progress: issueList.isEmpty
                  ? null
                  : ((issueIndex + task.progress) / issueList.length).clamp(
                      0.0,
                      1.0,
                    ),
            );
            await Future.delayed(const Duration(milliseconds: 500));
          }

          final refreshed = find(comic.id, comic.comicType);
          if (refreshed == null) {
            continue;
          }
          final pages = _countComicPagesSync(refreshed);
          final files = await _collectComicImages(refreshed);
          bool broken = false;
          for (final file in files) {
            if (await _isImageBroken(file)) {
              broken = true;
              break;
            }
          }
          if (!broken && pages > 0) {
            _upsertComicInfo(refreshed, url: info['url']?.toString());
            repaired = true;
            break;
          }
        } catch (e, s) {
          Log.error('LocalManager', 'Repair failed: $e', s);
        }
      }

      if (repaired) {
        report.repaired++;
      } else {
        report.failed++;
        report.messages.add(
          'Repair failed after $maxRetries retries: ${comic.title}',
        );
      }
      _emitValidationProgress(
        onProgress,
        stage: 'repair',
        message:
            '${'Repairing local comics'.tl} ${issueIndex + 1}/${issueList.length}: ${comic.title}',
        current: issueIndex + 1,
        total: issueList.length,
      );
    }

    await _flushComicInfo();
    await _runBackgroundDownloadValidation();
    return report;
  }

  String _normalizePathForCompare(String p) {
    var normalized = Directory(p).absolute.path.replaceAll('\\', '/');
    while (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    if (App.isWindows) {
      normalized = normalized.toLowerCase();
    }
    return normalized;
  }

  List<Directory> _listLocalComicDirectories() {
    final root = Directory(path);
    if (!root.existsSync()) {
      return const [];
    }
    final dirs = <Directory>[];
    try {
      for (final entity in root.listSync(followLinks: false)) {
        if (entity is! Directory) {
          continue;
        }
        if (entity.name.startsWith('.')) {
          continue;
        }
        dirs.add(entity);
      }
    } catch (_) {
      return const [];
    }
    return dirs;
  }

  LocalComic? _buildLocalComicFromDirectory(
    Directory directory, {
    required DateTime createTime,
    Set<String>? existingNames,
  }) {
    if (!directory.existsSync()) return null;
    final title = directory.name;
    if (existingNames != null && existingNames.contains(title)) {
      return null;
    }

    bool hasChapters = false;
    final chapters = <String>[];
    final rootImages = <String>[];

    try {
      for (final entry in directory.listSync(followLinks: false)) {
        if (entry is Directory) {
          hasChapters = true;
          chapters.add(entry.name);
        } else if (entry is File) {
          if (_isSupportedImageExt(entry.extension)) {
            rootImages.add(entry.name);
          }
        }
      }
    } catch (_) {
      return null;
    }

    if (!hasChapters && rootImages.isEmpty) {
      return null;
    }

    rootImages.sort();
    String cover = '';
    if (rootImages.isNotEmpty) {
      for (final image in rootImages) {
        if (image.toLowerCase().startsWith('cover.')) {
          cover = image;
          break;
        }
      }
      cover = cover.isEmpty ? rootImages.first : cover;
    }

    chapters.sort();
    if (cover.isEmpty && hasChapters && chapters.isNotEmpty) {
      final firstChapter = Directory(
        FilePath.join(directory.path, chapters.first),
      );
      final chapterImages = _imageFilesInDirectory(firstChapter);
      if (chapterImages.isNotEmpty) {
        cover = FilePath.join(
          chapters.first,
          chapterImages.first.name,
        ).replaceAll('\\', '/');
      }
    }

    if (cover.isEmpty) {
      return null;
    }

    return LocalComic(
      id: '0',
      title: title,
      subtitle: '',
      tags: const [],
      directory: directory.name,
      chapters: hasChapters
          ? ComicChapters(Map.fromIterables(chapters, chapters))
          : null,
      cover: cover,
      comicType: ComicType.local,
      downloadedChapters: chapters,
      createdAt: createTime,
    );
  }

  Future<LocalDatabaseRestoreReport> restoreLocalDatabaseFromDisk() async {
    final report = LocalDatabaseRestoreReport();
    final dirs = _listLocalComicDirectories();
    report.totalDirectories = dirs.length;

    final existingComics = getComics(LocalSortType.timeDesc);
    final existingNames = <String>{};
    final existingDirs = <String>{};
    for (final comic in existingComics) {
      existingNames.add(comic.title);
      existingDirs.add(_normalizePathForCompare(comic.baseDir));
    }

    int nextId;
    try {
      final res = _db.select(
        'SELECT id FROM comics WHERE comic_type = ? ORDER BY CAST(id AS INTEGER) DESC LIMIT 1;',
        [ComicType.local.value],
      );
      if (res.isEmpty) {
        nextId = 1;
      } else {
        nextId = (int.tryParse(res.first[0].toString()) ?? 0) + 1;
      }
    } catch (_) {
      nextId = 1;
    }

    for (int i = 0; i < dirs.length; i++) {
      final dir = dirs[i];
      report.scanned++;
      try {
        final normalizedDir = _normalizePathForCompare(dir.path);
        if (existingDirs.contains(normalizedDir)) {
          report.skipped++;
          continue;
        }

        final candidate = _buildLocalComicFromDirectory(
          dir,
          createTime: dir.statSync().modified,
          existingNames: existingNames,
        );
        if (candidate == null) {
          report.skipped++;
          continue;
        }

        final assignedId = (nextId++).toString();
        final downloaded = List<String>.from(candidate.downloadedChapters);
        _db.execute(
          'INSERT OR REPLACE INTO comics VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
          [
            assignedId,
            candidate.title,
            candidate.subtitle,
            jsonEncode(candidate.tags),
            candidate.directory,
            jsonEncode(candidate.chapters),
            candidate.cover,
            candidate.comicType.value,
            jsonEncode(downloaded),
            candidate.createdAt.millisecondsSinceEpoch,
          ],
        );

        final persisted = LocalComic(
          id: assignedId,
          title: candidate.title,
          subtitle: candidate.subtitle,
          tags: candidate.tags,
          directory: candidate.directory,
          chapters: candidate.chapters,
          cover: candidate.cover,
          comicType: candidate.comicType,
          downloadedChapters: downloaded,
          createdAt: candidate.createdAt,
        );
        _upsertComicInfo(persisted);

        existingNames.add(persisted.title);
        existingDirs.add(_normalizePathForCompare(persisted.baseDir));
        report.restored++;
      } catch (e) {
        report.failed++;
        if (report.messages.length < 50) {
          report.messages.add('Failed to restore ${dir.name}: $e');
        }
      }

      if (i % 20 == 0 && i > 0) {
        await Future.delayed(const Duration(milliseconds: 1));
      }
    }

    if (report.restored > 0) {
      _scheduleComicInfoFlush();
      notifyListeners();
    }

    return report;
  }

  bool _isSupportedImageExt(String ext) {
    const exts = {'jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp', 'avif', 'jxl'};
    return exts.contains(ext.toLowerCase());
  }

  List<File> _imageFilesInDirectory(Directory dir) {
    if (!dir.existsSync()) {
      return const [];
    }
    final files = <File>[];
    try {
      for (final entity in dir.listSync(followLinks: false)) {
        if (entity is File && _isSupportedImageExt(entity.extension)) {
          files.add(entity);
        }
      }
    } catch (_) {
      return const [];
    }
    files.sort((a, b) => a.name.compareTo(b.name));
    return files;
  }

  File? _findCoverCandidateByBaseDir(String baseDir) {
    final base = Directory(baseDir);
    if (!base.existsSync()) {
      return null;
    }

    final baseImages = _imageFilesInDirectory(base);
    File? explicitCover;
    for (final file in baseImages) {
      if (file.name.toLowerCase().startsWith('cover.')) {
        explicitCover = file;
        break;
      }
    }
    if (explicitCover != null) {
      return explicitCover;
    }
    if (baseImages.isNotEmpty) {
      return baseImages.first;
    }

    // Fallback: scan first-level chapter folders and use first image found.
    try {
      final chapterDirs = <Directory>[];
      for (final entity in base.listSync(followLinks: false)) {
        if (entity is Directory && !entity.name.startsWith('.')) {
          chapterDirs.add(entity);
        }
      }
      chapterDirs.sort((a, b) => a.name.compareTo(b.name));
      for (final chapterDir in chapterDirs) {
        final chapterImages = _imageFilesInDirectory(
          chapterDir,
        ).where((f) => !f.name.toLowerCase().startsWith('cover.')).toList();
        if (chapterImages.isNotEmpty) {
          return chapterImages.first;
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  String _toRelativeCoverPath(String baseDir, String filePath) {
    final base = Directory(baseDir).absolute.path;
    final full = File(filePath).absolute.path;
    if (full.length > base.length) {
      final i = base.endsWith('\\') || base.endsWith('/')
          ? base.length
          : base.length + 1;
      if (i <= full.length) {
        return full.substring(i).replaceAll('\\', '/');
      }
    }
    return File(filePath).name;
  }

  Future<LocalCoverRepairReport> repairLocalCoverIndex() async {
    final report = LocalCoverRepairReport();
    if (downloadingTasks.isNotEmpty) {
      report.messages.add(
        'Skipped: there are active download tasks. Please retry after downloads finish.',
      );
      return report;
    }
    void addReportMessage(String message) {
      if (report.messages.length < 200) {
        report.messages.add(message);
      }
    }

    final rows = _db.select('''
      SELECT id, title, directory, cover, comic_type
      FROM comics
      ORDER BY created_at DESC;
    ''');
    report.total = rows.length;

    bool changed = false;

    for (final row in rows) {
      report.checked++;
      try {
        final id = row['id']?.toString();
        final title = row['title']?.toString() ?? '';
        final directory = row['directory']?.toString();
        final cover = row['cover']?.toString() ?? '';
        final comicTypeValue = row['comic_type'];

        if (id == null || directory == null || directory.isEmpty) {
          report.failed++;
          addReportMessage('Repair failed: invalid row data');
          continue;
        }

        final comicType = ComicType(
          comicTypeValue is int ? comicTypeValue : ComicType.local.value,
        );

        final baseDir = (directory.contains('/') || directory.contains('\\'))
            ? directory
            : FilePath.join(path, directory);

        final currentCover = File(FilePath.join(baseDir, cover));
        if (currentCover.existsSync()) {
          report.valid++;
          continue;
        }

        final key = _comicInfoKey(comicType, id);
        final info = _comicInfoItems[key];

        File? candidate = _findCoverCandidateByBaseDir(baseDir);
        if (candidate == null) {
          try {
            final sourceKey = info?['sourceKey']?.toString();
            final comicId = info?['comicId']?.toString() ?? id;
            final source = sourceKey == null
                ? null
                : ComicSource.find(sourceKey);
            if (source?.loadComicInfo != null) {
              final detailRes = await source!.loadComicInfo!(comicId);
              if (!detailRes.error) {
                final coverUrl = detailRes.data.cover;
                if (coverUrl.isNotEmpty) {
                  final base = Directory(baseDir);
                  if (!base.existsSync()) {
                    base.createSync(recursive: true);
                  }
                  List<int>? bytes;
                  await for (final p in ImageDownloader.loadThumbnail(
                    coverUrl,
                    source.key,
                    comicId,
                  )) {
                    if (p.imageBytes != null) {
                      bytes = p.imageBytes;
                    }
                  }
                  if (bytes != null && bytes.isNotEmpty) {
                    final fileType = detectFileType(bytes);
                    final coverFile = File(
                      FilePath.join(base.path, 'cover${fileType.ext}'),
                    );
                    coverFile.writeAsBytesSync(bytes, flush: true);
                    candidate = coverFile;
                  }
                }
              }
            }
          } catch (_) {
            // ignore network fallback errors and keep normal failure path
          }
        }

        if (candidate == null) {
          report.failed++;
          addReportMessage('Cover not found: $title');
          continue;
        }

        final relativeCover = _toRelativeCoverPath(baseDir, candidate.path);
        _db.execute(
          'UPDATE comics SET cover = ? WHERE id = ? AND comic_type = ?;',
          [relativeCover, id, comicType.value],
        );

        final oldInfo = info;
        if (oldInfo != null) {
          _comicInfoItems[key] = {
            ...oldInfo,
            'cover': relativeCover,
            'updatedAt': DateTime.now().toIso8601String(),
          };
          _scheduleComicInfoFlush([key]);
        }

        changed = true;
        report.repaired++;
      } catch (e) {
        report.failed++;
        addReportMessage('Repair failed: $e');
      }

      if (report.checked % 10 == 0) {
        await Future.delayed(const Duration(milliseconds: 1));
      }
    }

    if (changed) {
      notifyListeners();
    }

    return report;
  }

  static String getChapterDirectoryName(String name) {
    var builder = StringBuffer();
    for (var i = 0; i < name.length; i++) {
      var char = name[i];
      if (char == '/' ||
          char == '\\' ||
          char == ':' ||
          char == '*' ||
          char == '?' ||
          char == '"' ||
          char == '<' ||
          char == '>' ||
          char == '|') {
        builder.write('_');
      } else {
        builder.write(char);
      }
    }
    var result = builder.toString();
    while (result.endsWith(' ') || result.endsWith('.')) {
      result = result.substring(0, result.length - 1);
    }
    if (result.isEmpty) {
      result = '_';
    }
    return result;
  }
}

class LocalValidationReport {
  int total = 0;
  int checked = 0;
  int dbComics = 0;
  int diskDirectories = 0;
  int unindexedDirectories = 0;
  int invalid = 0;
  int verified = 0;
  int repaired = 0;
  int failed = 0;
  int skipped = 0;
  int duplicateGroupsFound = 0;
  int duplicateGroupsMerged = 0;
  int duplicateDirectoriesMerged = 0;
  int duplicateFilesMerged = 0;
  final List<String> messages = [];
  final List<LocalValidationIssue> issues = [];
  final List<String> unindexedDirectorySamples = [];
  final List<String> duplicateSamples = [];
}

class LocalValidationIssue {
  final LocalComic comic;
  final Map<String, dynamic> info;
  final String reason;

  const LocalValidationIssue({
    required this.comic,
    required this.info,
    required this.reason,
  });
}

class LocalCoverRepairReport {
  int total = 0;
  int checked = 0;
  int valid = 0;
  int repaired = 0;
  int failed = 0;
  final List<String> messages = [];
}

class LocalDatabaseRestoreReport {
  int totalDirectories = 0;
  int scanned = 0;
  int restored = 0;
  int skipped = 0;
  int failed = 0;
  final List<String> messages = [];
}

class LocalValidationProgress {
  final String stage;
  final String message;
  final int current;
  final int total;
  final double? progress;

  const LocalValidationProgress({
    required this.stage,
    required this.message,
    required this.current,
    required this.total,
    this.progress,
  });
}

typedef LocalValidationProgressCallback =
    void Function(LocalValidationProgress progress);

class LocalDuplicateMergeReport {
  int groupsFound = 0;
  int groupsMerged = 0;
  int directoriesMerged = 0;
  int filesMerged = 0;
  final List<String> samples = [];
}

class _LocalDuplicateDirectoryGroup {
  final String label;
  final String key;
  final ComicType? comicType;
  final String? comicId;
  final List<Directory> directories;

  const _LocalDuplicateDirectoryGroup({
    required this.label,
    required this.key,
    required this.comicType,
    required this.comicId,
    required this.directories,
  });
}

enum LocalSortType {
  name("name"),
  timeAsc("time_asc"),
  timeDesc("time_desc");

  final String value;

  const LocalSortType(this.value);

  static LocalSortType fromString(String value) {
    for (var type in values) {
      if (type.value == value) {
        return type;
      }
    }
    return name;
  }
}
