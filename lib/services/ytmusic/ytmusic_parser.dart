// ytmusic_parser.dart
//
// Pure-Dart parsing of YouTube Music (InnerTube) JSON responses.
// No Flutter, no HTTP, no app imports — it only turns decoded JSON into small
// data classes, so it is easy to unit-test with saved responses.
//
// The response layout changes now and then, so lookups are defensive: every
// access is null-safe and we search for renderers instead of hard-coding long
// paths wherever the position on the page does not matter.

/// One track as listed on a YouTube Music page.
class YtTrack {
  final String videoId;
  final String title;
  final List<String> artists;
  final String? album;
  final int? durationMs;
  final String? thumbnailUrl;
  final bool isExplicit;

  const YtTrack({
    required this.videoId,
    required this.title,
    required this.artists,
    this.album,
    this.durationMs,
    this.thumbnailUrl,
    this.isExplicit = false,
  });

  @override
  String toString() => 'YtTrack($videoId, $title — ${artists.join(', ')})';
}

/// A playlist-like entry from the user's library (or a built-in source).
class YtCollection {
  /// Browse id used to open it, e.g. `VLPLxxxx`, `VLLM`, `FEmusic_liked_videos`.
  final String browseId;
  final String title;
  final String? subtitle;
  final String? thumbnailUrl;

  const YtCollection({
    required this.browseId,
    required this.title,
    this.subtitle,
    this.thumbnailUrl,
  });

  @override
  String toString() => 'YtCollection($browseId, $title)';
}

/// One page of results plus the token for the next page (null when done).
class YtPage<T> {
  final List<T> items;
  final String? continuation;

  const YtPage({required this.items, this.continuation});
}

class YtMusicParser {
  const YtMusicParser._();

  // ── Public API ───────────────────────────────────────────────────────────

  /// Parses a page of tracks (a playlist page, the liked-songs page, the
  /// library songs page, or any continuation of those).
  static YtPage<YtTrack> parseTrackPage(Map<String, dynamic> response) {
    List<dynamic> contents = const [];
    String? token;

    // Prefer the playlist shelf: playlist pages also carry "suggestions"
    // shelves further down that must not be imported as part of the playlist.
    final Map? shelf = _findFirst(response, const {
          'musicPlaylistShelfContinuation',
          'musicPlaylistShelfRenderer',
        }) ??
        _findFirst(response, const {
          'musicShelfContinuation',
          'musicShelfRenderer',
        });

    if (shelf != null) {
      final c = shelf['contents'];
      if (c is List) contents = c;
      token = _tokenFromContinuations(shelf['continuations']);
    } else {
      // Newer continuation format.
      final Map? action =
          _findFirst(response, const {'appendContinuationItemsAction'});
      final c = action?['continuationItems'];
      if (c is List) contents = c;
    }
    token ??= _tokenFromItems(contents);

    final tracks = <YtTrack>[];
    for (final item in contents) {
      if (item is! Map) continue;
      final r = item['musicResponsiveListItemRenderer'];
      if (r is! Map) continue;
      final track = _parseTrack(r);
      if (track != null) tracks.add(track);
    }
    return YtPage<YtTrack>(items: tracks, continuation: token);
  }

  /// Parses a page of library playlists (`FEmusic_liked_playlists`).
  static YtPage<YtCollection> parseCollectionPage(
      Map<String, dynamic> response) {
    final out = <YtCollection>[];
    final renderers = <Map>[];
    _collectAll(response, 'musicTwoRowItemRenderer', renderers);

    for (final r in renderers) {
      final browseId = _asString(
          _dig(r, ['navigationEndpoint', 'browseEndpoint', 'browseId']));
      // Real playlists open with a "VL" browse id. This skips the
      // "New playlist" tile and any albums/artists that sneak in.
      if (browseId == null || !browseId.startsWith('VL')) continue;
      // The built-in liked-songs playlist is offered separately.
      if (browseId == 'VLLM') continue;

      final title = _joinRuns(_dig(r, ['title', 'runs']));
      if (title.isEmpty) continue;

      out.add(YtCollection(
        browseId: browseId,
        title: title,
        subtitle: _nullIfEmpty(_joinRuns(_dig(r, ['subtitle', 'runs']))),
        thumbnailUrl: _lastThumbnail(_dig(r, [
          'thumbnailRenderer',
          'musicThumbnailRenderer',
          'thumbnail',
          'thumbnails',
        ])),
      ));
    }

    String? token = _findFirst(response, const {'nextContinuationData'})?[
        'continuation'] as String?;
    token ??= _asString(_dig(
        _findFirst(response, const {'continuationItemRenderer'}),
        ['continuationEndpoint', 'continuationCommand', 'token']));

    return YtPage<YtCollection>(items: out, continuation: token);
  }

  /// "3:45" -> 225000, "1:02:03" -> 3723000. Null if not a duration.
  static int? parseDurationMs(String? text) {
    if (text == null) return null;
    final t = text.trim();
    if (!RegExp(r'^\d+(:\d{1,2}){1,2}$').hasMatch(t)) return null;
    final parts = t.split(':').map(int.parse).toList();
    var seconds = 0;
    for (final p in parts) {
      seconds = seconds * 60 + p;
    }
    return seconds * 1000;
  }

  // ── Track parsing ────────────────────────────────────────────────────────

  static YtTrack? _parseTrack(Map r) {
    final flex = r['flexColumns'];

    List<Map> runsOf(int column) {
      final runs = _dig(flex, [
        column,
        'musicResponsiveListItemFlexColumnRenderer',
        'text',
        'runs',
      ]);
      if (runs is! List) return const [];
      return runs.whereType<Map>().toList(growable: false);
    }

    final titleRuns = runsOf(0);

    // Video id: playlistItemData is the most reliable; fall back to the play
    // overlay and then to the title link.
    final String? videoId = _asString(_dig(r, ['playlistItemData', 'videoId'])) ??
        _asString(_dig(r, [
          'overlay',
          'musicItemThumbnailOverlayRenderer',
          'content',
          'musicPlayButtonRenderer',
          'playNavigationEndpoint',
          'watchEndpoint',
          'videoId',
        ])) ??
        (titleRuns.isEmpty
            ? null
            : _asString(_dig(
                titleRuns.first, ['navigationEndpoint', 'watchEndpoint', 'videoId'])));
    if (videoId == null) return null; // unavailable / removed entries

    final title = titleRuns.map((e) => _asString(e['text']) ?? '').join().trim();
    if (title.isEmpty) return null;

    final artists = <String>[];
    String? album;
    final columnCount = flex is List ? flex.length : 0;
    for (var i = 1; i < columnCount; i++) {
      for (final run in runsOf(i)) {
        final text = _asString(run['text'])?.trim();
        if (text == null || text.isEmpty) continue;
        final pageType = _asString(_dig(run, [
          'navigationEndpoint',
          'browseEndpoint',
          'browseEndpointContextSupportedConfigs',
          'browseEndpointContextMusicConfig',
          'pageType',
        ]));
        if (pageType == 'MUSIC_PAGE_TYPE_ARTIST' ||
            pageType == 'MUSIC_PAGE_TYPE_USER_CHANNEL') {
          if (!artists.contains(text)) artists.add(text);
        } else if (pageType == 'MUSIC_PAGE_TYPE_ALBUM') {
          album ??= text;
        }
      }
    }

    // Fallback when the artist runs carry no navigation info: take the first
    // meaningful text of the second column.
    if (artists.isEmpty && columnCount > 1) {
      for (final run in runsOf(1)) {
        final text = _asString(run['text'])?.trim();
        if (text == null || text.isEmpty) continue;
        if (_isSeparator(text) || parseDurationMs(text) != null) continue;
        artists.add(text);
        break;
      }
    }

    // Duration: fixed column first, then any "m:ss" run in the other columns.
    int? durationMs = parseDurationMs(_asString(_dig(r, [
      'fixedColumns',
      0,
      'musicResponsiveListItemFixedColumnRenderer',
      'text',
      'runs',
      0,
      'text',
    ])));
    if (durationMs == null) {
      for (var i = 1; i < columnCount && durationMs == null; i++) {
        for (final run in runsOf(i)) {
          durationMs = parseDurationMs(_asString(run['text']));
          if (durationMs != null) break;
        }
      }
    }

    var explicit = false;
    final badges = r['badges'];
    if (badges is List) {
      for (final b in badges) {
        if (_asString(_dig(b, ['musicInlineBadgeRenderer', 'icon', 'iconType'])) ==
            'MUSIC_EXPLICIT_BADGE') {
          explicit = true;
          break;
        }
      }
    }

    return YtTrack(
      videoId: videoId,
      title: title,
      artists: artists,
      album: album,
      durationMs: durationMs,
      thumbnailUrl: _lastThumbnail(_dig(r, [
        'thumbnail',
        'musicThumbnailRenderer',
        'thumbnail',
        'thumbnails',
      ])),
      isExplicit: explicit,
    );
  }

  // ── Continuation tokens ──────────────────────────────────────────────────

  static String? _tokenFromContinuations(dynamic continuations) {
    if (continuations is! List) return null;
    for (final c in continuations) {
      final token = _asString(_dig(c, ['nextContinuationData', 'continuation'])) ??
          _asString(_dig(c, ['reloadContinuationData', 'continuation']));
      if (token != null) return token;
    }
    return null;
  }

  static String? _tokenFromItems(List<dynamic> contents) {
    for (final item in contents) {
      final token = _asString(_dig(item, [
        'continuationItemRenderer',
        'continuationEndpoint',
        'continuationCommand',
        'token',
      ]));
      if (token != null) return token;
    }
    return null;
  }

  // ── Generic JSON helpers ─────────────────────────────────────────────────

  /// Walks [path] through nested maps/lists; null if any step is missing.
  static dynamic _dig(dynamic node, List<Object> path) {
    dynamic cur = node;
    for (final key in path) {
      if (key is int) {
        if (cur is List && key >= 0 && key < cur.length) {
          cur = cur[key];
        } else {
          return null;
        }
      } else {
        if (cur is Map) {
          cur = cur[key];
        } else {
          return null;
        }
      }
    }
    return cur;
  }

  /// Depth-first, document-order search for the first map stored under any of
  /// [keys].
  static Map? _findFirst(dynamic node, Set<String> keys) {
    if (node is Map) {
      for (final entry in node.entries) {
        if (keys.contains(entry.key) && entry.value is Map) {
          return entry.value as Map;
        }
        final found = _findFirst(entry.value, keys);
        if (found != null) return found;
      }
    } else if (node is List) {
      for (final element in node) {
        final found = _findFirst(element, keys);
        if (found != null) return found;
      }
    }
    return null;
  }

  /// Collects every map stored under [key], anywhere in the tree.
  static void _collectAll(dynamic node, String key, List<Map> out) {
    if (node is Map) {
      for (final entry in node.entries) {
        if (entry.key == key && entry.value is Map) {
          out.add(entry.value as Map);
        } else {
          _collectAll(entry.value, key, out);
        }
      }
    } else if (node is List) {
      for (final element in node) {
        _collectAll(element, key, out);
      }
    }
  }

  static String? _asString(dynamic v) => v is String ? v : null;

  static String? _nullIfEmpty(String s) => s.trim().isEmpty ? null : s.trim();

  static String _joinRuns(dynamic runs) {
    if (runs is! List) return '';
    return runs
        .whereType<Map>()
        .map((e) => _asString(e['text']) ?? '')
        .join()
        .trim();
  }

  static String? _lastThumbnail(dynamic thumbnails) {
    if (thumbnails is! List || thumbnails.isEmpty) return null;
    final last = thumbnails.last;
    return last is Map ? _asString(last['url']) : null;
  }

  static bool _isSeparator(String text) {
    const separators = {'•', '·', '&', ',', '-', '–', '—'};
    return separators.contains(text.trim());
  }
}
