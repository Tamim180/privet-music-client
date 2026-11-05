// ytmusic_import.dart
//
// "Import from YouTube Music (cookie sync)" flow.
//
//   cookie file -> YtMusicClient -> pick liked songs / library / a playlist
//   -> fetch tracks -> ContentImportCubit.loadFromM3U (the existing pipeline)
//   -> import process screen (match against your plugins, review, save).
//
// Re-running it for the same source merges into the playlist of the same name
// (PlaylistDAO.ensurePlaylist matches by name and track insertion de-duplicates),
// so it doubles as a one-way "sync from YouTube Music".

import 'dart:developer';

import 'package:Bloomee/core/constants/route_paths.dart';
import 'package:Bloomee/core/theme/app_theme.dart';
import 'package:Bloomee/plugins/blocs/import/content_import_cubit.dart';
import 'package:Bloomee/screens/widgets/snackbar.dart';
import 'package:Bloomee/services/ytmusic/ytmusic_client.dart';
import 'package:Bloomee/services/ytmusic/ytmusic_parser.dart';
import 'package:Bloomee/src/rust/api/plugin/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

Future<void> startYtMusicImport(BuildContext context) async {
  final cubit = context.read<ContentImportCubit>();
  final router = GoRouter.of(context);

  SnackbarService.showMessage('Contacting YouTube Music…');

  YtMusicClient? client;
  List<YtCollection>? playlists;
  try {
    client = await YtMusicClient.fromCookieFile();
    playlists = await client.fetchLibraryPlaylists();
  } on YtMusicSetupException catch (e) {
    if (context.mounted) await _showSetupDialog(context, e.message);
    return;
  } on YtMusicRequestException catch (e) {
    SnackbarService.showMessage('YouTube Music: ${e.message}',
        duration: const Duration(seconds: 6));
    return;
  } catch (e, st) {
    log('YT Music playlist fetch failed: $e',
        name: 'YtMusicImport', error: e, stackTrace: st);
    SnackbarService.showMessage('YouTube Music sync failed: $e',
        duration: const Duration(seconds: 6));
    return;
  }
  if (client == null || playlists == null) return;
  if (!context.mounted) return;

  final choice = await _pickSource(context, playlists);
  if (choice == null) return;

  SnackbarService.showMessage(
    'Fetching “${choice.title}”…',
    loading: true,
    duration: const Duration(seconds: 30),
  );

  final List<YtTrack> tracks;
  try {
    tracks = await client.fetchTracks(choice.browseId);
  } on YtMusicRequestException catch (e) {
    SnackbarService.showMessage('YouTube Music: ${e.message}',
        duration: const Duration(seconds: 6));
    return;
  } catch (e, st) {
    log('YT Music track fetch failed: $e',
        name: 'YtMusicImport', error: e, stackTrace: st);
    SnackbarService.showMessage('Fetching tracks failed: $e',
        duration: const Duration(seconds: 6));
    return;
  } finally {
    client.close();
  }

  if (tracks.isEmpty) {
    SnackbarService.showMessage(
      'No tracks came back for “${choice.title}”. If it is not empty, your '
      'cookies may be expired.',
      duration: const Duration(seconds: 6),
    );
    return;
  }

  final items = tracks
      .map((t) => ImportTrackItem(
            title: t.title,
            artists: t.artists,
            albumTitle: t.album,
            thumbnailUrl: t.thumbnailUrl,
            durationMs: t.durationMs != null ? BigInt.from(t.durationMs!) : null,
            isExplicit: t.isExplicit,
            url: 'https://music.youtube.com/watch?v=${t.videoId}',
            sourceId: t.videoId,
          ))
      .toList(growable: false);

  final summary = ImportCollectionSummary(
    title: choice.title,
    kind: ImportCollectionType.playlist,
    thumbnailUrl: choice.thumbnailUrl,
    trackCount: items.length,
  );

  // Starts matching against your installed plugins right away.
  cubit.loadFromM3U(items, summary);
  router.goNamed(
    RoutePaths.importProcess,
    queryParameters: {'pluginId': ''},
  );
}

// ── Source picker ──────────────────────────────────────────────────────────

Future<YtCollection?> _pickSource(
  BuildContext context,
  List<YtCollection> playlists,
) {
  final entries = <YtCollection>[
    YtMusicClient.likedSongs,
    YtMusicClient.librarySongs,
    ...playlists,
  ];

  return showDialog<YtCollection>(
    context: context,
    builder: (dialogCtx) => AlertDialog(
      backgroundColor: Default_Theme.themeColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
      contentPadding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      title: Text(
        'Import from YouTube Music',
        style: Default_Theme.primaryTextStyle.merge(
          const TextStyle(color: Default_Theme.primaryColor1, fontSize: 18),
        ),
      ),
      content: SizedBox(
        width: 420,
        height: 440,
        child: ListView.builder(
          itemCount: entries.length,
          itemBuilder: (_, i) {
            final e = entries[i];
            final isBuiltIn = i < 2;
            return ListTile(
              leading: Icon(
                isBuiltIn ? Icons.favorite_rounded : Icons.queue_music_rounded,
                color: Default_Theme.accentColor2,
              ),
              title: Text(
                e.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Default_Theme.primaryColor1,
                  fontWeight: FontWeight.w600,
                ),
              ),
              subtitle: e.subtitle == null
                  ? null
                  : Text(
                      e.subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Default_Theme.primaryColor2
                            .withValues(alpha: 0.7),
                      ),
                    ),
              onTap: () => Navigator.of(dialogCtx).pop(e),
            );
          },
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogCtx).pop(),
          child: Text(
            'Cancel',
            style: TextStyle(color: Default_Theme.primaryColor2),
          ),
        ),
      ],
    ),
  );
}

// ── Setup help ─────────────────────────────────────────────────────────────

Future<void> _showSetupDialog(BuildContext context, String problem) {
  final path = YtMusicCredentials.defaultPath();
  return showDialog<void>(
    context: context,
    builder: (dialogCtx) => AlertDialog(
      backgroundColor: Default_Theme.themeColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Text(
        'YouTube Music cookies needed',
        style: Default_Theme.primaryTextStyle.merge(
          const TextStyle(color: Default_Theme.primaryColor1, fontSize: 18),
        ),
      ),
      content: SingleChildScrollView(
        child: SelectableText(
          '$problem\n\n'
          'Setup:\n'
          '1. Log in to music.youtube.com in your browser.\n'
          '2. Open dev tools (F12) → Network, reload, click a "browse" request.\n'
          '3. Copy the value of the "cookie" request header.\n'
          '4. Save it as the only line of:\n$path\n'
          '5. chmod 600 that file, then try again.\n\n'
          'A Netscape cookies.txt export also works.',
          style: TextStyle(
            color: Default_Theme.primaryColor2.withValues(alpha: 0.9),
            fontSize: 14,
            height: 1.5,
          ),
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(dialogCtx).pop(),
          style: FilledButton.styleFrom(
            backgroundColor: Default_Theme.accentColor2,
            foregroundColor: Colors.white,
          ),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}
