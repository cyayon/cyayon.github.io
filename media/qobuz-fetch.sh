#!/bin/sh
# Qobuz → JSON track extractor
# Usage:
#   ./fetch_qobuz.sh \
#     --app-id APP_ID \
#     --token YOUR_QOBUZ_TOKEN \
#     --outputdir ./here/
#     ./qobuz-fetch.sh --app-id <id> --token <token> [ --outputdir <dir> ]

#set -e

# keep previous export and rename to .old
#KEEP_OLD=1

# api url
QOBUZ_APIURL="https://www.qobuz.com/api.json/0.2"

# Config file
Config="/etc/nbux/qobuz-fetch.conf"

# load config if defined
if [ ! -z "$Config" ] && [ -f "$Config" ] ; then
    echo "NOTICE: loading config $Config"
    . $Config
    [ $? -ne 0 ] && echo "FATAL: while loading config $Config !" && exit 7
else
	# Parse arguments
	while [ $# -gt 0 ]; do
		case "$1" in
    		--app-id)   QOBUZ_APPID="$2";   shift 2 ;;
    		--token)    QOBUZ_TOKEN="$2";    shift 2 ;;
    		--outputdir)   OUTPUT_DIR="$2";   shift 2 ;;
    		*) echo "FATAL: unknown option: $1 !"; exit 9 ;;
  		esac
	done
fi

# output dir
[ -z "${OUTPUT_DIR}/" ] && OUTPUT_DIR="."
echo "Qobuz output directory is ${OUTPUT_DIR}/"

# Check required args
for var in QOBUZ_APIURL QOBUZ_APPID QOBUZ_TOKEN OUTPUT_DIR ; do
	eval "val=\$$var"
	if [ -z "$val" ]; then
		echo "FATAL : missing required arguments"
		exit 8
	fi
done


# mkdir output dir
if [ ! -d "${OUTPUT_DIR}/" ] ; then
	echo "mkdir -p ${OUTPUT_DIR}/" 
	mkdir -p "${OUTPUT_DIR}/"
	[ $? -ne 0 ] && echo "FATAL : unable to mkdir -p ${OUTPUT_DIR}/ !" && exit 9
fi


# fetch function
QbzFetch()
{
	[ -z "$1" ] && echo "usage : QbzFetch playlists|(favorites-)tracks/albums/artists|playlist_id" && return 9
	local fetch="$1"
	local response
	local response_ret
	local api_limit=500
	local count=0 
	local total=0 
	local offset=0 
	local fetch_url=""
	local fetch_arg=""
	local output=""
	local ret=0

	case $fetch in
		playlists) fetch_url="playlist/getUserPlaylists" ; fetch_arg=() ; output="${OUTPUT_DIR}/qobuz-${fetch}" ;;
		tracks|albums|artists) fetch_url="favorite/getUserFavorites" ; fetch_arg=(--data-urlencode "type=${fetch}") ; output="${OUTPUT_DIR}/qobuz-favorites-${fetch}" ;;
		*) fetch_url="/playlist/get" ; fetch_arg=(--data-urlencode "playlist_id=${fetch}") ; output="${OUTPUT_DIR}/qobuz-${fetch}" ;;
	esac

	if [ -f "${output}.json" ] && [ ! -z "$KEEP_OLD" ] && [ "$KEEP_OLD" = "1" ] ; then
		echo "Qobuz fetch preivous ${output}.json exist, moving to ${output}.json.old"
		mv "${output}.json" "${output}.json.old"
	fi

	#echo "Qobuz fetch $fetch begin"
	while true ; do
		#echo "Qobuz fetching $fetch (fetch_url:${fetch_url} offset:${offset})"
		response=$(curl -sf "${QOBUZ_APIURL}/${fetch_url}" --get --data-urlencode "limit=${api_limit}" --data-urlencode "offset=${offset}" --data-urlencode "extra=tracks" --data-urlencode "app_id=${QOBUZ_APPID}" --data-urlencode "user_auth_token=${QOBUZ_TOKEN}" "${fetch_arg[@]}" -o "${output}.${offset}.json" ) ; response_ret=$?
		if [ $response_ret -ne 0 ] ; then
			echo "FATAL : Qobuz fetch $fetch response (fetch_url:${fetch_url} offset:${offset} ret:${response_ret} response:${response}) !"
			return $response_ret
		fi
		#echo "Qobuz $fetch fetched (file:${output}.${offset}.json (offset:${offset})"
		case $fetch in
			playlists) 
				jq -r '.playlists.items[] | "\(.id)\t\(.name)"' ${output}.${offset}.json | tee "${output}.txt"
				PLAYLISTS_ID=$(jq -r '.playlists.items[] | "\(.id):\(.name)"' ${output}.${offset}.json | tr -d ' ' | tr '\012' ' ' 2>/dev/null)
				cat "${output}.${offset}.json" > "${output}.json"
				rm "${output}.${offset}.json"
				break ;;

			tracks|albums|artists)
				count=$(jq --arg i "$fetch" '.[$i].items | length' ${output}.${offset}.json 2>/dev/null)
				total=$(jq --arg i "$fetch" '.[$i].total' ${output}.${offset}.json 2>/dev/null)
				;;
	
			*)	
				count=$(jq '.tracks.items | length' ${output}.${offset}.json 2>/dev/null)
				total=$(jq '.tracks.total' ${output}.${offset}.json 2>/dev/null)
				;;
		esac

		#echo "Qobuz $fetch offset (file:${output}.${offset}.json count:${count} total:${total} offset:${offset})"
		if [ -z "$count" ] || [ $count -eq 0 ] ; then
			if [ -z "$total" ] || [ $total -eq 0 ] ; then
				echo "WARNING: Qobuz fetch $fetch empty (total:${total}) !"
				#mv "${output}.${offset}.json" "${output}.json"
				ret=1
			else
				echo "Qobuz no more to fetch $fetch (file:${output}.json total:${total})"
				rm "${output}.${offset}.json"
			fi
			break
		else
			#echo "Qobuz $fetch offset append (${output}.${offset}.json >> ${output}.json)"
			cat "${output}.${offset}.json" >> "${output}.json"
			rm "${output}.${offset}.json"
		fi
		offset=$((offset + api_limit))
	done

	#echo "Qobuz fetch $fetch finished (output:${output}.json)"
	return $ret
}


ret=0

echo
echo "Qobuz fetching playlists"
QbzFetch playlists ; r=$? ; [ $r -ne 0 ] && ret=$r
echo "PLAYLISTS_ID:[${PLAYLISTS_ID}]"

echo
for i in $PLAYLISTS_ID ; do
	echo "Qobuz fetching playlist $i"
	n=$(echo "$i" | cut -d: -f1) ; m=$(echo "$i" | cut -d: -f2)
	QbzFetch $n ; r=$? ; [ $r -ne 0 ] && ret=$r
	if [ -f "${OUTPUT_DIR}/qobuz-${n}.json" ] ; then
		echo "Qobuz format playlist $n (file:${OUTPUT_DIR}/qobuz-${n}.json format:${OUTPUT_DIR}/qobuz-${m}-${n}.txt)"
		echo "# Qobuz format playlist ${m}-${n} - $(date)" > "${OUTPUT_DIR}/qobuz-${m}-${n}.txt"
		cat "${OUTPUT_DIR}/qobuz-${n}.json" | jq '
		  [ .tracks.items[] |
			{
			  title:    .title,
			  artist:   (.performer.name? // ""),
			  album:    (.album.title? // ""),
			  isrc:     .isrc,
			  duration: .duration
			}
		  ]' >> "${OUTPUT_DIR}/qobuz-${m}-${n}.txt"
	fi
	echo
done

echo
for i in tracks albums artists ; do
	echo "Qobuz fetching favorites $i"
	QbzFetch $i ; r=$? ; [ $r -ne 0 ] && ret=$r
	# formatted output
	if [ -f "${OUTPUT_DIR}/qobuz-favorites-${i}.json" ] ; then
		echo "Qobuz format favorites $i (file:${OUTPUT_DIR}/qobuz-favorites-${i}.json format:${OUTPUT_DIR}/qobuz-favorites-${i}.txt)"
		echo "# Qobuz format favorites $i - $(date)" > "${OUTPUT_DIR}/qobuz-favorites-${i}.txt"
		case $i in
			tracks)
			cat "${OUTPUT_DIR}/qobuz-favorites-${i}.json" | jq '
			  [ .tracks.items[] |
				{
				  title:    .title,
				  artist:   (.performer.name? // ""),
				  album:    (.album.title? // ""),
				  isrc:     .isrc,
				  duration: .duration
				}
			  ]' >> "${OUTPUT_DIR}/qobuz-favorites-${i}.txt" ; r=$? ; [ $r -ne 0 ] && ret=$r ;;

		  	artists)
			cat "${OUTPUT_DIR}/qobuz-favorites-${i}.json" | jq '
			  [ .artists.items[] |
				{
				  artist:   (.name? // ""),
				  id:       (.id? // "")
				}
			  ]' >> "${OUTPUT_DIR}/qobuz-favorites-${i}.txt" ; r=$? ; [ $r -ne 0 ] && ret=$r ;;

		  	albums)
			cat "${OUTPUT_DIR}/qobuz-favorites-${i}.json" | jq '
			  [ .albums.items[] |
				{
				  artist:   (.artist.name? // ""),
				  album:    (.title? // ""),
				  label:    (.label.name? // ""),
				  upc: 		.upc,
				  duration: .duration
				}
			  ]' >> "${OUTPUT_DIR}/qobuz-favorites-${i}.txt" ; r=$? ; [ $r -ne 0 ] && ret=$r ;;
		esac
	fi
	echo
done

echo "exit $ret"
exit $ret
