# Spotify Playlists Backup
# Backing Up Spotify Playlists with a Shell Script

There are two kinds of people in this world: those who trust cloud music platforms to keep their library forever, and those who have already lost something once.

I am in the second category.

This small script, [spotify-fetch.sh](https://codeberg.org/cyayon/cyasssw/src/branch/main/media/spotify-fetch.sh), is a deliberately simple backup tool for Spotify. It does not try to synchronize anything, rebuild playlists, or become a full music-management platform. It does one thing: it asks Spotify for my account data and stores the result locally as JSON files.

Simple, boring, inspectable. The holy trinity of scripts that I may need to understand again in six months.

---

## What the Script Backs Up

The script exports several parts of a Spotify account:

- the user profile;
- the playlist list;
- playlist metadata;
- playlist items;
- liked songs;
- saved albums.

The resulting backup directory looks like this:

```text
spotify-backup-YYYYMMDD-HHMMSS/
  profile.json
  playlists.tsv
  playlists/
    <playlist_name>__<playlist_id>/
      playlist.json
      items-page-001.json
      items-page-002.json
      ...
      NOTICE.txt
  library/
    liked-songs/
      tracks-page-001.json
      tracks-page-002.json
      ...
      manifest.txt
    saved-albums/
      albums-page-001.json
      albums-page-002.json
      ...
      manifest.txt
```

The output is intentionally raw.

I do not want a clever export format that hides information. I want the data as returned by the Spotify Web API, stored locally, with enough structure to diff, inspect, archive, or process later.

Because sometimes the best database is a directory tree and a few JSON files. At least until someone suggests Kubernetes.

---

## Why Backup Spotify Playlists?

Streaming platforms are convenient, but they are not backups.

A Spotify playlist can disappear for several reasons:

- accidental deletion;
- account migration;
- API or platform changes;
- collaborative playlist changes;
- unavailable tracks;
- subscription or region issues;
- simple human error, which remains the most reliable failure mode in computing.

The script is not meant to replace Spotify. It is meant to preserve a local snapshot of what Spotify says exists at a given point in time.

That snapshot may not be enough to recreate everything perfectly, but it gives me a recoverable reference: playlist IDs, names, owners, track pages, liked songs, albums, Spotify URLs, and metadata.

In other words: not a time machine, but at least a decent black box recorder.

---

## Design Philosophy

The script follows the same philosophy I tend to apply to infrastructure tooling:

- keep the moving parts small;
- use standard Unix tools;
- avoid hidden state;
- write files that can be inspected manually;
- fail loudly when something unexpected happens;
- do not pretend the script is smarter than the API.

It is written as a POSIX-style shell script using `curl`, `sed`, `awk`, `tr`, and basic filesystem operations.

No framework.
No database.
No daemon.
No web UI.
No “lightweight dependency” that pulls half the Internet.

Just shell, HTTP, JSON, and the occasional reminder that parsing JSON with `sed` is not beautiful, but beauty was not the primary requirement here.

---

## Spotify API Prerequisites

The script uses the Spotify Web API and therefore requires an application to be created in the Spotify Developer Dashboard.

The application must provide:

```text
SPOTIFY_CLIENT_ID
SPOTIFY_CLIENT_SECRET
SPOTIFY_REFRESH_TOKEN
```

The redirect URI used by the script is:

```text
http://127.0.0.1:8888/callback
```

This URI must be declared in the Spotify Developer Dashboard.

The script requests the following scopes:

```text
playlist-read-private
playlist-read-collaborative
user-library-read
```

These scopes are required to read:

- private playlists;
- collaborative playlists;
- liked songs;
- saved albums.

The goal is read-only backup. The script does not modify anything in Spotify.

That is an important property. Backup tools should not become restore tools by accident.

---

## Configuration

The script can load a configuration file from:

```text
/etc/nbux/spotify-fetch.conf
```

A minimal configuration looks like this:

```sh
SPOTIFY_CLIENT_ID='your-client-id'
SPOTIFY_CLIENT_SECRET='your-client-secret'
SPOTIFY_REFRESH_TOKEN='your-refresh-token'
```

An optional output directory can also be defined:

```sh
OUTPUT_DIR='/path/to/spotify-backup'
```

If `OUTPUT_DIR` is not defined, the script creates a timestamped directory:

```text
spotify-backup-YYYYMMDD-HHMMSS
```

This makes each run immutable by default. A backup run creates a new snapshot rather than overwriting the previous one.

That is boring, safe, and exactly what I want.

---

## Getting a Refresh Token

The script includes a token helper mode:

```sh
sh spotify-fetch.sh token
```

This mode prints an authorization URL, asks the user to open it in a browser, and then expects the full redirect URL to be pasted back into the terminal.

The script extracts the `code=` parameter and exchanges it for:

```text
SPOTIFY_ACCESS_TOKEN
SPOTIFY_REFRESH_TOKEN
```

The refresh token is the important one. It should be stored securely in the configuration file and reused for future backup runs.

A refresh token is a long-lived credential. Treat it like a password, not like a cute string that happens to unlock your music library.

---

## Authentication Flow

Normal backup mode starts by refreshing the Spotify access token:

```text
refresh_token -> access_token
```

The script uses:

```text
https://accounts.spotify.com/api/token
```

with HTTP Basic authentication based on the client ID and client secret.

The resulting access token is then used as a Bearer token for Spotify API calls:

```text
Authorization: Bearer <access_token>
```

If Spotify returns `401 Unauthorized`, the script refreshes the token and retries.

This makes the backup resilient to expired access tokens without requiring manual intervention.

---

## Rate Limiting

Spotify can return:

```text
429 Too Many Requests
```

When that happens, the script reads the `Retry-After` header and sleeps for the requested duration.

If no retry value is available, it falls back to a short default delay.

This keeps the script polite with the API.

It is also a good reminder that even shell scripts should have manners.

---

## User Profile Backup

The first exported object is the Spotify user profile:

```text
GET /v1/me
```

The response is stored as:

```text
profile.json
```

This gives context to the backup: account identity, display name, URI, country, external URL, and other fields returned by Spotify.

---

## Playlist Discovery

The script lists playlists using:

```text
GET /v1/me/playlists
```

with pagination:

```text
limit=50
offset=<n>
```

Each page is temporarily stored, and playlist IDs are extracted into an intermediate file.

The script then deduplicates playlist IDs before backing them up one by one.

This avoids processing the same playlist twice if the API response ever contains duplicates or if pagination behaves in an unexpected way.

Again: boring defensive programming. Not glamorous, but useful.

---

## Playlist Metadata

For each playlist, the script downloads metadata using:

```text
GET /v1/playlists/{playlist_id}
```

with selected fields such as:

- playlist ID;
- name;
- description;
- public/private status;
- collaborative flag;
- snapshot ID;
- Spotify URI;
- external Spotify URL;
- owner;
- follower count;
- images;
- total track count.

The metadata is stored as:

```text
playlists/<playlist_name>__<playlist_id>/playlist.json
```

Playlist names are sanitized before being used as directory names.

The playlist ID is always included in the directory name because names are not stable identifiers. Humans rename things. APIs have IDs for a reason.

---

## Playlist Manifest

The script also creates a tab-separated manifest:

```text
playlists.tsv
```

The manifest contains:

```text
playlist_id    name    total_tracks    spotify_url    owner_id
```

This provides a quick index of all backed-up playlists without having to open each JSON file.

It is useful for quick checks, `grep`, `awk`, diffs, and the kind of command-line archaeology that inevitably happens later.

---

## Playlist Items

For each playlist, the script downloads playlist items page by page:

```text
GET /v1/playlists/{playlist_id}/items
```

with:

```text
limit=50
offset=<n>
```

Pages are stored as:

```text
items-page-001.json
items-page-002.json
...
```

The script follows pagination until the API returns no `next` URL.

This preserves the raw playlist item structure, including track metadata and playlist-specific information returned by Spotify.

---

## Handling Forbidden Playlist Items

Some playlists may be visible as metadata but not fully readable at the item level.

If Spotify returns:

```text
403 Forbidden
```

while reading playlist items, the script does not abort the whole backup.

Instead, it writes a local notice file:

```text
NOTICE.txt
```

with content such as:

```text
tracks_skipped=403_forbidden
reason=get_playlist_items_forbidden
```

This is an important operational detail.

One inaccessible playlist should not prevent the backup of the rest of the account. The failure is recorded locally, and the script continues.

Good backup tools should distinguish between “something was skipped and documented” and “everything is broken, panic now”.

---

## Liked Songs

The script backs up liked songs from:

```text
GET /v1/me/tracks
```

Pages are stored under:

```text
library/liked-songs/
```

as:

```text
tracks-page-001.json
tracks-page-002.json
...
```

The script also writes:

```text
manifest.txt
```

with the total number of saved tracks reported by Spotify:

```text
total_saved_tracks=<n>
```

The selected fields include track identity, name, URI, duration, explicit flag, artists, album metadata, release date, and Spotify URL.

This is useful because liked songs are not just another playlist. They are a personal library state, and losing them is annoying in a very specific and deeply modern way.

---

## Saved Albums

Saved albums are exported from:

```text
GET /v1/me/albums
```

Pages are stored under:

```text
library/saved-albums/
```

as:

```text
albums-page-001.json
albums-page-002.json
...
```

A manifest stores the total number of saved albums:

```text
total_saved_albums=<n>
```

The selected fields include album ID, name, URI, album type, total tracks, release date, artists, images, and Spotify URL.

---

## Running the Backup

With the configuration in place, the normal usage is:

```sh
sh spotify-fetch.sh
```

If no output directory is configured, the script creates a timestamped backup directory:

```text
spotify-backup-20260609-211530/
```

At the end of the run, it prints the backup directory, manifest path, number of playlists backed up, and the library directories.

---

## Scheduling

The script is suitable for periodic execution from cron or a systemd timer.

For example, a simple weekly cron entry could look like:

```cron
15 3 * * 1 /usr/local/bin/spotify-fetch.sh >/var/log/spotify-fetch.log 2>&1
```

A more careful setup would:

- write backups to a dedicated directory;
- rotate or prune old snapshots;
- include the backup directory in a real filesystem backup;
- monitor the exit code;
- alert if the script fails.

Because a backup script that nobody monitors is just a superstition with a timestamp.

---

## What This Script Does Not Do

The script does not:

- restore playlists;
- download audio files;
- bypass DRM;
- scrape the web player;
- modify Spotify data;
- normalize JSON into a custom schema;
- hide API failures;
- pretend to be a music management system.

It only uses the Spotify Web API to export metadata that the account is allowed to read.

That boundary is intentional.

---

## Why Raw JSON?

Raw JSON has advantages:

- it preserves API details;
- it can be reprocessed later;
- it is easy to archive;
- it can be diffed between runs;
- it avoids premature data modeling;
- it keeps the backup script small.

A cleaner export format can always be generated later from the raw data.

The reverse is rarely true.

Once you have thrown away fields, they are gone. And then you get to write a second script called `spotify-fetch-but-this-time-with-the-field-I-forgot.sh`.

---

## Security Notes

The configuration contains sensitive credentials:

```text
SPOTIFY_CLIENT_SECRET
SPOTIFY_REFRESH_TOKEN
```

The file should be readable only by the user running the backup:

```sh
chmod 600 /etc/nbux/spotify-fetch.conf
```

The backup itself may also contain private playlist names, saved music, and account metadata.

That may not be as sensitive as passwords, but it is still personal data. Music taste is basically a fingerprint, just with worse explanations.

---

## Final Thoughts

This script is intentionally small and pragmatic.

It is not an enterprise backup platform. It is not a sync engine. It is not a product.

It is a shell script that asks Spotify what I have, stores the answer locally, and gets out of the way.

For personal infrastructure, that is often the right level of engineering.

Simple enough to understand.
Robust enough to trust.
Boring enough to run unattended.

And if one day a playlist disappears, at least I will have something better than a vague memory and a suspicious feeling that the missing track had a blue cover.

#publish #cyasssw/media
