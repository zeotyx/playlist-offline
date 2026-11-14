# Playlist Offline

A Flutter app for Linux and iPhone. Import Spotify playlist metadata, find full-track downloads on Audius and Jamendo, and play saved audio offline. Tracks are matched by title, artist and duration within three seconds. The app also opens local MP3 files and copies them into its offline library.

## Linux

Extract the Linux archive and run `./playlist_offline` from its directory. Keep the bundled `lib` and `data` directories beside the executable. The x86-64 build uses GTK 3 and GStreamer. A GStreamer audio decoder and working audio output are required for playback.

To build from source, install Flutter 3.50 and its Linux desktop prerequisites, then run `flutter pub get` and `flutter build linux --release`.

## iPhone

The iOS project is included. On a Mac with Flutter 3.50 and Xcode, run `./build-altstore-ipa.sh` from the source directory. Transfer the resulting `build/PlaylistOffline.ipa` to Files on the iPhone and import it in AltStore Classic. The script builds an unsigned device app for AltStore to sign. The iOS build and on-device login need verification on Apple hardware.

## Service setup

1. Register a Spotify Web API development app and add `http://127.0.0.1:43821/callback` to its redirect allowlist. In the app, open **Service setup**, paste your Spotify client ID, then select **Connect Spotify**. Authorize in your browser and return to Playlist Offline after the browser confirms the connection. Where Spotify requires it, allowlist the account in the Spotify Developer Dashboard. Spotify requires Premium for Development Mode app owners, and limits playlist item access to playlists you own or collaborate on.
2. Add your Jamendo API client ID in **Service setup** to enable Jamendo searches. Audius public searches work without a key. An optional Audius API key can be entered for downloads.
3. Pick a playlist or paste an `https://open.spotify.com/playlist/…` link. Choose **Download available tracks** or search for a single track. Catalogs may have sparse coverage. The app shows unmatched tracks and download errors in the playlist.
4. Tap a saved track to play it. Saved tracks and metadata are available after restarting the app. Spotify authorization is session-only.

[Spotify setup](https://developer.spotify.com/documentation/web-api/concepts/apps) · [Audius API](https://docs.audius.co/api/) · [Jamendo API](https://developer.jamendo.com/v3.0/tracks)

### Build the IPA with GitHub Actions

Put the source at the root of a GitHub repository with Actions enabled. In **Actions → Build AltStore IPA**, select **Run workflow**. When the build succeeds, download the **PlaylistOffline-IPA** artifact, unzip it, and send the IPA inside to your iPhone. This workflow uses a GitHub-hosted macOS runner and packages the device build for AltStore to sign. Usage on private repositories is subject to the account's Actions allowance.

The interface uses Flutter Animate for the staggered entrances and respects the system Reduce Motion setting.

### Preconfigure service IDs

Set GitHub repository Actions variables `SPOTIFY_CLIENT_ID` and `JAMENDO_CLIENT_ID` before running the workflow. They are embedded into the app so phone users only need to connect their Spotify account. The same names work as environment variables on a Mac with the build script, or as `--dart-define=NAME=value` arguments for Linux. Register the callback URL shown above with the Spotify app. Use the client ID, never the client secret.

### Search for public playlists

Choose Spotify or SoundCloud under **Import music**, enter a name, and tap **Search playlists**. Tap a result to import the track list or use the external-link button to open it on its service.

- Spotify search requires connecting Spotify. Public playlists appear in search, but Spotify only returns track listings for playlists you own or collaborate on.
- SoundCloud search and track imports require an API access token. Enter one in **Service setup** for the current session. Generate it using SoundCloud's developer API guide with a registered app. SoundCloud currently requires Artist Pro to register a new API app. Keep the client secret outside Playlist Offline.
- Audio downloads still come from matching Audius or Jamendo tracks.

[SoundCloud API guide](https://developers.soundcloud.com/docs/api/guide)
