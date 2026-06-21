import 'dart:async';

import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/pages/downloading_page.dart';
import 'package:venera/pages/favorites/favorites_page.dart';
import 'package:venera/utils/cbz.dart';
import 'package:venera/utils/epub.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/pdf.dart';
import 'package:venera/utils/translations.dart';
import 'package:zip_flutter/zip_flutter.dart';
import 'package:url_launcher/url_launcher_string.dart';

class LocalComicsPage extends StatefulWidget {
  const LocalComicsPage({super.key});

  @override
  State<LocalComicsPage> createState() => _LocalComicsPageState();
}

class _LocalComicsPageState extends State<LocalComicsPage> {
  static const String _syncTargetAllLocalFavorites = '__local_all_favorites__';

  late List<LocalComic> comics;

  late LocalSortType sortType;

  String keyword = "";

  bool searchMode = false;

  bool multiSelectMode = false;

  Map<LocalComic, bool> selectedComics = {};

  void _updateValidationProgress(
    LoadingDialogController controller,
    LocalValidationProgress progress,
  ) {
    controller.setMessage(progress.message);
    controller.setProgress(progress.progress);
  }

  String _validationDuplicateSummary(LocalValidationReport report) {
    if (report.duplicateGroupsMerged <= 0) {
      return '';
    }
    return '\n${'Merged @g duplicate folders and @f files.'.tlParams({'g': report.duplicateGroupsMerged, 'f': report.duplicateFilesMerged})}';
  }

  void update() {
    if (keyword.isEmpty) {
      setState(() {
        comics = LocalManager().getComics(sortType);
      });
    } else {
      setState(() {
        comics = LocalManager().search(keyword);
      });
    }
  }

  @override
  void initState() {
    var sort = appdata.implicitData["local_sort"] ?? "name";
    sortType = LocalSortType.fromString(sort);
    comics = LocalManager().getComics(sortType);
    LocalManager().addListener(update);
    unawaited(_checkMissingLocalComics());
    super.initState();
  }

  Future<void> _checkMissingLocalComics() async {
    final removed = await LocalManager().pruneMissingLocalComics();
    if (removed > 0 && mounted) {
      update();
    }
  }

  @override
  void dispose() {
    LocalManager().removeListener(update);
    super.dispose();
  }

  String _comicKey(String id, ComicType type) {
    return '${type.value}::$id';
  }

  Future<Set<String>> _loadNetworkFavoriteKeys(String sourceKey) async {
    final source = ComicSource.find(sourceKey);
    final favoriteData = source?.favoriteData;
    if (source == null || favoriteData == null) {
      return {};
    }

    final keys = <String>{};
    final folderId = favoriteData.allFavoritesId;
    final type = ComicType(sourceKey.hashCode);

    if (favoriteData.loadComic != null) {
      int page = 1;
      while (page <= 200) {
        final res = await favoriteData.loadComic!(page, folderId);
        if (res.error) {
          throw Exception(
            res.errorMessage ?? 'Failed to load network favorites',
          );
        }
        for (final comic in res.data) {
          keys.add(_comicKey(comic.id, type));
        }
        final maxPage = res.subData is int ? res.subData as int : null;
        if (res.data.isEmpty || (maxPage != null && page >= maxPage)) {
          break;
        }
        page++;
      }
      return keys;
    }

    if (favoriteData.loadNext != null) {
      String? next;
      int rounds = 0;
      while (rounds < 200) {
        final res = await favoriteData.loadNext!(next, folderId);
        if (res.error) {
          throw Exception(
            res.errorMessage ?? 'Failed to load network favorites',
          );
        }
        for (final comic in res.data) {
          keys.add(_comicKey(comic.id, type));
        }
        rounds++;
        if (res.data.isEmpty || res.subData == null) {
          break;
        }
        next = res.subData;
      }
    }

    return keys;
  }

  Future<void> _syncWithFavorites() async {
    final localFolders = LocalFavoritesManager().folderNames;
    final networkSources = <String>[];
    final networkSettings = appdata.settings['favorites'];
    if (networkSettings is List) {
      for (final raw in networkSettings) {
        if (raw is! String) continue;
        final source = ComicSource.find(raw);
        if (source?.favoriteData != null && !networkSources.contains(raw)) {
          networkSources.add(raw);
        }
      }
    }

    final targetLabels = <String, String>{
      _syncTargetAllLocalFavorites: 'Local Favorites (All)'.tl,
      for (final folder in localFolders)
        folder: 'Local: @f'.tlParams({'f': folder}),
      for (final key in networkSources)
        'network:$key': 'Network: @n'.tlParams({
          'n': ComicSource.find(key)?.name ?? key,
        }),
    };

    final targetKeys = targetLabels.keys.toList();
    if (targetKeys.isEmpty) {
      context.showMessage(message: 'No favorites source available'.tl);
      return;
    }

    String selectedTarget = targetKeys.first;
    bool? confirmed;
    await showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return ContentDialog(
              title: 'Sync with Favorites'.tl,
              content: ListTile(
                title: Text('Target Favorites'.tl),
                trailing: Select(
                  current: targetLabels[selectedTarget]!,
                  values: targetKeys.map((e) => targetLabels[e]!).toList(),
                  minWidth: 196,
                  onTap: (index) {
                    setState(() {
                      selectedTarget = targetKeys[index];
                    });
                  },
                ),
              ),
              actions: [
                Button.text(
                  onPressed: () {
                    confirmed = false;
                    context.pop();
                  },
                  child: Text('Cancel'.tl),
                ),
                Button.filled(
                  onPressed: () {
                    confirmed = true;
                    context.pop();
                  },
                  child: Text('Confirm'.tl),
                ),
              ],
            );
          },
        );
      },
    );

    if (confirmed != true) {
      return;
    }

    final loading = showLoadingDialog(context, message: 'Scanning'.tl);
    List<LocalComic> staleComics = [];
    try {
      final favoriteKeys = <String>{};
      if (selectedTarget == _syncTargetAllLocalFavorites) {
        final all = LocalFavoritesManager().getAllComics();
        for (final item in all) {
          favoriteKeys.add(_comicKey(item.id, item.type));
        }
      } else if (selectedTarget.startsWith('network:')) {
        final sourceKey = selectedTarget.substring('network:'.length);
        favoriteKeys.addAll(await _loadNetworkFavoriteKeys(sourceKey));
      } else {
        final folderComics = LocalFavoritesManager().getFolderComics(
          selectedTarget,
        );
        for (final item in folderComics) {
          favoriteKeys.add(_comicKey(item.id, item.type));
        }
      }

      final allLocalComics = LocalManager().getComics(sortType);
      staleComics = allLocalComics.where((comic) {
        return !favoriteKeys.contains(_comicKey(comic.id, comic.comicType));
      }).toList();
    } catch (e, s) {
      loading.close();
      Log.error('Local Sync', e, s);
      if (mounted) {
        context.showMessage(message: e.toString());
      }
      return;
    }
    loading.close();

    if (staleComics.isEmpty) {
      context.showMessage(
        message: 'All local comics are in target favorites'.tl,
      );
      return;
    }

    final selected = <LocalComic, bool>{
      for (final comic in staleComics) comic: true,
    };
    bool? shouldDelete;
    await showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            final selectedCount = selected.values.where((v) => v).length;
            return ContentDialog(
              title: 'Delete local comics not in favorites'.tl,
              content: SizedBox(
                width: 560,
                height: 420,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Found @c comics not in selected favorites'.tlParams({
                        'c': staleComics.length,
                      }),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: ListView.builder(
                        itemCount: staleComics.length,
                        itemBuilder: (context, index) {
                          final comic = staleComics[index];
                          return CheckboxListTile(
                            value: selected[comic] ?? false,
                            title: Text(comic.title),
                            subtitle: Text(comic.subtitle),
                            onChanged: (v) {
                              setState(() {
                                selected[comic] = v ?? false;
                              });
                            },
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                Button.text(
                  onPressed: () {
                    shouldDelete = false;
                    context.pop();
                  },
                  child: Text('Cancel'.tl),
                ),
                Button.filled(
                  onPressed: () {
                    if (selectedCount == 0) {
                      return;
                    }
                    shouldDelete = true;
                    context.pop();
                  },
                  child: Text(
                    'Delete @c comics'.tlParams({'c': selectedCount}),
                  ),
                ),
              ],
            );
          },
        );
      },
    );

    if (shouldDelete == true) {
      final toDelete = selected.entries
          .where((entry) => entry.value)
          .map((entry) => entry.key)
          .toList();
      if (toDelete.isNotEmpty) {
        final deleted = await deleteComics(toDelete);
        if (deleted) {
          context.showMessage(
            message: 'Deleted @c local comics'.tlParams({'c': toDelete.length}),
          );
        }
      }
    }
  }

  void sort() {
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return ContentDialog(
              title: "Sort".tl,
              content: RadioGroup<LocalSortType>(
                groupValue: sortType,
                onChanged: (v) {
                  setState(() {
                    sortType = v ?? sortType;
                  });
                },
                child: Column(
                  children: [
                    RadioListTile<LocalSortType>(
                      title: Text("Name".tl),
                      value: LocalSortType.name,
                    ),
                    RadioListTile<LocalSortType>(
                      title: Text("Date".tl),
                      value: LocalSortType.timeAsc,
                    ),
                    RadioListTile<LocalSortType>(
                      title: Text("Date Desc".tl),
                      value: LocalSortType.timeDesc,
                    ),
                  ],
                ),
              ),
              actions: [
                FilledButton(
                  onPressed: () {
                    appdata.implicitData["local_sort"] = sortType.value;
                    appdata.writeImplicitData();
                    Navigator.pop(context);
                    update();
                  },
                  child: Text("Confirm".tl),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget buildMultiSelectMenu() {
    return MenuButton(
      entries: [
        MenuEntry(
          icon: Icons.verified_outlined,
          text: "Verify".tl,
          onClick: () {
            validateComics(selectedComics.keys.toList());
          },
        ),
        MenuEntry(
          icon: Icons.delete_outline,
          text: "Delete".tl,
          onClick: () {
            deleteComics(selectedComics.keys.toList()).then((value) {
              if (value) {
                setState(() {
                  multiSelectMode = false;
                  selectedComics.clear();
                });
              }
            });
          },
        ),
        MenuEntry(
          icon: Icons.favorite_border,
          text: "Add to favorites".tl,
          onClick: () {
            addFavorite(selectedComics.keys.toList());
          },
        ),
        if (selectedComics.length == 1)
          MenuEntry(
            icon: Icons.folder_open,
            text: "Open Folder".tl,
            onClick: () {
              openComicFolder(selectedComics.keys.first);
            },
          ),
        if (selectedComics.length == 1)
          MenuEntry(
            icon: Icons.chrome_reader_mode_outlined,
            text: "View Detail".tl,
            onClick: () {
              context.to(
                () => ComicPage(
                  id: selectedComics.keys.first.id,
                  sourceKey: selectedComics.keys.first.sourceKey,
                ),
              );
            },
          ),
        if (selectedComics.isNotEmpty)
          ...exportActions(selectedComics.keys.toList()),
      ],
    );
  }

  void selectAll() {
    setState(() {
      selectedComics = comics.asMap().map((k, v) => MapEntry(v, true));
    });
  }

  void deSelect() {
    setState(() {
      selectedComics.clear();
    });
  }

  void invertSelection() {
    setState(() {
      comics.asMap().forEach((k, v) {
        selectedComics[v] = !selectedComics.putIfAbsent(v, () => false);
      });
      selectedComics.removeWhere((k, v) => !v);
    });
  }

  @override
  Widget build(BuildContext context) {
    List<Widget> selectActions = [
      IconButton(
        icon: const Icon(Icons.select_all),
        tooltip: "Select All".tl,
        onPressed: selectAll,
      ),
      IconButton(
        icon: const Icon(Icons.deselect),
        tooltip: "Deselect".tl,
        onPressed: deSelect,
      ),
      IconButton(
        icon: const Icon(Icons.flip),
        tooltip: "Invert Selection".tl,
        onPressed: invertSelection,
      ),
      buildMultiSelectMenu(),
    ];

    List<Widget> normalActions = [
      Tooltip(
        message: "Search".tl,
        child: IconButton(
          icon: const Icon(Icons.search),
          onPressed: () {
            setState(() {
              searchMode = true;
            });
          },
        ),
      ),
      Tooltip(
        message: "Sort".tl,
        child: IconButton(icon: const Icon(Icons.sort), onPressed: sort),
      ),
      Tooltip(
        message: "Downloading".tl,
        child: IconButton(
          icon: const Icon(Icons.download),
          onPressed: () {
            showPopUpWidget(context, const DownloadingPage());
          },
        ),
      ),
      Tooltip(
        message: 'Sync with Favorites'.tl,
        child: IconButton(
          icon: const Icon(Icons.sync_alt),
          onPressed: _syncWithFavorites,
        ),
      ),
    ];

    var body = Scaffold(
      body: SmoothCustomScrollView(
        slivers: [
          if (!searchMode)
            SliverAppbar(
              leading: Tooltip(
                message: multiSelectMode ? "Cancel".tl : "Back".tl,
                child: IconButton(
                  onPressed: () {
                    if (multiSelectMode) {
                      setState(() {
                        multiSelectMode = false;
                        selectedComics.clear();
                      });
                    } else {
                      context.pop();
                    }
                  },
                  icon: multiSelectMode
                      ? const Icon(Icons.close)
                      : const Icon(Icons.arrow_back),
                ),
              ),
              title: multiSelectMode
                  ? Text(selectedComics.length.toString())
                  : Text("Local".tl),
              actions: multiSelectMode ? selectActions : normalActions,
            )
          else if (searchMode)
            SliverAppbar(
              leading: Tooltip(
                message: multiSelectMode ? "Cancel".tl : "Cancel".tl,
                child: IconButton(
                  icon: multiSelectMode
                      ? const Icon(Icons.close)
                      : const Icon(Icons.close),
                  onPressed: () {
                    if (multiSelectMode) {
                      setState(() {
                        multiSelectMode = false;
                        selectedComics.clear();
                      });
                    } else {
                      setState(() {
                        searchMode = false;
                        keyword = "";
                        update();
                      });
                    }
                  },
                ),
              ),
              title: multiSelectMode
                  ? Text(selectedComics.length.toString())
                  : TextField(
                      autofocus: true,
                      decoration: InputDecoration(
                        hintText: "Search".tl,
                        border: InputBorder.none,
                      ),
                      onChanged: (v) {
                        keyword = v;
                        update();
                      },
                    ),
              actions: multiSelectMode ? selectActions : null,
            ),
          SliverGridComics(
            comics: comics,
            selections: selectedComics,
            onLongPressed: (c, heroID) {
              setState(() {
                multiSelectMode = true;
                selectedComics[c as LocalComic] = true;
              });
            },
            onTap: (c, heroID) {
              if (multiSelectMode) {
                setState(() {
                  if (selectedComics.containsKey(c as LocalComic)) {
                    selectedComics.remove(c);
                  } else {
                    selectedComics[c] = true;
                  }
                  if (selectedComics.isEmpty) {
                    multiSelectMode = false;
                  }
                });
              } else {
                // prevent dirty data
                var comic = LocalManager().find(
                  c.id,
                  ComicType.fromKey(c.sourceKey),
                )!;
                context.to(
                  () => ComicPage(id: comic.id, sourceKey: comic.sourceKey),
                );
              }
            },
            menuBuilder: (c) {
              return [
                MenuEntry(
                  icon: Icons.verified_outlined,
                  text: "Verify".tl,
                  onClick: () {
                    validateComics([c as LocalComic]);
                  },
                ),
                MenuEntry(
                  icon: Icons.folder_open,
                  text: "Open Folder".tl,
                  onClick: () {
                    openComicFolder(c as LocalComic);
                  },
                ),
                MenuEntry(
                  icon: Icons.delete,
                  text: "Delete".tl,
                  onClick: () {
                    deleteComics([c as LocalComic]).then((value) {
                      if (value && multiSelectMode) {
                        setState(() {
                          multiSelectMode = false;
                          selectedComics.clear();
                        });
                      }
                    });
                  },
                ),
                ...exportActions([c as LocalComic]),
              ];
            },
          ),
        ],
      ),
    );

    return PopScope(
      canPop: !multiSelectMode && !searchMode,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (multiSelectMode) {
          setState(() {
            multiSelectMode = false;
            selectedComics.clear();
          });
        } else if (searchMode) {
          setState(() {
            searchMode = false;
            keyword = "";
            update();
          });
        }
      },
      child: body,
    );
  }

  Future<void> validateComics(List<LocalComic> targetComics) async {
    if (targetComics.isEmpty) {
      return;
    }
    var loadingDialog = showLoadingDialog(
      App.rootContext,
      barrierDismissible: false,
      allowCancel: false,
      withProgress: true,
      message: "Validate Local Comics".tl,
    );
    try {
      final checkTitle = appdata.settings['validateLocalByUrlTitle'] == true;
      final preview = await LocalManager().validateAndRepairLocalComics(
        repair: false,
        checkTitleFromUrl: checkTitle,
        checkBrokenImages: false,
        targetComics: targetComics,
        onProgress: (progress) {
          _updateValidationProgress(loadingDialog, progress);
        },
      );
      loadingDialog.close();

      if (preview.invalid == 0) {
        if (preview.messages.isNotEmpty && preview.checked == 0) {
          context.showMessage(message: preview.messages.first);
          return;
        }
        context.showMessage(
          message:
              'Checked: @checked/@total, all valid.'.tlParams({
                'checked': preview.checked,
                'total': preview.total,
              }) +
              _validationDuplicateSummary(preview),
        );
        return;
      }

      bool confirmed = false;
      await showDialog(
        context: context,
        builder: (context) {
          final lines = preview.issues
              .take(30)
              .map((e) => '- ${e.comic.title} (${e.reason.tl})')
              .join('\n');
          final extra = preview.issues.length > 30
              ? '\n${'...and @count more'.tlParams({'count': preview.issues.length - 30})}'
              : '';
          return ContentDialog(
            title: 'Confirm Repair'.tl,
            content: SingleChildScrollView(
              child: Text(
                '${'Found @count invalid comics.'.tlParams({'count': preview.invalid})}\n\n$lines$extra\n\n${'Start auto-repair (max @times retries each)?'.tlParams({'times': 3})}',
              ),
            ).paddingHorizontal(16),
            actions: [
              Button.text(
                onPressed: () => context.pop(),
                child: Text('Cancel'.tl),
              ),
              Button.filled(
                onPressed: () {
                  confirmed = true;
                  context.pop();
                },
                child: Text('Confirm'.tl),
              ),
            ],
          );
        },
      );

      if (!confirmed) {
        context.showMessage(message: 'Repair cancelled'.tl);
        return;
      }

      loadingDialog = showLoadingDialog(
        App.rootContext,
        barrierDismissible: false,
        allowCancel: false,
        withProgress: true,
        message: "Validate Local Comics".tl,
      );
      final report = await LocalManager().validateAndRepairLocalComics(
        repair: true,
        checkTitleFromUrl: checkTitle,
        checkBrokenImages: false,
        targetComics: targetComics,
        issues: preview.issues,
        onProgress: (progress) {
          _updateValidationProgress(loadingDialog, progress);
        },
      );
      context.showMessage(
        message:
            'Invalid: @invalid, Repaired: @repaired, Failed: @failed, Skipped: @skipped'
                .tlParams({
                  'invalid': preview.invalid,
                  'repaired': report.repaired,
                  'failed': report.failed,
                  'skipped': report.skipped,
                }) +
            _validationDuplicateSummary(preview),
      );
      if (report.messages.isNotEmpty) {
        Log.error('Local Validation', report.messages.take(50).join('\n'));
      }
    } catch (e, s) {
      Log.error('Local Validation', e.toString(), s);
      context.showMessage(message: e.toString());
    } finally {
      loadingDialog.close();
    }
  }

  Future<bool> deleteComics(List<LocalComic> comics) async {
    bool isDeleted = false;
    await showDialog(
      context: App.rootContext,
      builder: (context) {
        bool removeComicFile = true;
        bool removeFavoriteAndHistory = true;
        return StatefulBuilder(
          builder: (context, state) {
            return ContentDialog(
              title: "Delete".tl,
              content: Column(
                children: [
                  CheckboxListTile(
                    title: Text("Remove local favorite and history".tl),
                    value: removeFavoriteAndHistory,
                    onChanged: (v) {
                      state(() {
                        removeFavoriteAndHistory = !removeFavoriteAndHistory;
                      });
                    },
                  ),
                  CheckboxListTile(
                    title: Text("Also remove files on disk".tl),
                    value: removeComicFile,
                    onChanged: (v) {
                      state(() {
                        removeComicFile = !removeComicFile;
                      });
                    },
                  ),
                ],
              ),
              actions: [
                if (comics.length == 1 && comics.first.hasChapters)
                  TextButton(
                    child: Text("Delete Chapters".tl),
                    onPressed: () {
                      context.pop();
                      showDeleteChaptersPopWindow(context, comics.first);
                    },
                  ),
                FilledButton(
                  onPressed: () {
                    context.pop();
                    LocalManager().batchDeleteComics(
                      comics,
                      removeComicFile,
                      removeFavoriteAndHistory,
                    );
                    isDeleted = true;
                  },
                  child: Text("Confirm".tl),
                ),
              ],
            );
          },
        );
      },
    );
    return isDeleted;
  }

  List<MenuEntry> exportActions(List<LocalComic> comics) {
    return [
      MenuEntry(
        icon: Icons.outbox_outlined,
        text: "Export as cbz".tl,
        onClick: () {
          exportComics(comics, CBZ.export, ".cbz");
        },
      ),
      MenuEntry(
        icon: Icons.picture_as_pdf_outlined,
        text: "Export as pdf".tl,
        onClick: () async {
          exportComics(comics, createPdfFromComicIsolate, ".pdf");
        },
      ),
      MenuEntry(
        icon: Icons.import_contacts_outlined,
        text: "Export as epub".tl,
        onClick: () async {
          exportComics(comics, createEpubWithLocalComic, ".epub");
        },
      ),
    ];
  }

  /// Export given comics to a file
  void exportComics(
    List<LocalComic> comics,
    ExportComicFunc export,
    String ext,
  ) async {
    var current = 0;
    var cacheDir = FilePath.join(App.cachePath, 'comics_export');
    var outFile = FilePath.join(App.cachePath, 'comics_export.zip');
    bool canceled = false;
    if (Directory(cacheDir).existsSync()) {
      Directory(cacheDir).deleteSync(recursive: true);
    }
    Directory(cacheDir).createSync();
    var loadingController = showLoadingDialog(
      context,
      allowCancel: true,
      message: "${"Exporting".tl} $current/${comics.length}",
      withProgress: comics.length > 1,
      onCancel: () {
        canceled = true;
      },
    );
    try {
      var fileName = "";
      // For each comic, export it to a file
      for (var comic in comics) {
        fileName = FilePath.join(
          cacheDir,
          sanitizeFileName(comic.title, maxLength: 100) + ext,
        );
        await export(comic, fileName);
        current++;
        if (comics.length > 1) {
          loadingController.setMessage(
            "${"Exporting".tl} $current/${comics.length}",
          );
          loadingController.setProgress(current / comics.length);
        }
        if (canceled) {
          return;
        }
      }
      // For single comic, just save the file
      if (comics.length == 1) {
        await saveFile(file: File(fileName), filename: File(fileName).name);
        Directory(cacheDir).deleteSync(recursive: true);
        loadingController.close();
        return;
      }
      // For multiple comics, compress the folder
      loadingController.setProgress(null);
      loadingController.setMessage("Compressing".tl);
      await ZipFile.compressFolderAsync(cacheDir, outFile);
      if (canceled) {
        File(outFile).deleteIgnoreError();
        return;
      }
    } catch (e, s) {
      Log.error("Export Comics", e, s);
      context.showMessage(message: e.toString());
      loadingController.close();
      return;
    } finally {
      Directory(cacheDir).deleteIgnoreError(recursive: true);
    }
    await saveFile(file: File(outFile), filename: "comics_export.zip");
    loadingController.close();
    File(outFile).deleteIgnoreError();
  }
}

typedef ExportComicFunc =
    Future<File> Function(LocalComic comic, String outFilePath);

/// Opens the folder containing the comic in the system file explorer
Future<void> openComicFolder(LocalComic comic) async {
  try {
    final folderPath = comic.baseDir;

    if (App.isWindows) {
      await Process.run('explorer', [folderPath]);
    } else if (App.isMacOS) {
      await Process.run('open', [folderPath]);
    } else if (App.isLinux) {
      // Try different file managers commonly found on Linux
      try {
        await Process.run('xdg-open', [folderPath]);
      } catch (e) {
        // Fallback to other common file managers
        try {
          await Process.run('nautilus', [folderPath]);
        } catch (e) {
          try {
            await Process.run('dolphin', [folderPath]);
          } catch (e) {
            try {
              await Process.run('thunar', [folderPath]);
            } catch (e) {
              // Last resort: use the URL launcher with file:// protocol
              await launchUrlString('file://$folderPath');
            }
          }
        }
      }
    } else {
      // For mobile platforms, use the URL launcher with file:// protocol
      await launchUrlString('file://$folderPath');
    }
  } catch (e, s) {
    Log.error("Open Folder", "Failed to open comic folder: $e", s);
    // Show error message to user
    if (App.rootContext.mounted) {
      App.rootContext.showMessage(message: "Failed to open folder: $e");
    }
  }
}

void showDeleteChaptersPopWindow(BuildContext context, LocalComic comic) {
  var chapters = <String>[];

  showPopUpWidget(
    context,
    PopUpWidgetScaffold(
      title: "Delete Chapters".tl,
      body: StatefulBuilder(
        builder: (context, setState) {
          return Column(
            children: [
              Expanded(
                child: ListView.builder(
                  itemCount: comic.downloadedChapters.length,
                  itemBuilder: (context, index) {
                    var id = comic.downloadedChapters[index];
                    var chapter = comic.chapters![id] ?? "Unknown Chapter";
                    return CheckboxListTile(
                      title: Text(chapter),
                      value: chapters.contains(id),
                      onChanged: (v) {
                        setState(() {
                          if (v == true) {
                            chapters.add(id);
                          } else {
                            chapters.remove(id);
                          }
                        });
                      },
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    FilledButton(
                      onPressed: () {
                        Future.delayed(const Duration(milliseconds: 200), () {
                          LocalManager().deleteComicChapters(comic, chapters);
                        });
                        App.rootContext.pop();
                      },
                      child: Text("Submit".tl),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
}
