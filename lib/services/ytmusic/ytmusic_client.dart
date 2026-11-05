// ytmusic_client.dart
//
// Minimal read-only YouTube Music client for a personal setup.
//
// Instead of a login screen it reads your browser cookies from a text file and
// signs requests the same way the web player does (cookie + SAPISIDHASH).
//
// Cookie file location (outside the repo, so it can never be committed):
//   $BLOOMEE_YTMUSIC_COOKIE            (if set, full path)
//   $XDG_CONFIG_HOME/bloomee/ytmusic_cookie.txt
//   ~/.config/bloomee/ytmusic_cookie.txt
//
// Accepted file contents (any one of these):
//   1. A raw Cookie header value:    SID=...; HSID=...; SAPISID=...; ...
//   2. The same prefixed with        Cookie: 
//   3. A Netscape cookies.txt export (tab separated, from a browser extension)
// Optional extra lines (not needed for reading, supported just in case):
//   visitor_data: <VISITOR_DATA from music.youtube.com>
//   data_sync_id: <DATASYNC_ID from music.youtube.com>
//   auth_user: 0                       (index of the Google account, default 0)
// Lines starting with # are ignored.

import 'dart:convert';
import 'dart:io';

import 'package:Bloomee/services/ytmusic/ytmusic_parser.dart';
import 'package:crypto/crypto.dart' show sha1;
import 'package:http/http.dart' as http;

/// The cookie file is missing, unreadable, or lacks the required cookies.
class YtMusicSetupException implements Exception {
  final String message;
  const YtMusicSetupException(this.message);

  @override
  String toString() => message;
}

/// YouTube answered with an error or something we could not understand.
class YtMusicRequestException implements Exception {
  final String message;
  const YtMusicRequestException(this.message);

  @override
  String toString() => message;
}

class YtMusicCredentials {
  /// All cookies by name.
  final Map<String, String> cookies;
  final String? visitorData;
  final String? dataSyncId;
  final String authUser;

  const YtMusicCredentials({
    required this.cookies,
    this.visitorData,
    this.dataSyncId,
    this.authUser = '0',
  });

  /// Cookie header value.
  String get cookieHeader =>
      cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');

  /// The cookie used to build the SAPISIDHASH signature.
  String? get sapisid => cookies['SAPISID'] ?? cookies['__Secure-3PAPISID'];

  /// Where the cookie file is expected.
  static String defaultPath() {
    final env = Platform.environment;
    final override = env['BLOOMEE_YTMUSIC_COOKIE'];
    if (override != null && override.trim().isNotEmpty) return override.trim();

    String? base = env['XDG_CONFIG_HOME'];
    if (base == null || base.isEmpty) {
      final home = env['HOME'];
      if (home != null && home.isNotEmpty) base = '$home/.config';
    }
    if ((base == null || base.isEmpty) && Platform.isWindows) {
      base = env['APPDATA'];
    }
    base ??= '.';
    return '$base/bloomee/ytmusic_cookie.txt';
  }

  static Future<YtMusicCredentials> loadFromFile([String? path]) async {
    final filePath = path ?? defaultPath();
    final file = File(filePath);
    if (!await file.exists()) {
      throw YtMusicSetupException('Cookie file not found:\n$filePath');
    }
    final String raw;
    try {
      raw = await file.readAsString();
    } catch (e) {
      throw YtMusicSetupException('Could not read the cookie file:\n$e');
    }
    return parse(raw);
  }

  static YtMusicCredentials parse(String raw) {
    final cookies = <String, String>{};
    String? visitorData;
    String? dataSyncId;
    var authUser = '0';

    for (final rawLine in raw.split(RegExp(r'\r?\n'))) {
      var line = rawLine.trim();
      if (line.isEmpty) continue;

      final lower = line.toLowerCase();

      // Optional extra values.
      final extra = RegExp(r'^(visitor_?data|data_?sync_?id|auth_?user)\s*[:=]\s*(.+)$',
              caseSensitive: false)
          .firstMatch(line);
      if (extra != null) {
        final key = extra.group(1)!.toLowerCase().replaceAll('_', '');
        final value = extra.group(2)!.trim();
        if (key == 'visitordata') {
          visitorData = value;
        } else if (key == 'datasyncid') {
          // The page reports "<id>||<other>"; only the first part is used.
          dataSyncId = value.split('||').first;
        } else {
          authUser = value;
        }
        continue;
      }

      // Netscape cookies.txt: 7 tab-separated fields.
      if (line.contains('\t')) {
        final parts = line.split('\t');
        if (parts.length >= 7) {
          final domain = parts[0].replaceFirst('#HttpOnly_', '').toLowerCase();
          if (domain.contains('youtube.com') || domain.contains('google.com')) {
            final name = parts[5].trim();
            if (name.isNotEmpty) cookies[name] = parts[6].trim();
          }
          continue;
        }
      }

      // Comments (but not "#HttpOnly_" Netscape lines handled above).
      if (line.startsWith('#')) continue;

      // Raw Cookie header, optionally prefixed with "Cookie:".
      if (lower.startsWith('cookie:')) line = line.substring(7).trim();
      for (final pair in line.split(';')) {
        final idx = pair.indexOf('=');
        if (idx <= 0) continue;
        final name = pair.substring(0, idx).trim();
        final value = pair.substring(idx + 1).trim();
        if (name.isNotEmpty) cookies[name] = value;
      }
    }

    final creds = YtMusicCredentials(
      cookies: cookies,
      visitorData: visitorData,
      dataSyncId: dataSyncId,
      authUser: authUser,
    );
    if (creds.sapisid == null) {
      throw const YtMusicSetupException(
        'The cookie file has no SAPISID cookie, so requests cannot be signed.\n'
        'Copy the cookies from a browser that is logged in to music.youtube.com.',
      );
    }
    return creds;
  }
}

class YtMusicClient {
  static const String _origin = 'https://music.youtube.com';
  static const String _clientName = 'WEB_REMIX';
  static const String _clientId = '67';

  /// Bump this if YouTube starts rejecting requests (copy the current value
  /// from a request in your browser's dev tools: context.client.clientVersion).
  static const String clientVersion = '1.20260213.01.00';

  static const String _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:140.0) Gecko/20100101 Firefox/140.0';

  /// Built-in sources offered next to the user's own playlists.
  static const YtCollection likedSongs =
      YtCollection(browseId: 'VLLM', title: 'Liked songs');
  static const YtCollection librarySongs =
      YtCollection(browseId: 'FEmusic_liked_videos', title: 'Library songs');

  final YtMusicCredentials credentials;
  final http.Client _http;

  YtMusicClient(this.credentials, {http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  static Future<YtMusicClient> fromCookieFile([String? path]) async {
    return YtMusicClient(await YtMusicCredentials.loadFromFile(path));
  }

  void close() => _http.close();

  // ── Public API ───────────────────────────────────────────────────────────

  /// The user's saved/created playlists.
  Future<List<YtCollection>> fetchLibraryPlaylists({int maxPages = 20}) async {
    final out = <YtCollection>[];
    final seenTokens = <String>{};
    String? continuation;
    var first = true;

    for (var page = 0; page < maxPages; page++) {
      final response = first
          ? await _browse(browseId: 'FEmusic_liked_playlists')
          : await _browse(continuation: continuation);
      first = false;

      final parsed = YtMusicParser.parseCollectionPage(response);
      out.addAll(parsed.items);

      continuation = parsed.continuation;
      if (continuation == null || !seenTokens.add(continuation)) break;
    }
    return out;
  }

  /// Every track of a playlist/library page, following continuations.
  ///
  /// [browseId] examples: `VLLM` (liked songs), `FEmusic_liked_videos`
  /// (library songs), `VLPL...` (a playlist).
  Future<List<YtTrack>> fetchTracks(
    String browseId, {
    int maxPages = 100,
    void Function(int loadedSoFar)? onProgress,
  }) async {
    final out = <YtTrack>[];
    final seenTokens = <String>{};
    String? continuation;
    var first = true;

    for (var page = 0; page < maxPages; page++) {
      final response = first
          ? await _browse(browseId: browseId)
          : await _browse(continuation: continuation);
      first = false;

      final parsed = YtMusicParser.parseTrackPage(response);
      out.addAll(parsed.items);
      onProgress?.call(out.length);

      continuation = parsed.continuation;
      if (continuation == null || !seenTokens.add(continuation)) break;
    }
    return out;
  }

  // ── Request plumbing ─────────────────────────────────────────────────────

  Map<String, String> _headers() {
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final hash =
        sha1.convert(utf8.encode('$ts ${credentials.sapisid} $_origin')).toString();

    return <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'User-Agent': _userAgent,
      'Accept-Language': 'en-US,en;q=0.9',
      'Cookie': credentials.cookieHeader,
      'Authorization': 'SAPISIDHASH ${ts}_$hash',
      'Origin': _origin,
      'Referer': '$_origin/',
      'X-Origin': _origin,
      'X-Goog-AuthUser': credentials.authUser,
      'X-Goog-Api-Format-Version': '1',
      'X-YouTube-Client-Name': _clientId,
      'X-YouTube-Client-Version': clientVersion,
      if (credentials.visitorData != null)
        'X-Goog-Visitor-Id': credentials.visitorData!,
    };
  }

  Map<String, dynamic> _body({String? browseId, String? continuation}) {
    return <String, dynamic>{
      'context': <String, dynamic>{
        'client': <String, dynamic>{
          'clientName': _clientName,
          'clientVersion': clientVersion,
          'hl': 'en',
          'gl': 'US',
          if (credentials.visitorData != null)
            'visitorData': credentials.visitorData,
        },
        'user': <String, dynamic>{
          if (credentials.dataSyncId != null)
            'onBehalfOfUser': credentials.dataSyncId,
        },
      },
      if (browseId != null) 'browseId': browseId,
      if (continuation != null) 'continuation': continuation,
    };
  }

  Future<Map<String, dynamic>> _browse({
    String? browseId,
    String? continuation,
  }) async {
    final uri = Uri.https('music.youtube.com', '/youtubei/v1/browse', {
      'prettyPrint': 'false',
    });

    final http.Response res;
    try {
      res = await _http
          .post(
            uri,
            headers: _headers(),
            body: jsonEncode(_body(browseId: browseId, continuation: continuation)),
          )
          .timeout(const Duration(seconds: 30));
    } on SocketException catch (e) {
      throw YtMusicRequestException('Network error: ${e.message}');
    }

    if (res.statusCode == 401 || res.statusCode == 403) {
      throw YtMusicRequestException(
        'YouTube rejected the cookies (HTTP ${res.statusCode}). They have '
        'probably expired — export them again from a logged-in browser.',
      );
    }
    if (res.statusCode != 200) {
      final body = utf8.decode(res.bodyBytes, allowMalformed: true);
      final snippet = body.length > 200 ? body.substring(0, 200) : body;
      throw YtMusicRequestException('HTTP ${res.statusCode}: $snippet');
    }

    final dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(res.bodyBytes));
    } catch (_) {
      throw const YtMusicRequestException(
          'YouTube returned something that is not JSON.');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const YtMusicRequestException('Unexpected response shape.');
    }
    return decoded;
  }
}
