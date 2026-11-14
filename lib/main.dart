import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'services.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final folder = await getApplicationSupportDirectory();
  await folder.create(recursive: true);
  runApp(
    MaterialApp(
      title: 'Playlist Offline',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme:
            ColorScheme.fromSeed(
              seedColor: const Color(0xffd7fb7e),
              brightness: Brightness.dark,
            ).copyWith(
              primary: const Color(0xffd7fb7e),
              onPrimary: const Color(0xff182208),
              surface: const Color(0xff181d18),
              onSurface: const Color(0xfff0f4eb),
              onSurfaceVariant: const Color(0xffb6c1b3),
            ),
        scaffoldBackgroundColor: const Color(0xff101410),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xff242c22),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
        ),
      ),
      home: Library(folder: folder),
    ),
  );
}

class Library extends StatefulWidget {
  const Library({super.key, required this.folder});
  final Directory folder;
  @override
  State<Library> createState() => _LibraryState();
}

class _LibraryState extends State<Library> {
  final player = AudioPlayer();
  final spotify = Spotify();
  static const spotifyClientId = String.fromEnvironment('SPOTIFY_CLIENT_ID');
  static const jamendoClientId = String.fromEnvironment('JAMENDO_CLIENT_ID');
  final client = TextEditingController(text: spotifyClientId);
  final jamendo = TextEditingController(text: jamendoClientId);
  final audius = TextEditingController();
  final link = TextEditingController();
  final soundCloudToken = TextEditingController();
  List<Playlist> searchResults = [];
  bool searchSoundCloud = false;
  SoundCloud get soundCloud => SoundCloud(soundCloudToken.text.trim());
  List<Playlist> playlists = [];
  final tracks = <Track>[];
  final saved = <String, String>{};
  final status = <String, String>{};
  String title = 'Offline library';
  String message = '';
  Track? playing;
  bool busy = false;

  File get index => File('${widget.folder.path}/library.json');
  File file(Track track, [String? extension]) {
    File withExtension(String extension) =>
        File('${widget.folder.path}/${track.id}.$extension');
    if (extension != null) return withExtension(extension);
    for (final format in ['mp3', 'wav', 'flac', 'm4a']) {
      final candidate = withExtension(format);
      if (candidate.existsSync()) return candidate;
    }
    return withExtension('mp3');
  }

  @override
  void initState() {
    super.initState();
    try {
      if (!index.existsSync()) return;
      final data = jsonDecode(index.readAsStringSync());
      title = data['title'];
      if (spotifyClientId.isEmpty)
        client.text = data['client'] as String? ?? '';
      if (jamendoClientId.isEmpty)
        jamendo.text = data['jamendo'] as String? ?? '';
      saved.addAll(Map<String, String>.from(data['saved']));
      tracks.addAll(
        (data['tracks'] as List).map((item) => Track.fromJson(item)),
      );
    } catch (_) {
      message = 'Could not read the saved library.';
    }
  }

  Future<void> save() async {
    final temporary = File('${index.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({
        'title': title,
        'client': client.text.trim(),
        'jamendo': jamendo.text.trim(),
        'tracks': tracks.map((track) => track.toJson()).toList(),
        'saved': saved,
      }),
      flush: true,
    );
    await temporary.rename(index.path);
  }

  Future<void> run(Future<void> Function() work) async {
    if (busy) return;
    setState(() {
      busy = true;
      message = '';
    });
    try {
      await work();
    } catch (error) {
      message = error.toString().replaceFirst('Exception: ', '');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> load(Playlist playlist) async {
    final imported = playlist.isSoundCloud
        ? await soundCloud.tracks(playlist.id)
        : await loadSpotifyTracks(playlist.id);
    final retained = tracks.where((track) => file(track).existsSync()).toList();
    final ids = imported.map((track) => track.id).toSet();
    tracks
      ..clear()
      ..addAll(imported)
      ..addAll(retained.where((track) => !ids.contains(track.id)));
    title = playlist.name;
    status.clear();
    await save();
  }

  Future<void> download(Track track) async {
    if (file(track).existsSync()) return;
    setState(() => status[track.id] = 'Searching…');
    try {
      final source = await Catalogs(
        jamendo.text.trim(),
        audius.text.trim(),
      ).download(track, (extension) => file(track, extension));
      if (source == null) {
        status[track.id] = 'No downloadable match';
      } else {
        saved[track.id] = source;
        await save();
      }
    } catch (error) {
      status[track.id] = error.toString().replaceFirst('Exception: ', '');
    }
    if (mounted) setState(() {});
  }

  Future<void> importFiles() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['mp3'],
    );
    for (final item in result) {
      final path = item.path;
      if (path == null) continue;
      final track = Track(
        'local-${DateTime.now().microsecondsSinceEpoch}',
        item.name,
        'Local file',
        0,
        '',
      );
      final temporary = await File(path).copy('${file(track).path}.part');
      await temporary.rename(file(track).path);
      tracks.add(track);
      saved[track.id] = 'Local file';
      await save();
    }
  }

  Future<void> play(Track track) async {
    await player.play(DeviceFileSource(file(track).path));
    if (mounted) setState(() => playing = track);
  }

  @override
  void dispose() {
    player.dispose();
    client.dispose();
    jamendo.dispose();
    audius.dispose();
    link.dispose();
    soundCloudToken.dispose();
    super.dispose();
  }

  Widget reveal(Widget child, {int delay = 0}) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    return child
        .animate(delay: delay.ms)
        .fadeIn(duration: 320.ms, curve: Curves.easeOut)
        .slideY(begin: .08, end: 0, curve: Curves.easeOutCubic);
  }

  Future<void> connect() async {
    if (client.text.trim().isEmpty) {
      throw Exception('Enter your Spotify client ID in Service setup.');
    }
    await spotify.connect(
      client.text.trim(),
      (url) => launchUrl(url, mode: LaunchMode.externalApplication),
    );
    playlists = await spotify.playlists();
    await save();
  }

  Future<List<Track>> loadSpotifyTracks(String id) async {
    try {
      return await spotify.tracks(id);
    } catch (error) {
      if (error.toString().contains('HTTP 403')) {
        throw Exception(
          'Spotify only allows track imports for playlists you own or collaborate on. You can still open this playlist in Spotify.',
        );
      }
      rethrow;
    }
  }

  Future<void> searchPlaylists() async {
    final query = link.text.trim();
    if (query.isEmpty) throw Exception('Enter a playlist name to search.');
    if (Uri.tryParse(query)?.host == 'open.spotify.com') {
      await load(await spotify.fromLink(query));
      return;
    }
    searchResults = [];
    searchResults = await (searchSoundCloud
        ? soundCloud.search(query)
        : spotify.search(query));
    if (searchResults.isEmpty) message = 'No public playlists found.';
  }

  void showSettings() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            24,
            0,
            24,
            24 + MediaQuery.viewInsetsOf(sheetContext).bottom,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Service setup',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 18),
              TextField(
                controller: client,
                readOnly: spotifyClientId.isNotEmpty,
                decoration: const InputDecoration(
                  labelText: 'Spotify client ID',
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: SelectableText(Spotify.redirect),
              ),
              TextField(
                controller: jamendo,
                readOnly: jamendoClientId.isNotEmpty,
                decoration: const InputDecoration(
                  labelText: 'Jamendo client ID',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: audius,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Audius API key (optional)',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: soundCloudToken,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'SoundCloud access token (session only)',
                ),
              ),
              const SizedBox(height: 18),
              FilledButton(
                onPressed: () {
                  Navigator.pop(sheetContext);
                  run(save);
                },
                child: const Text('Save settings'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final offline = tracks.where((track) => file(track).existsSync()).length;
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      bottomNavigationBar: playing == null ? null : playerBar(colors),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 790),
            child: CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(22, 12, 22, 14),
                  sliver: SliverList.list(
                    children: [
                      Row(
                        children: [
                          const Icon(
                            Icons.graphic_eq_rounded,
                            color: Color(0xffd7fb7e),
                            size: 28,
                          ),
                          const SizedBox(width: 10),
                          const Expanded(
                            child: Text(
                              'Playlist Offline',
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w700,
                                letterSpacing: -.6,
                              ),
                            ),
                          ),
                          IconButton.filledTonal(
                            tooltip: 'Service setup',
                            onPressed: busy ? null : showSettings,
                            icon: const Icon(Icons.tune_rounded),
                          ),
                        ],
                      ),
                      const SizedBox(height: 22),
                      reveal(libraryCard(offline), delay: 35),
                      const SizedBox(height: 16),
                      reveal(importCard(), delay: 95),
                      if (busy)
                        const Padding(
                          padding: EdgeInsets.only(top: 14),
                          child: LinearProgressIndicator(
                            borderRadius: BorderRadius.all(Radius.circular(6)),
                          ),
                        ),
                      if (message.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: SelectableText(
                            message,
                            style: TextStyle(color: colors.error),
                          ),
                        ),
                      const SizedBox(height: 26),
                      Row(
                        children: [
                          const Expanded(
                            child: Text(
                              'Tracks',
                              style: TextStyle(
                                fontSize: 23,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          if (offline < tracks.length)
                            FilledButton.tonalIcon(
                              onPressed: busy
                                  ? null
                                  : () => run(() async {
                                      for (final track in tracks) {
                                        await download(track);
                                      }
                                    }),
                              icon: const Icon(Icons.download_rounded),
                              label: const Text('Download all'),
                            ),
                        ],
                      ),
                      if (tracks.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 20),
                          child: Text(
                            'Import a playlist or MP3 to get started.',
                            style: TextStyle(color: colors.onSurfaceVariant),
                          ),
                        ),
                    ],
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(22, 0, 22, 24),
                  sliver: SliverList.builder(
                    itemCount: tracks.length,
                    itemBuilder: (context, index) =>
                        trackRow(tracks[index], colors),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget libraryCard(int offline) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(26),
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xff253d2c), Color(0xff415735), Color(0xff627246)],
            begin: Alignment.bottomLeft,
            end: Alignment.topRight,
          ),
        ),
        child: Stack(
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(painter: RecordGrooves()),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 26, 22, 23),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.headphones_rounded,
                    size: 25,
                    color: Color(0xffd7fb7e),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 38,
                      height: 1.03,
                      letterSpacing: -1.7,
                      fontWeight: FontWeight.w800,
                      color: Color(0xfff7ffef),
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '$offline of ${tracks.length} tracks saved offline',
                    style: const TextStyle(
                      fontWeight: FontWeight.w500,
                      color: Color(0xffe0edda),
                    ),
                  ),
                  if (tracks.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: LinearProgressIndicator(
                        value: offline / tracks.length,
                        backgroundColor: const Color(0xff334637),
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget importCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xff181f18),
        border: Border.all(color: const Color(0xff313b30)),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Import music',
            style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: link,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              labelText: searchSoundCloud
                  ? 'Search SoundCloud playlists'
                  : 'Search Spotify playlists or paste a link',
              prefixIcon: const Icon(Icons.search_rounded),
            ),
            onSubmitted: busy ? null : (_) => run(searchPlaylists),
          ),
          const SizedBox(height: 10),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('Spotify')),
              ButtonSegment(value: true, label: Text('SoundCloud')),
            ],
            selected: {searchSoundCloud},
            onSelectionChanged: busy
                ? null
                : (selection) => setState(() {
                    searchSoundCloud = selection.single;
                    searchResults = [];
                    message = '';
                  }),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              FilledButton.icon(
                onPressed: busy ? null : () => run(searchPlaylists),
                icon: const Icon(Icons.search),
                label: const Text('Search playlists'),
              ),
              if (!searchSoundCloud)
                OutlinedButton(
                  onPressed: busy ? null : () => run(connect),
                  child: const Text('Connect Spotify'),
                ),
              TextButton.icon(
                onPressed: busy ? null : () => run(importFiles),
                icon: const Icon(Icons.audio_file_outlined),
                label: const Text('Import MP3s'),
              ),
            ],
          ),
          for (final playlist in searchResults)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(playlist.name),
              subtitle: Text(playlist.isSoundCloud ? 'SoundCloud' : 'Spotify'),
              onTap: busy ? null : () => run(() => load(playlist)),
              trailing: IconButton(
                tooltip: 'Open original playlist',
                icon: const Icon(Icons.open_in_new),
                onPressed: () => launchUrl(
                  playlist.url,
                  mode: LaunchMode.externalApplication,
                ),
              ),
            ),
          if (playlists.isNotEmpty) ...[
            const SizedBox(height: 10),
            DropdownButtonFormField<Playlist>(
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Your Spotify playlists',
              ),
              items: playlists
                  .map(
                    (playlist) => DropdownMenuItem(
                      value: playlist,
                      child: Text(
                        playlist.name,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                  .toList(),
              onChanged: busy
                  ? null
                  : (playlist) {
                      if (playlist != null) run(() => load(playlist));
                    },
            ),
          ],
        ],
      ),
    );
  }

  Widget trackRow(Track track, ColorScheme colors) {
    final available = file(track).existsSync();
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: ListTile(
        tileColor: const Color(0xff181f18),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
        leading: Icon(
          available ? Icons.offline_pin_rounded : Icons.music_note_rounded,
          color: available ? colors.primary : colors.onSurfaceVariant,
        ),
        title: Text(track.title),
        subtitle: Text(
          '${track.artist}\n${available ? 'Saved offline · ${saved[track.id] ?? 'Local file'}' : status[track.id] ?? 'Ready to search'}',
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (track.spotifyUrl.isNotEmpty)
              IconButton(
                tooltip: 'Open original track',
                onPressed: () => launchUrl(
                  Uri.parse(track.spotifyUrl),
                  mode: LaunchMode.externalApplication,
                ),
                icon: const Icon(Icons.open_in_new, size: 18),
              ),
            IconButton.filledTonal(
              tooltip: available ? 'Play offline' : 'Find download',
              icon: Icon(
                available ? Icons.play_arrow_rounded : Icons.download_rounded,
              ),
              onPressed: busy
                  ? null
                  : () => run(() => available ? play(track) : download(track)),
            ),
          ],
        ),
      ),
    );
  }

  Widget playerBar(ColorScheme colors) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
        child: Center(
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 746),
            child: reveal(
              Material(
                borderRadius: BorderRadius.circular(20),
                color: const Color(0xff293927),
                child: ListTile(
                  leading: Icon(
                    Icons.graphic_eq_rounded,
                    color: colors.primary,
                  ),
                  title: Text(playing!.title, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    playing!.artist,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: StreamBuilder<PlayerState>(
                    stream: player.onPlayerStateChanged,
                    initialData: player.state,
                    builder: (context, snapshot) {
                      final active = snapshot.data == PlayerState.playing;
                      return IconButton.filled(
                        tooltip: active ? 'Pause' : 'Play',
                        onPressed: busy
                            ? null
                            : () => run(() async {
                                if (active) {
                                  await player.pause();
                                } else if (player.state == PlayerState.paused) {
                                  await player.resume();
                                } else {
                                  await play(playing!);
                                }
                              }),
                        icon: AnimatedSwitcher(
                          duration: MediaQuery.disableAnimationsOf(context)
                              ? Duration.zero
                              : 160.ms,
                          child: Icon(
                            active
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            key: ValueKey(active),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class RecordGrooves extends CustomPainter {
  const RecordGrooves();
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width - 22, size.height * .33);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = const Color(0x32eaffbf);
    for (double radius = 20; radius < 188; radius += 12) {
      canvas.drawCircle(center, radius, paint);
    }
  }

  @override
  bool shouldRepaint(RecordGrooves oldDelegate) => false;
}
