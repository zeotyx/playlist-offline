import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

class Track {
  final String id, title, artist, spotifyUrl;
  final int seconds;

  const Track(this.id, this.title, this.artist, this.seconds, this.spotifyUrl);

  factory Track.fromJson(Map<String, dynamic> json) => Track(
    json['id'],
    json['title'],
    json['artist'],
    json['seconds'],
    json['spotifyUrl'],
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'artist': artist,
    'seconds': seconds,
    'spotifyUrl': spotifyUrl,
  };
}

class Playlist {
  final String id, name;
  final String? soundCloudUrl;
  const Playlist(this.id, this.name, {this.soundCloudUrl});
  bool get isSoundCloud => soundCloudUrl != null;

  Uri get url =>
      Uri.parse(soundCloudUrl ?? 'https://open.spotify.com/playlist/$id');
}

Future<Map<String, dynamic>> getJson(
  Uri uri, {
  Map<String, String>? headers,
}) async {
  final response = await http
      .get(uri, headers: headers)
      .timeout(const Duration(seconds: 20));
  if (response.statusCode != 200) {
    throw Exception('${uri.host} returned HTTP ${response.statusCode}.');
  }
  return jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
}

class Spotify {
  static const redirect = 'http://127.0.0.1:43821/callback';
  String? _token;

  Future<void> connect(
    String clientId,
    Future<bool> Function(Uri) openBrowser,
  ) async {
    final random = Random.secure();
    String nonce() =>
        base64UrlEncode(List.generate(32, (_) => random.nextInt(256)))
            .replaceAll('=', '');
    final verifier = nonce();
    final state = nonce();
    final challenge = base64UrlEncode(
      sha256.convert(ascii.encode(verifier)).bytes,
    ).replaceAll('=', '');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 43821);
    final code = Completer<String>();
    server.listen((request) async {
      final params = request.uri.queryParameters;
      if (request.uri.path != '/callback' || params['state'] != state) {
        request.response.statusCode = 400;
        await request.response.close();
        return;
      }
      final value = params['code'];
      request.response.write(
        value == null
            ? 'Spotify authorization was declined. Return to Playlist Offline.'
            : 'Spotify approved access. Return to Playlist Offline.',
      );
      await request.response.close();
      if (code.isCompleted) return;
      if (value == null) {
        code.completeError(Exception('Spotify authorization was declined.'));
      } else {
        code.complete(value);
      }
    });

    try {
      final url = Uri.https('accounts.spotify.com', '/authorize', {
        'client_id': clientId,
        'response_type': 'code',
        'redirect_uri': redirect,
        'scope': 'playlist-read-private playlist-read-collaborative',
        'state': state,
        'code_challenge_method': 'S256',
        'code_challenge': challenge,
      });
      final authorization = await Future.wait([
        code.future.timeout(const Duration(minutes: 4)),
        openBrowser(url).then((opened) {
          if (!opened) throw Exception('Could not open Spotify sign-in.');
        }),
      ], eagerError: true);
      final response = await http
          .post(
            Uri.https('accounts.spotify.com', '/api/token'),
            body: {
              'client_id': clientId,
              'grant_type': 'authorization_code',
              'code': authorization.first as String,
              'redirect_uri': redirect,
              'code_verifier': verifier,
            },
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        throw Exception(
          'Spotify sign-in failed (HTTP ${response.statusCode}).',
        );
      }
      _token = jsonDecode(response.body)['access_token'] as String;
    } finally {
      if (!code.isCompleted) {
        code.completeError(Exception('Spotify sign-in ended.'));
      }
      await server.close(force: true);
    }
  }

  Future<Map<String, dynamic>> _get(Uri uri) {
    if (_token == null) throw Exception('Connect Spotify first.');
    if (uri.origin != 'https://api.spotify.com') {
      throw Exception('Invalid Spotify API address.');
    }
    return getJson(uri, headers: {'Authorization': 'Bearer $_token'});
  }

  Stream<dynamic> _items(String path) async* {
    Uri? next = Uri.https('api.spotify.com', path, {'limit': '50'});
    while (next != null) {
      final page = await _get(next);
      yield* Stream.fromIterable(page['items'] as List);
      next = Uri.tryParse(page['next'] as String? ?? '');
      if (next?.host.isEmpty ?? false) next = null;
    }
  }

  Future<List<Playlist>> playlists() =>
      _items('/v1/me/playlists')
          .where((item) => item != null)
          .map((item) => Playlist(item['id'], item['name']))
          .toList();

  Future<List<Playlist>> search(String query) async {
    final page = await _get(
      Uri.https('api.spotify.com', '/v1/search', {
        'q': query,
        'type': 'playlist',
        'limit': '10',
      }),
    );
    return [
      for (final item in page['playlists']['items'] as List)
        if (item != null && item['public'] != false)
          Playlist(item['id'], item['name']),
    ];
  }

  Future<List<Track>> tracks(String id) async {
    final tracks = <Track>[];
    await for (final entry in _items('/v1/playlists/$id/items')) {
      final item = entry?['item'] ?? entry?['track'];
      if (item == null || item['type'] != 'track' || item['id'] == null) {
        continue;
      }
      tracks.add(
        Track(
          item['id'],
          item['name'],
          (item['artists'] as List).map((artist) => artist['name']).join(', '),
          (item['duration_ms'] as int) ~/ 1000,
          'https://open.spotify.com/track/${item['id']}',
        ),
      );
    }
    return tracks;
  }

  Future<Playlist> fromLink(String value) async {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host != 'open.spotify.com' ||
        uri.pathSegments.length < 2 ||
        uri.pathSegments[uri.pathSegments.length - 2] != 'playlist') {
      throw Exception('Paste an open.spotify.com playlist link.');
    }
    final id = uri.pathSegments.last;
    if (!RegExp(r'^[A-Za-z0-9]{22}$').hasMatch(id)) {
      throw Exception('Invalid Spotify playlist ID.');
    }
    final result = await _get(
      Uri.https('api.spotify.com', '/v1/playlists/$id'),
    );
    return Playlist(id, result['name']);
  }
}

class SoundCloud {
  final String token;
  const SoundCloud(this.token);

  Future<Map<String, dynamic>> _get(Uri uri) {
    if (token.isEmpty)
      throw Exception('Add a SoundCloud access token in Service setup.');
    if (uri.origin != 'https://api.soundcloud.com') {
      throw Exception('Invalid SoundCloud API address.');
    }
    return getJson(uri, headers: {'Authorization': 'OAuth $token'});
  }

  Future<List<Playlist>> search(String query) async {
    final page = await _get(
      Uri.https('api.soundcloud.com', '/playlists', {
        'q': query,
        'limit': '20',
        'linked_partitioning': 'true',
      }),
    );
    return [
      for (final item in page['collection'] as List)
        if (item['sharing'] == 'public' &&
            item['urn'] is String &&
            item['permalink_url'] is String)
          Playlist(
            item['urn'],
            item['title'],
            soundCloudUrl: item['permalink_url'],
          ),
    ];
  }

  Future<List<Track>> tracks(String urn) async {
    Uri? next = Uri.https('api.soundcloud.com', '/playlists/$urn/tracks', {
      'linked_partitioning': 'true',
    });
    final result = <Track>[];
    while (next != null) {
      final page = await _get(next);
      for (final item in page['collection'] as List) {
        final id = item?['urn'] as String?;
        if (id == null ||
            item['sharing'] == 'private' ||
            item['duration'] is! int)
          continue;
        final metadata = item['publisher_metadata'];
        result.add(
          Track(
            id.replaceAll(':', '-'),
            item['title'],
            metadata?['artist'] ?? item['user']?['username'] ?? '',
            (item['duration'] as int) ~/ 1000,
            item['permalink_url'] ?? '',
          ),
        );
      }
      next = Uri.tryParse(page['next_href'] as String? ?? '');
      if (next?.host.isEmpty ?? false) next = null;
    }
    return result;
  }
}

class Match {
  final String provider, title, artist;
  final int seconds;
  final Uri url;
  const Match(this.provider, this.title, this.artist, this.seconds, this.url);

  bool matches(Track track) {
    String normalize(String value) =>
        value.toLowerCase().trim().replaceAll(RegExp(r'\s+'), ' ');
    return normalize(title) == normalize(track.title) &&
        normalize(artist) == normalize(track.artist) &&
        (seconds - track.seconds).abs() <= 3;
  }
}

class Catalogs {
  final String jamendoId, audiusKey;
  const Catalogs(this.jamendoId, this.audiusKey);

  Future<List<Match>> audius(Track track) async {
    final params = {'app_name': 'PlaylistOffline'};
    final data = await getJson(
      Uri.https('api.audius.co', '/v1/tracks/search', {
        ...params,
        'query': '${track.title} ${track.artist}',
        'limit': '20',
      }),
    );
    return [
      for (final item in data['data'])
        if (item['is_downloadable'] == true &&
            item['is_download_gated'] != true)
          Match(
            'Audius',
            item['title'],
            item['user']['name'],
            item['duration'],
            Uri.https('api.audius.co', '/v1/tracks/${item['id']}/download', {
              ...params,
              'original': 'false',
            }),
          ),
    ];
  }

  Future<List<Match>> jamendo(Track track) async {
    final data = await getJson(
      Uri.https('api.jamendo.com', '/v3.0/tracks/', {
        'client_id': jamendoId,
        'namesearch': track.title,
        'artist_name': track.artist,
        'type': 'single albumtrack',
        'audiodlformat': 'mp32',
        'limit': '20',
      }),
    );
    if (data['headers']['status'] != 'success') {
      throw Exception('Jamendo rejected the search. Check your client ID.');
    }
    return [
      for (final item in data['results'])
        if (item['audiodownload_allowed'] == true &&
            (item['audiodownload'] as String).startsWith('https://'))
          Match(
            'Jamendo',
            item['name'],
            item['artist_name'],
            item['duration'],
            Uri.parse(item['audiodownload']),
          ),
    ];
  }

  Future<String?> download(
    Track track,
    File Function(String) destination,
  ) async {
    final errors = <String>[];
    Future<List<Match>> lookup(Future<List<Match>> search) async {
      try {
        return await search;
      } catch (error) {
        errors.add(error.toString());
        return [];
      }
    }

    final lists = await Future.wait([
      lookup(audius(track)),
      if (jamendoId.isNotEmpty) lookup(jamendo(track)),
    ]);
    for (final match
        in lists
            .expand((list) => list)
            .where((match) => match.matches(track))) {
      final client = http.Client();
      final partial = File('${destination('mp3').path}.part');
      try {
        final request = http.Request('GET', match.url);
        if (match.provider == 'Audius' && audiusKey.isNotEmpty) {
          request.headers['x-api-key'] = audiusKey;
        }
        final response = await client
            .send(request)
            .timeout(const Duration(seconds: 25));
        final type = response.headers['content-type'] ?? '';
        if (response.statusCode != 200 ||
            !(type.startsWith('audio/') ||
                type.startsWith('application/octet-stream'))) {
          throw Exception(
            '${match.provider} did not provide an audio file (HTTP ${response.statusCode}).',
          );
        }
        await response.stream
            .timeout(const Duration(seconds: 25))
            .pipe(partial.openWrite());
        if (await partial.length() == 0) {
          throw Exception('${match.provider} returned an empty file.');
        }
        final name = switch (type.split(';').first) {
          'audio/wav' || 'audio/wave' || 'audio/x-wav' => 'wav',
          'audio/flac' || 'audio/x-flac' => 'flac',
          'audio/mp4' || 'audio/aac' => 'm4a',
          'audio/mpeg' || 'audio/mp3' => 'mp3',
          _ => throw Exception(
            '${match.provider} returned an unsupported audio format.',
          ),
        };
        await partial.rename(destination(name).path);
        return match.provider;
      } catch (error) {
        errors.add(error.toString());
      } finally {
        client.close();
        if (await partial.exists()) await partial.delete();
      }
    }
    if (errors.isNotEmpty) throw Exception(errors.join('\n'));
    return null;
  }
}
