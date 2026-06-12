# Qobuz Playlists Backup
# Backing Up Qobuz Playlists with a Simple Shell Script

Streaming platforms are convenient until they are not.

Playlists are one of those small personal datasets that quietly become valuable over time. They are not just lists of tracks; they are listening history, mood archives, travel memories, debugging music, late-night sysadmin fuel, and sometimes the only proof that a specific album really did exist before a licensing agreement made it vanish.

This is why I wanted a small, boring, scriptable way to export my Qobuz playlists and favorites.

Not a full music manager. Not a synchronization platform. Not a database-backed media library with a web UI, three containers and a motivational dashboard.

Just a shell script.

Because sometimes the best backup tool is the one you can run from cron, inspect with `cat`, and fix with coffee.

---

## The Goal

The script, [qobuz-fetch.sh](https://codeberg.org/cyayon/cyasssw/src/branch/main/media/qobuz-fetch.sh), is a small POSIX-style shell script that talks directly to the Qobuz API and exports:

- the list of user playlists;
- each playlist content;
- favorite tracks;
- favorite albums;
- favorite artists;
- raw JSON API responses;
- simplified text exports generated with `jq`.

The goal is not to replace Qobuz.

The goal is to own a local copy of the metadata that matters.

If a playlist disappears, a track is removed, an account has an issue, or I simply want to diff my music taste over time like any perfectly normal person would do, I have files.

And files are good.

---

## Why Backup Streaming Playlists?

Streaming services create a strange dependency: the music is remote, the catalog changes, but the curation is personal.

A playlist can represent years of manual selection. Yet, in most platforms, it remains tied to:

- a provider account;
- a proprietary API;
- licensing constraints;
- application behavior;
- and sometimes an export feature that may or may not exist when you need it.

Backing up playlists does not magically give you the music files, of course. But it preserves useful metadata:

- track title;
- artist;
- album;
- ISRC;
- duration;
- album UPC for favorites;
- Qobuz playlist identifiers;
- Qobuz artist identifiers.

That is enough to rebuild, compare, migrate, audit, or simply keep a historical record.

In infrastructure terms: I do not want my playlists to be a single-provider stateful snowflake.

Yes, even playlists get architecture principles. I may have a problem.

---

## Requirements

The script intentionally keeps the dependency list short.

It requires:

- `sh`;
- `curl`;
- `jq`;
- a Qobuz application ID;
- a Qobuz user authentication token;
- a writable output directory.

The script uses the Qobuz API endpoint:

```text
https://www.qobuz.com/api.json/0.2
```

Authentication is done by passing:

```text
app_id
user_auth_token
```

as API parameters.

---

## Configuration

The script supports two configuration methods.

### Command-line arguments

It can be called directly with:

```sh
./qobuz-fetch.sh \
  --app-id APP_ID \
  --token YOUR_QOBUZ_TOKEN \
  --outputdir ./qobuz-backup
```

### Configuration file

If the following file exists:

```text
/etc/nbux/qobuz-fetch.conf
```

it is loaded automatically.

A typical configuration file looks like:

```sh
QOBUZ_APPID="your_app_id"
QOBUZ_TOKEN="your_user_auth_token"
OUTPUT_DIR="/var/backups/qobuz"
```

This makes the script easier to run from cron or from a systemd timer without exposing credentials in the process arguments.

The configuration file should obviously not be world-readable.

For example:

```sh
chown root:root /etc/nbux/qobuz-fetch.conf
chmod 600 /etc/nbux/qobuz-fetch.conf
```

There is no need to turn playlist backup into credential confetti.

---

## Output Directory

The output directory is created automatically if it does not exist.

For example:

```text
/var/backups/qobuz
```

or:

```text
/home/user/backups/qobuz
```

The script writes both raw JSON files and formatted text files.

The raw JSON files are useful because they preserve the original API response.

The text files are useful because they are easier to read, diff, commit, or grep.

---

## What the Script Fetches

The script first retrieves the user playlists using:

```text
playlist/getUserPlaylists
```

It then extracts the playlist IDs and names.

For each playlist, it calls:

```text
playlist/get
```

with:

```text
extra=tracks
```

This returns the playlist metadata and track list.

Finally, the script fetches user favorites through:

```text
favorite/getUserFavorites
```

for the following types:

```text
tracks
albums
artists
```

---

## Pagination

The script handles pagination with a fixed API limit:

```sh
api_limit=500
```

It starts at offset `0`, then increments the offset by `500` until no more items are returned.

The loop is intentionally simple:

```text
offset = 0
offset = offset + 500
stop when the API returns no more items
```

No hidden state, no cache database, no local cursor file.

The source of truth is the Qobuz API at execution time, and the output is a set of files.

Boring. Predictable. Good.

---

## Generated Files

The playlist list is exported as:

```text
qobuz-playlists.json
qobuz-playlists.txt
```

Each playlist is exported as raw JSON:

```text
qobuz-<playlist_id>.json
```

The script also generates a simplified playlist export:

```text
qobuz-<playlist_name>-<playlist_id>.txt
```

For favorites, the script creates:

```text
qobuz-favorites-tracks.json
qobuz-favorites-tracks.txt

qobuz-favorites-albums.json
qobuz-favorites-albums.txt

qobuz-favorites-artists.json
qobuz-favorites-artists.txt
```

This gives two levels of backup:

1. raw API data for completeness;
2. formatted metadata for human use.

---

## Playlist Export Format

For each playlist, the formatted export contains a JSON array of simplified track objects:

```json
[
  {
    "title": "Track title",
    "artist": "Artist name",
    "album": "Album title",
    "isrc": "ISRC code",
    "duration": 123
  }
]
```

The important field here is `isrc`.

Track names and album names are useful, but they are not always stable or unique. The ISRC is much better when trying to identify a recording across platforms.

It is not perfect, because the music industry enjoys making metadata weird, but it is better than trusting only strings.

---

## Favorite Tracks Export Format

Favorite tracks use a similar structure:

```json
[
  {
    "title": "Track title",
    "artist": "Artist name",
    "album": "Album title",
    "isrc": "ISRC code",
    "duration": 123
  }
]
```

This makes playlist tracks and favorite tracks easy to compare.

For example:

```sh
jq '.[].isrc' qobuz-favorites-tracks.txt
```

or:

```sh
grep -i "artist name" qobuz-favorites-tracks.txt
```

Yes, the file extension is `.txt`, but the formatted content is JSON-like output from `jq`.

That is not a bug. That is a lifestyle choice.

---

## Favorite Albums Export Format

Favorite albums are exported with:

```json
[
  {
    "artist": "Artist name",
    "album": "Album title",
    "label": "Label name",
    "upc": "UPC code",
    "duration": 1234
  }
]
```

The `upc` field is useful when identifying albums across services.

Just like ISRC for tracks, UPC is not always a silver bullet, but it is much better than relying only on album titles.

---

## Favorite Artists Export Format

Favorite artists are exported as:

```json
[
  {
    "artist": "Artist name",
    "id": "Qobuz artist id"
  }
]
```

This is the simplest export, but still useful for rebuilding favorite artist lists or comparing account state over time.

---

## Optional Previous Export Retention

The script contains support for keeping the previous export by renaming an existing file to `.old` when `KEEP_OLD=1` is enabled.

For example:

```sh
KEEP_OLD=1
```

If enabled, an existing file such as:

```text
qobuz-favorites-tracks.json
```

is moved to:

```text
qobuz-favorites-tracks.json.old
```

before the new export is written.

This is intentionally minimal.

For real versioning, I would rather put the output directory under Git, rsnapshot, restic, borg, ZFS snapshots, Btrfs snapshots, or whatever backup religion is currently winning in the room.

---

## Running It from Cron

A simple cron entry could look like this:

```cron
15 3 * * * /usr/local/bin/qobuz-fetch.sh >/var/log/qobuz-fetch.log 2>&1
```

Or, if using explicit arguments:

```cron
15 3 * * * /usr/local/bin/qobuz-fetch.sh --app-id APP_ID --token TOKEN --outputdir /var/backups/qobuz >/var/log/qobuz-fetch.log 2>&1
```

I prefer the configuration file approach for credentials.

Arguments are convenient for testing; config files are cleaner for unattended execution.

---

## Running It from systemd

A systemd service could be as simple as:

```ini
[Unit]
Description=Backup Qobuz playlists and favorites
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/qobuz-fetch.sh
```

And a timer:

```ini
[Unit]
Description=Run Qobuz playlist backup daily

[Timer]
OnCalendar=03:15
Persistent=true

[Install]
WantedBy=timers.target
```

Then:

```sh
systemctl enable --now qobuz-fetch.timer
```

This gives a clean unattended backup without inventing a platform.

---

## Error Handling

The script checks that required variables are set:

```text
QOBUZ_APIURL
QOBUZ_APPID
QOBUZ_TOKEN
OUTPUT_DIR
```

It also checks whether the output directory can be created.

API calls are made with:

```sh
curl -sf
```

So HTTP errors and connection failures return a non-zero status.

The script accumulates errors and exits with the last non-zero return code seen during execution.

It is not a complex retry engine, and that is deliberate.

If Qobuz or the network is down, I want the job to fail visibly. The next scheduled run will try again.

A backup job should be boring, not heroic.

---

## What This Script Does Not Do

This script does not:

- download music files;
- bypass DRM;
- synchronize playlists back to Qobuz;
- migrate playlists to another provider;
- normalize metadata perfectly;
- maintain a local database;
- expose a web UI;
- pretend to be a music platform.

It only exports metadata.

That is the point.

Small scope, small failure domain.

---

## Why Not Use a Bigger Tool?

There are existing tools and services for playlist migration, music library management, and streaming account synchronization.

Some of them are more complete than this script.

They may support multiple providers, bidirectional synchronization, GUI workflows, interactive authentication, conflict resolution, and metadata matching.

That is useful when the goal is migration or large-scale library management.

My goal was different.

I wanted:

- a local backup;
- no dependency on a third-party sync service;
- no database;
- no daemon;
- no web UI;
- no complex state;
- no magic;
- files I can inspect.

A shell script using `curl` and `jq` is not glamorous, but it is transparent.

And transparent usually ages better.

---

## Design Philosophy

The design is intentionally KISS:

- fetch from the API;
- paginate;
- write JSON;
- generate readable exports;
- exit with a meaningful status.

There is no state machine beyond the API offset.

There is no persistence layer beyond the files themselves.

There is no clever abstraction to debug later when all I wanted was to know what was in a playlist six months ago.

This is the same principle I like in infrastructure scripts: do one thing, keep it observable, and make sure future-you can understand it after forgetting why past-you wrote it.

Future-me is rarely impressed. Documentation helps.

---

## Example Workflow

A typical workflow is:

```sh
install -d -m 700 /var/backups/qobuz
install -d -m 700 /etc/nbux
vi /etc/nbux/qobuz-fetch.conf
chmod 600 /etc/nbux/qobuz-fetch.conf
/usr/local/bin/qobuz-fetch.sh
```

Then inspect the output:

```sh
ls -lh /var/backups/qobuz
```

Read the playlist list:

```sh
cat /var/backups/qobuz/qobuz-playlists.txt
```

Search for a track:

```sh
grep -Ri "track name" /var/backups/qobuz
```

Commit to Git if desired:

```sh
cd /var/backups/qobuz
git add .
git commit -m "Update Qobuz backup"
```

Because nothing says “healthy relationship with music” like version-controlling playlists.

---

## Conclusion

`qobuz-fetch.sh` is a small backup script for Qobuz playlists and favorites.

It is not ambitious. That is why I like it.

It uses the Qobuz API, exports raw JSON, creates simplified metadata files with `jq`, and can run unattended from cron or systemd.

It gives me local, inspectable, versionable files for something that would otherwise live only inside a streaming platform.

Sometimes the best architecture is just:

```text
API → JSON → files → backup
```

No dashboard required.

#publish #blog/cyasssw/media
