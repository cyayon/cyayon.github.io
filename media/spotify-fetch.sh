#!/bin/sh
#
# spotify-fetch.sh [ token ]
#
# Backup Spotify:
#   - user profile
#   - playlists
#   - items
#   - liked songs (/me/tracks)
#   - saved albums (/me/albums)
#
# create client_id and client_secret here : https://developer.spotify.com/dashboard/
# set the redirect URI to http://127.0.0.1:8888/callback
#
# Variables:
#   SPOTIFY_CLIENT_ID
#   SPOTIFY_CLIENT_SECRET
#   SPOTIFY_REFRESH_TOKEN
#	REDIRECT_URI='http://127.0.0.1:8888/callback'
#
# Scopes refresh token:
#   playlist-read-private
#   playlist-read-collaborative
#   user-library-read
#
# Usage:
#   export SPOTIFY_CLIENT_ID='...'
#   export SPOTIFY_CLIENT_SECRET='...'
#   export SPOTIFY_REFRESH_TOKEN='...'
#   sh spotify-fetch.sh
#   sh spotify-fetch.sh token 
#
# Output:
#   spotify-backup-YYYYMMDD-HHMMSS/
#     profile.json
#     playlists.tsv
#     playlists/
#       <playlist_name>__<playlist_id>/
#         playlist.json
#         tracks-page-001.json
#         ...
#         NOTICE.txt              # if items are not accessibles
#     library/
#       liked-songs/
#         tracks-page-001.json
#         ...
#         manifest.txt
#       saved-albums/
#         albums-page-001.json
#         ...
#         manifest.txt

set -eu

API_BASE="https://api.spotify.com/v1"
TOKEN_URL="https://accounts.spotify.com/api/token"
REDIRECT_URI='http://127.0.0.1:8888/callback' # adapt AUTH_REQUEST_URL
SCOPE='playlist-read-private%20playlist-read-collaborative%20user-library-read'
AUTH_URL="https://accounts.spotify.com/authorize"
TOKEN_URL="https://accounts.spotify.com/api/token"

# Config file
Config="/etc/nbux/spotify-fetch.conf"

# load config if defined
if [ ! -z "$Config" ] && [ -f "$Config" ] ; then
	echo "NOTICE: loading config $Config"
	. $Config
	[ $? -ne 0 ] && echo "FATAL: while loading config $Config !" && exit 7
fi

: "${SPOTIFY_CLIENT_ID:?missing SPOTIFY_CLIENT_ID}"
: "${SPOTIFY_CLIENT_SECRET:?missing SPOTIFY_CLIENT_SECRET}"
: "${SPOTIFY_REFRESH_TOKEN:?missing SPOTIFY_REFRESH_TOKEN}"

STAMP="$(date +%Y%m%d-%H%M%S)"
#ROOT_DIR="${1:-spotify-backup-$STAMP}"
ROOT_DIR="${OUTPUT_DIR:-spotify-backup-$STAMP}"
TMP_DIR="$ROOT_DIR/.tmp"
PLAYLISTS_DIR="$ROOT_DIR/playlists"
LIBRARY_DIR="$ROOT_DIR/library"
LIKED_DIR="$LIBRARY_DIR/liked-songs"
ALBUMS_DIR="$LIBRARY_DIR/saved-albums"
MANIFEST="$ROOT_DIR/playlists.tsv"

[ ! -d "$ROOT_DIR" ] && echo "mkdir -p $ROOT_DIR" && mkdir -p "$ROOT_DIR"
[ ! -d "$TMP_DIR" ] && echo "mkdir -p $TMP_DIR" && mkdir -p "$TMP_DIR"
[ ! -d "$PLAYLISTS_DIR" ] && echo "mkdir -p $PLAYLISTS_DIR" && mkdir -p "$PLAYLISTS_DIR"
[ ! -d "$LIKED_DIR" ] && echo "mkdir -p $LIKED_DIR" && mkdir -p "$LIKED_DIR"
[ ! -d "$ALBUMS_DIR" ] && echo "mkdir -p $ALBUMS_DIR" && mkdir -p "$ALBUMS_DIR"

AUTH_REQUEST_URL="${AUTH_URL}?client_id=${SPOTIFY_CLIENT_ID}&response_type=code&redirect_uri=http%3A%2F%2F127.0.0.1%3A8888%2Fcallback&scope=${SCOPE}"

ACCESS_TOKEN=""

log() {
    printf '%s\n' "$*" >&2
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

extract_code() {
    sed -n 's/.*[?&]code=\([^&]*\).*/\1/p'
}

json_oneline() {
    tr -d '\n' < "$1"
}

#json_get_string() {
#    key="$1"
#    file="$2"
#    tr -d '\n' < "$file" | sed -n "s/.*\"$key\":\"\\([^\"]*\\)\".*/\\1/p"
#}

json_get_string() {
    key="$1"
    file="$2"
    json_oneline "$file" | sed -n "s/.*\"$key\":\"\\([^\"]*\\)\".*/\\1/p"
}

json_get_next_url() {
    file="$1"
    v="$(json_oneline "$file" | sed -n 's/.*"next":\(null\|"[^"]*"\).*/\1/p')"
    case "$v" in
        null|"")
            printf '\n'
            ;;
        \"*\")
            printf '%s\n' "$v" | sed 's/^"//; s/"$//'
            ;;
        *)
            printf '%s\n' "$v"
            ;;
    esac
}

sanitize_name() {
    printf '%s' "$1" \
    | tr '/\\:*?"<>|' '_' \
    | tr -cd '[:alnum:][:space:]_.-' \
    | sed 's/[[:space:]][[:space:]]*/ /g; s/^ *//; s/ *$//'
}

refresh_access_token() {
    out="$TMP_DIR/token.json"

    curl -fsS \
        -u "$SPOTIFY_CLIENT_ID:$SPOTIFY_CLIENT_SECRET" \
        -H 'Content-Type: application/x-www-form-urlencoded' \
        --data-urlencode 'grant_type=refresh_token' \
        --data-urlencode "refresh_token=$SPOTIFY_REFRESH_TOKEN" \
        "$TOKEN_URL" \
        -o "$out"

    ACCESS_TOKEN="$(json_get_string access_token "$out")"
    [ -n "$ACCESS_TOKEN" ] || {
        cat "$out" >&2
        die "unable to extract access_token"
    }
}

api_get() {
    url="$1"
    out="$2"

    [ -n "$ACCESS_TOKEN" ] || refresh_access_token

    hdr="$TMP_DIR/headers.txt"
    body="$out.tmp"

    while :; do
        code="$(
            curl -sS \
                -D "$hdr" \
                -H "Authorization: Bearer $ACCESS_TOKEN" \
                -H 'Accept: application/json' \
                -o "$body" \
                -w '%{http_code}' \
                "$url"
        )"

        case "$code" in
            200)
                mv "$body" "$out"
                return 0
                ;;
            401)
                #rm -f "$body"
                log "401 received, refreshing access token..."
                refresh_access_token
                ;;
            429)
                retry_after="$(
                    awk 'tolower($1)=="retry-after:" {print $2}' "$hdr" \
                    | tr -d '\r' \
                    | head -n 1
                )"
                [ -n "$retry_after" ] || retry_after=5
                #rm -f "$body"
                log "Rate limited, sleeping ${retry_after}s..."
                sleep "$retry_after"
                ;;
            *)
                log "HTTP $code for $url"
                if [ -s "$body" ]; then
                    sed 's/^/  /' "$body" >&2
                fi
                #rm -f "$body"
                exit 1
                ;;
        esac
    done
}

extract_ids_from_me_playlists_page() {
    file="$1"
    json_oneline "$file" \
    | sed 's/},{/}\n{/g' \
    | sed -n 's/.*"id":"\([^"]*\)".*/\1/p'
}

backup_profile() {
    log "Backing up user profile..."
    api_get "$API_BASE/me" "$ROOT_DIR/profile.json"
}

backup_playlists_index() {
    log "Listing playlists..."
    : > "$TMP_DIR/playlist_ids.txt"

    offset=0
    page=1

    while :; do
        out="$TMP_DIR/me-playlists-page-$(printf '%03d' "$page").json"
        url="$API_BASE/me/playlists?limit=50&offset=$offset&fields=items(id),next,total,limit,offset"

        api_get "$url" "$out"
        extract_ids_from_me_playlists_page "$out" >> "$TMP_DIR/playlist_ids.txt"

        next_url="$(json_get_next_url "$out")"
        [ -n "$next_url" ] || break

        offset=$((offset + 50))
        page=$((page + 1))
    done

    awk '!seen[$0]++' "$TMP_DIR/playlist_ids.txt" > "$TMP_DIR/playlist_ids.unique.txt"
}

backup_one_playlist() {
    playlist_id="$1"

    meta_tmp="$TMP_DIR/${playlist_id}.json"
    meta_url="$API_BASE/playlists/$playlist_id?fields=id,name,description,public,collaborative,snapshot_id,uri,external_urls(spotify),owner(id,display_name),followers(total),images,tracks(total)"

    api_get "$meta_url" "$meta_tmp"

    playlist_name="$(json_get_string name "$meta_tmp")"
    [ -n "$playlist_name" ] || playlist_name="$playlist_id"

    safe_name="$(sanitize_name "$playlist_name")"
    [ -n "$safe_name" ] || safe_name="$playlist_id"

    pl_dir="$PLAYLISTS_DIR/${safe_name}__${playlist_id}"
    mkdir -p "$pl_dir"

    mv "$meta_tmp" "$pl_dir/playlist.json"

    total_tracks="$(json_oneline "$pl_dir/playlist.json" | sed -n 's/.*"tracks":{"total":\([0-9][0-9]*\)}.*/\1/p')"
    [ -n "$total_tracks" ] || total_tracks="0"

    spotify_url="$(json_oneline "$pl_dir/playlist.json" | sed -n 's/.*"external_urls":{"spotify":"\([^"]*\)"}.*/\1/p')"
    [ -n "$spotify_url" ] || spotify_url=""

    owner_id="$(json_oneline "$pl_dir/playlist.json" | sed -n 's/.*"owner":{"id":"\([^"]*\)".*/\1/p')"
    [ -n "$owner_id" ] || owner_id=""

    printf '%s\t%s\t%s\t%s\t%s\n' \
        "$playlist_id" \
        "$playlist_name" \
        "$total_tracks" \
        "$spotify_url" \
        "$owner_id" >> "$MANIFEST"

    offset=0
    page=1

    while :; do
        out="$pl_dir/items-page-$(printf '%03d' "$page").json"
        url="$API_BASE/playlists/$playlist_id/items?limit=50&offset=$offset"

        hdr="$TMP_DIR/headers.txt"
        body="$out.tmp"

        code="$(
            curl -sS \
                -D "$hdr" \
                -H "Authorization: Bearer $ACCESS_TOKEN" \
                -H 'Accept: application/json' \
                -o "$body" \
                -w '%{http_code}' \
                "$url"
        )"

        case "$code" in
            200)
                mv "$body" "$out"
                next_url="$(json_get_next_url "$out")"
                [ -n "$next_url" ] || break
                offset=$((offset + 50))
                page=$((page + 1))
                ;;
            401)
                #rm -f "$body"
                log "401 on playlist items for $playlist_id, refreshing token..."
                refresh_access_token
                ;;
            429)
                retry_after="$(
                    awk 'tolower($1)=="retry-after:" {print $2}' "$hdr" \
                    | tr -d '\r' \
                    | head -n 1
                )"
                [ -n "$retry_after" ] || retry_after=5
                #rm -f "$body"
                log "Rate limited on playlist $playlist_id, sleeping ${retry_after}s..."
                sleep "$retry_after"
                ;;
            403)
                #rm -f "$body"
                printf 'tracks_skipped=403_forbidden\n' > "$pl_dir/NOTICE.txt"
                printf 'reason=get_playlist_items_forbidden\n' >> "$pl_dir/NOTICE.txt"
                log "Skipping items for playlist $playlist_id ($playlist_name): 403 Forbidden"
                break
                ;;
            *)
                log "HTTP $code for $url"
                if [ -s "$body" ]; then
                    sed 's/^/  /' "$body" >&2
                fi
                #rm -f "$body"
                exit 1
                ;;
        esac
    done
}

backup_liked_songs() {
    log "Backing up liked songs..."
    : > "$LIKED_DIR/manifest.txt"

    offset=0
    page=1
    total=""

    while :; do
        out="$LIKED_DIR/tracks-page-$(printf '%03d' "$page").json"
        url="$API_BASE/me/tracks?limit=50&offset=$offset&fields=items(added_at,track(id,name,uri,duration_ms,explicit,disc_number,track_number,artists(id,name,uri),album(id,name,uri,release_date,total_tracks),external_urls(spotify))),next,total,limit,offset"

        api_get "$url" "$out"

        if [ -z "$total" ]; then
            total="$(json_oneline "$out" | sed -n 's/.*"total":\([0-9][0-9]*\).*/\1/p')"
            [ -n "$total" ] || total="unknown"
            printf 'total_saved_tracks=%s\n' "$total" > "$LIKED_DIR/manifest.txt"
        fi

        next_url="$(json_get_next_url "$out")"
        [ -n "$next_url" ] || break

        offset=$((offset + 50))
        page=$((page + 1))
    done
}

backup_saved_albums() {
    log "Backing up saved albums..."
    : > "$ALBUMS_DIR/manifest.txt"

    offset=0
    page=1
    total=""

    while :; do
        out="$ALBUMS_DIR/albums-page-$(printf '%03d' "$page").json"
        url="$API_BASE/me/albums?limit=50&offset=$offset&fields=items(added_at,album(id,name,uri,album_type,total_tracks,release_date,artists(id,name,uri),images,external_urls(spotify))),next,total,limit,offset"

        api_get "$url" "$out"

        if [ -z "$total" ]; then
            total="$(json_oneline "$out" | sed -n 's/.*"total":\([0-9][0-9]*\).*/\1/p')"
            [ -n "$total" ] || total="unknown"
            printf 'total_saved_albums=%s\n' "$total" > "$ALBUMS_DIR/manifest.txt"
        fi

        next_url="$(json_get_next_url "$out")"
        [ -n "$next_url" ] || break

        offset=$((offset + 50))
        page=$((page + 1))
    done
}

token_get() {
	echo "1) check the declared URI on Spotify Developer Dashboard :" >&2
	echo "   $REDIRECT_URI" >&2
	echo >&2

	AUTH_REQUEST_URL="${AUTH_URL}?client_id=${SPOTIFY_CLIENT_ID}&response_type=code&redirect_uri=http%3A%2F%2F127.0.0.1%3A8888%2Fcallback&scope=${SCOPE}"

	echo "2) Open this URL in browser :" >&2
	echo >&2
	echo "$AUTH_REQUEST_URL" >&2
	echo >&2

	printf '3) Paste here the complete redirect URL : ' >&2
	IFS= read -r REDIRECTED_URL

	CODE="$(printf '%s\n' "$REDIRECTED_URL" | extract_code)"
	[ -n "$CODE" ] || {
		echo "Error: unable to extract code= from return URL !" >&2
		exit 1
	}

	TMP="${TMPDIR:-/tmp}/spotify-token-$$.json"
	trap 'rm -f "$TMP"' EXIT HUP INT TERM

	curl -fsS \
	  -u "$SPOTIFY_CLIENT_ID:$SPOTIFY_CLIENT_SECRET" \
	  -H 'Content-Type: application/x-www-form-urlencoded' \
	  --data-urlencode 'grant_type=authorization_code' \
	  --data-urlencode "code=$CODE" \
	  --data-urlencode "redirect_uri=$REDIRECT_URI" \
	  "$TOKEN_URL" \
	  -o "$TMP"

	ACCESS_TOKEN="$(json_get_string access_token "$TMP")"
	REFRESH_TOKEN="$(json_get_string refresh_token "$TMP")"

	[ -n "$ACCESS_TOKEN" ] || {
		echo "Error: access_token missing !" >&2
		cat "$TMP" >&2
		exit 1
	}

	[ -n "$REFRESH_TOKEN" ] || {
		echo "Error: refresh_token missing !" >&2
		cat "$TMP" >&2
		exit 1
	}

	echo
	echo "SPOTIFY_ACCESS_TOKEN=$ACCESS_TOKEN"
	echo "SPOTIFY_REFRESH_TOKEN=$REFRESH_TOKEN"
	echo
	echo "KEEP THE REFRESH TOKEN !"
}

main() {
    printf 'playlist_id\tname\ttotal_tracks\tspotify_url\towner_id\n' > "$MANIFEST"

    refresh_access_token
    backup_profile
    backup_playlists_index

    count=0
    while IFS= read -r playlist_id; do
        [ -n "$playlist_id" ] || continue
        count=$((count + 1))
        log "=== Playlist $count: $playlist_id ==="
        backup_one_playlist "$playlist_id"
    done < "$TMP_DIR/playlist_ids.unique.txt"

    backup_liked_songs
    backup_saved_albums

    log ""
    log "Backup completed: $ROOT_DIR"
    log "Manifest: $MANIFEST"
    log "Playlists backed up: $count"
    log "Liked songs directory: $LIKED_DIR"
    log "Saved albums directory: $ALBUMS_DIR"
}

case $@ in 
	token) echo "Getting only Spotify token" ; token_get ;;
	*) main $@ ;;
esac

