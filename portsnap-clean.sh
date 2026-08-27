#!/bin/sh -e

# SPDX-License-Identifier: BSD-2-Clause

set -e
umask 077

CLEAN_APPLY=no
CLEAN_GRACE_DAYS=45
CLEAN_QUARANTINE_DAYS=30
CLEAN_MANIFEST_MAX_COMPRESSED=67108864
CLEAN_MANIFEST_MAX_EXPANDED=268435456
CLEAN_MANIFEST_MAX_RECORDS=5000000
CLEAN_MANIFEST_MAX_LINE=4096

usage () {
	echo "usage: $0 [--apply] [--grace-days days] [--quarantine-days days] pubdir" >&2
	exit 1
}

valid_days () {
	case $1 in
	''|*[!0-9]*) return 1 ;;
	esac
	[ $1 -le 3650 ]
}

while [ $# -gt 0 ]; do
	case $1 in
	--apply)
		CLEAN_APPLY=yes
		shift
		;;
	--grace-days)
		[ $# -ge 2 ] || usage
		valid_days "$2" || usage
		CLEAN_GRACE_DAYS=$2
		shift 2
		;;
	--quarantine-days)
		[ $# -ge 2 ] || usage
		valid_days "$2" || usage
		CLEAN_QUARANTINE_DAYS=$2
		shift 2
		;;
	--)
		shift
		break
		;;
	-*) usage ;;
	*) break ;;
	esac
done

[ $# -eq 1 ] || usage
CLEAN_PUBDIR_INPUT=$1
if [ -L "${CLEAN_PUBDIR_INPUT}" ] || ! [ -d "${CLEAN_PUBDIR_INPUT}" ]; then
	echo "Refusing invalid or symlinked publication directory" >&2
	exit 1
fi
CLEAN_PUBDIR=`cd "${CLEAN_PUBDIR_INPUT}" && pwd -P`
case ${CLEAN_PUBDIR} in
/|'')
	echo "Refusing unsafe publication directory ${CLEAN_PUBDIR}" >&2
	exit 1
	;;
esac

file_owner () {
	CLEAN_OWNER=`stat -f '%u' "$1" 2>/dev/null` || CLEAN_OWNER=
	case ${CLEAN_OWNER} in
	''|*[!0-9]*) stat -c '%u' "$1" 2>/dev/null ;;
	*) echo "${CLEAN_OWNER}" ;;
	esac
}

directory_is_private () {
	[ -z "`find "$1" -prune \( -perm -020 -o -perm -002 \) -print`" ]
}

CLEAN_EUID=`id -u`
CLEAN_PUBDIR_OWNER=`file_owner "${CLEAN_PUBDIR}"` || exit 1
if [ "${CLEAN_PUBDIR_OWNER}" != "${CLEAN_EUID}" ]; then
	echo "Run cleanup as the account which owns ${CLEAN_PUBDIR}" >&2
	exit 1
fi
if ! directory_is_private "${CLEAN_PUBDIR}"; then
	echo "Refusing group- or world-writable publication directory" >&2
	exit 1
fi

CLEAN_SUBDIRS="bp f s t"
if [ -e "${CLEAN_PUBDIR}/tp" ] || [ -L "${CLEAN_PUBDIR}/tp" ]; then
	CLEAN_SUBDIRS="${CLEAN_SUBDIRS} tp"
fi
for CLEAN_SUBDIR in ${CLEAN_SUBDIRS}; do
	if [ -L "${CLEAN_PUBDIR}/${CLEAN_SUBDIR}" ] ||
	    ! [ -d "${CLEAN_PUBDIR}/${CLEAN_SUBDIR}" ]; then
		echo "Missing or symlinked ${CLEAN_SUBDIR} directory" >&2
		exit 1
	fi
	CLEAN_SUBDIR_OWNER=`file_owner "${CLEAN_PUBDIR}/${CLEAN_SUBDIR}"` || exit 1
	if [ "${CLEAN_SUBDIR_OWNER}" != "${CLEAN_EUID}" ]; then
		echo "Refusing ${CLEAN_SUBDIR} directory owned by another account" >&2
		exit 1
	fi
	if ! directory_is_private "${CLEAN_PUBDIR}/${CLEAN_SUBDIR}"; then
		echo "Refusing group- or world-writable ${CLEAN_SUBDIR} directory" >&2
		exit 1
	fi
done

CLEAN_PARENT=${CLEAN_PUBDIR%/*}
[ -n "${CLEAN_PARENT}" ] || exit 1
CLEAN_PARENT_OWNER=`file_owner "${CLEAN_PARENT}"` || exit 1
if [ "${CLEAN_PARENT_OWNER}" != "${CLEAN_EUID}" ] ||
    ! directory_is_private "${CLEAN_PARENT}"; then
	echo "Refusing cleanup state parent not private to the web-root owner" >&2
	exit 1
fi
CLEAN_STATE_DIR=${CLEAN_PARENT}/.portsnap-clean
CLEAN_QUARANTINE_DIR=${CLEAN_STATE_DIR}/quarantine
if [ -L "${CLEAN_STATE_DIR}" ]; then
	echo "Refusing symlinked cleanup state directory" >&2
	exit 1
fi
if [ -e "${CLEAN_STATE_DIR}" ]; then
	CLEAN_STATE_OWNER=`file_owner "${CLEAN_STATE_DIR}"` || exit 1
	if [ "${CLEAN_STATE_OWNER}" != "${CLEAN_EUID}" ]; then
		echo "Refusing cleanup state owned by another account" >&2
		exit 1
	fi
	if ! directory_is_private "${CLEAN_STATE_DIR}"; then
		echo "Refusing group- or world-writable cleanup state" >&2
		exit 1
	fi
fi
if [ -L "${CLEAN_QUARANTINE_DIR}" ]; then
	echo "Refusing symlinked quarantine directory" >&2
	exit 1
fi
if [ -e "${CLEAN_QUARANTINE_DIR}" ]; then
	CLEAN_QUARANTINE_OWNER=`file_owner "${CLEAN_QUARANTINE_DIR}"` || exit 1
	if [ "${CLEAN_QUARANTINE_OWNER}" != "${CLEAN_EUID}" ] ||
	    ! directory_is_private "${CLEAN_QUARANTINE_DIR}"; then
		echo "Refusing quarantine directory not private to the web-root owner" >&2
		exit 1
	fi
fi

CLEAN_WRKDIR=`mktemp -d "${TMPDIR:-/tmp}/portsnap-clean.XXXXXX"` || exit 1
CLEAN_LOCKDIR=
cleanup () {
	if [ -n "${CLEAN_LOCKDIR}" ] && [ -d "${CLEAN_LOCKDIR}" ]; then
		rmdir "${CLEAN_LOCKDIR}" 2>/dev/null || true
	fi
	if [ -n "${CLEAN_WRKDIR}" ] && [ -d "${CLEAN_WRKDIR}" ]; then
		rm -r "${CLEAN_WRKDIR}"
	fi
}
trap cleanup 0
trap 'exit 1' 1 2 15

CLEAN_NOW=`date +%s`
case ${CLEAN_NOW} in
''|*[!0-9]*) exit 1 ;;
esac
CLEAN_GRACE_SECONDS=`awk -v days=${CLEAN_GRACE_DAYS} \
    'BEGIN { printf "%.0f", days * 86400 }'`
CLEAN_QUARANTINE_SECONDS=`awk -v days=${CLEAN_QUARANTINE_DAYS} \
    'BEGIN { printf "%.0f", days * 86400 }'`
CLEAN_CUTOFF=`expr ${CLEAN_NOW} - ${CLEAN_GRACE_SECONDS}`
CLEAN_QUARANTINE_CUTOFF=`expr ${CLEAN_NOW} - ${CLEAN_QUARANTINE_SECONDS}`

expand_manifest () {
	CLEAN_EXPAND_SOURCE=$1
	CLEAN_EXPAND_OUTPUT=$2
	CLEAN_EXPAND_FIFO=${CLEAN_WRKDIR}/manifest.fifo
	CLEAN_EXPAND_LIMIT=`expr ${CLEAN_MANIFEST_MAX_EXPANDED} + 1`

	if [ `wc -c < "${CLEAN_EXPAND_SOURCE}"` -gt \
	    ${CLEAN_MANIFEST_MAX_COMPRESSED} ]; then
		return 1
	fi
	rm -f "${CLEAN_EXPAND_FIFO}" "${CLEAN_EXPAND_OUTPUT}"
	mkfifo "${CLEAN_EXPAND_FIFO}"
	gunzip -c "${CLEAN_EXPAND_SOURCE}" > "${CLEAN_EXPAND_FIFO}" 2>/dev/null &
	CLEAN_EXPAND_PID=$!
	CLEAN_HEAD_STATUS=0
	head -c ${CLEAN_EXPAND_LIMIT} < "${CLEAN_EXPAND_FIFO}" \
	    > "${CLEAN_EXPAND_OUTPUT}" || CLEAN_HEAD_STATUS=$?
	CLEAN_GZIP_STATUS=0
	wait ${CLEAN_EXPAND_PID} || CLEAN_GZIP_STATUS=$?
	rm -f "${CLEAN_EXPAND_FIFO}"
	if [ ${CLEAN_HEAD_STATUS} -ne 0 ] || [ ${CLEAN_GZIP_STATUS} -ne 0 ] ||
	    [ `wc -c < "${CLEAN_EXPAND_OUTPUT}"` -gt \
	    ${CLEAN_MANIFEST_MAX_EXPANDED} ]; then
		return 1
	fi
}

for CLEAN_CONTROL in bl.gz tl.gz el.gz latest.ssl pub.ssl snapshot.ssl; do
	CLEAN_CONTROL_PATH=${CLEAN_PUBDIR}/${CLEAN_CONTROL}
	if [ -L "${CLEAN_CONTROL_PATH}" ] || ! [ -f "${CLEAN_CONTROL_PATH}" ]; then
		echo "Missing or symlinked ${CLEAN_CONTROL}" >&2
		exit 1
	fi
	cp "${CLEAN_CONTROL_PATH}" "${CLEAN_WRKDIR}/${CLEAN_CONTROL}"
done

for CLEAN_MANIFEST in bl tl el; do
	if ! expand_manifest "${CLEAN_WRKDIR}/${CLEAN_MANIFEST}.gz" \
	    "${CLEAN_WRKDIR}/${CLEAN_MANIFEST}"; then
		echo "Invalid or oversized ${CLEAN_MANIFEST}.gz" >&2
		exit 1
	fi
done

if ! awk -F '|' -v maxline=${CLEAN_MANIFEST_MAX_LINE} \
    -v maxrecords=${CLEAN_MANIFEST_MAX_RECORDS} '
	function hex64(value) {
		return length(value) == 64 && value !~ /[^0-9a-f]/
	}
	length($0) > maxline || NR > maxrecords || NF != 3 || $1 == "" ||
	    $2 !~ /^[0-9]+$/ || !hex64($3) { bad = 1; exit }
	END { if (NR == 0 || bad) exit 1 }
' "${CLEAN_WRKDIR}/bl"; then
	echo "Malformed bl.gz" >&2
	exit 1
fi

if ! awk -F '|' -v maxline=${CLEAN_MANIFEST_MAX_LINE} \
    -v maxrecords=${CLEAN_MANIFEST_MAX_RECORDS} '
	function hex64(value) {
		return length(value) == 64 && value !~ /[^0-9a-f]/
	}
	length($0) > maxline || NR > maxrecords || NF != 3 || $1 == "" ||
	    $2 !~ /^[0-9]+$/ || !hex64($3) { bad = 1; exit }
	END { if (NR == 0 || bad) exit 1 }
' "${CLEAN_WRKDIR}/tl"; then
	echo "Malformed tl.gz" >&2
	exit 1
fi

if ! awk -v maxline=${CLEAN_MANIFEST_MAX_LINE} \
    -v maxrecords=${CLEAN_MANIFEST_MAX_RECORDS} '
	function hex64(value) {
		return length(value) == 64 && value !~ /[^0-9a-f]/
	}
	{
		if (length($0) > maxline || NR > maxrecords) {
			bad = 1
			exit
		}
		if (substr($0, 1, 2) == "t/" && hex64(substr($0, 3))) {
			tags++
			tag_hash[substr($0, 3)] = 1
			next
		}
		if (substr($0, 1, 2) == "s/" &&
		    substr($0, length($0) - 3) == ".tgz" &&
		    hex64(substr($0, 3, length($0) - 6))) {
			snapshots++
			snapshot_hash[substr($0, 3, length($0) - 6)] = 1
			next
		}
		bad = 1
		exit
	}
	END {
		for (hash in snapshot_hash)
			if (!(hash in tag_hash)) bad = 1
		if (NR == 0 || tags == 0 || snapshots == 0 || bad) exit 1
	}
' "${CLEAN_WRKDIR}/el"; then
	echo "Malformed el.gz" >&2
	exit 1
fi

controls_unchanged () {
	for CLEAN_CONTROL in bl.gz tl.gz el.gz latest.ssl pub.ssl snapshot.ssl; do
		[ -f "${CLEAN_PUBDIR}/${CLEAN_CONTROL}" ] &&
		    ! [ -L "${CLEAN_PUBDIR}/${CLEAN_CONTROL}" ] || return 1
		cmp -s "${CLEAN_WRKDIR}/${CLEAN_CONTROL}" \
		    "${CLEAN_PUBDIR}/${CLEAN_CONTROL}" || return 1
	done
}

if ! controls_unchanged; then
	echo "Publication changed while manifests were being read; retry later" >&2
	exit 1
fi

awk -F '|' '{ print $3 }' "${CLEAN_WRKDIR}/bl" | sort -u \
    > "${CLEAN_WRKDIR}/bl.hashes"
awk -F '|' '{ print $3 }' "${CLEAN_WRKDIR}/tl" | sort -u \
    > "${CLEAN_WRKDIR}/tl.hashes"

: > "${CLEAN_WRKDIR}/live"
awk '{ print "f/" $1 ".gz" }' "${CLEAN_WRKDIR}/bl.hashes" \
    "${CLEAN_WRKDIR}/tl.hashes" >> "${CLEAN_WRKDIR}/live"
sed -n -e '/^t\//p' -e '/^s\//p' "${CLEAN_WRKDIR}/el" \
    >> "${CLEAN_WRKDIR}/live"

: > "${CLEAN_WRKDIR}/present"
: > "${CLEAN_WRKDIR}/unexpected"
: > "${CLEAN_WRKDIR}/tp.names"
for CLEAN_SUBDIR in ${CLEAN_SUBDIRS}; do
	( cd "${CLEAN_PUBDIR}/${CLEAN_SUBDIR}" &&
	    find . -maxdepth 1 -type f -print ) |
	    sed 's#^\./##' > "${CLEAN_WRKDIR}/${CLEAN_SUBDIR}.all"
	case ${CLEAN_SUBDIR} in
	bp)
		grep -E '^[0-9a-f]{64}-[0-9a-f]{64}$' \
		    "${CLEAN_WRKDIR}/${CLEAN_SUBDIR}.all" \
		    > "${CLEAN_WRKDIR}/${CLEAN_SUBDIR}.names" || true
		;;
	f)
		grep -E '^[0-9a-f]{64}\.gz$' \
		    "${CLEAN_WRKDIR}/${CLEAN_SUBDIR}.all" \
		    > "${CLEAN_WRKDIR}/${CLEAN_SUBDIR}.names" || true
		;;
	s)
		grep -E '^[0-9a-f]{64}\.tgz$' \
		    "${CLEAN_WRKDIR}/${CLEAN_SUBDIR}.all" \
		    > "${CLEAN_WRKDIR}/${CLEAN_SUBDIR}.names" || true
		;;
	t)
		grep -E '^[0-9a-f]{64}$' \
		    "${CLEAN_WRKDIR}/${CLEAN_SUBDIR}.all" \
		    > "${CLEAN_WRKDIR}/${CLEAN_SUBDIR}.names" || true
		;;
	tp)
		grep -E '^[0-9a-f]{64}-[0-9a-f]{64}\.gz$' \
		    "${CLEAN_WRKDIR}/${CLEAN_SUBDIR}.all" \
		    > "${CLEAN_WRKDIR}/${CLEAN_SUBDIR}.names" || true
		;;
	esac
	sed "s#^#${CLEAN_SUBDIR}/#" \
	    "${CLEAN_WRKDIR}/${CLEAN_SUBDIR}.names" \
	    >> "${CLEAN_WRKDIR}/present"
	sort -u "${CLEAN_WRKDIR}/${CLEAN_SUBDIR}.all" \
	    > "${CLEAN_WRKDIR}/${CLEAN_SUBDIR}.all.sorted"
	sort -u "${CLEAN_WRKDIR}/${CLEAN_SUBDIR}.names" \
	    > "${CLEAN_WRKDIR}/${CLEAN_SUBDIR}.names.sorted"
	comm -23 "${CLEAN_WRKDIR}/${CLEAN_SUBDIR}.all.sorted" \
	    "${CLEAN_WRKDIR}/${CLEAN_SUBDIR}.names.sorted" |
	    sed "s#^#${CLEAN_SUBDIR}/#" \
	    >> "${CLEAN_WRKDIR}/unexpected" || true
done

awk '
	NR == FNR { hashes[$1] = 1; next }
	{
		split($0, pair, "-")
		if (hashes[pair[1]] && hashes[pair[2]]) print "bp/" $0
	}
' "${CLEAN_WRKDIR}/bl.hashes" "${CLEAN_WRKDIR}/bp.names" \
    >> "${CLEAN_WRKDIR}/live"
sed 's/\.gz$//' "${CLEAN_WRKDIR}/tp.names" > "${CLEAN_WRKDIR}/tp.pairs"
awk '
	NR == FNR { hashes[$1] = 1; next }
	{
		split($0, pair, "-")
		if (hashes[pair[1]] && hashes[pair[2]]) print "tp/" $0 ".gz"
	}
' "${CLEAN_WRKDIR}/tl.hashes" "${CLEAN_WRKDIR}/tp.pairs" \
    >> "${CLEAN_WRKDIR}/live"

sort -u "${CLEAN_WRKDIR}/live" > "${CLEAN_WRKDIR}/live.sorted"
sort -u "${CLEAN_WRKDIR}/present" > "${CLEAN_WRKDIR}/present.sorted"
comm -23 "${CLEAN_WRKDIR}/present.sorted" \
    "${CLEAN_WRKDIR}/live.sorted" > "${CLEAN_WRKDIR}/candidates"

if [ ${CLEAN_APPLY} = yes ]; then
	mkdir -p "${CLEAN_STATE_DIR}" "${CLEAN_QUARANTINE_DIR}"
	chmod 700 "${CLEAN_STATE_DIR}" "${CLEAN_QUARANTINE_DIR}"
	CLEAN_LOCKDIR=${CLEAN_STATE_DIR}/lock
	if ! mkdir "${CLEAN_LOCKDIR}" 2>/dev/null; then
		echo "Another cleanup run is active, or ${CLEAN_LOCKDIR} is stale" >&2
		exit 1
	fi
fi

: > "${CLEAN_WRKDIR}/old-state"
if [ -f "${CLEAN_STATE_DIR}/candidates" ]; then
	if [ -L "${CLEAN_STATE_DIR}/candidates" ]; then
		echo "Refusing symlinked cleanup state" >&2
		exit 1
	fi
	cp "${CLEAN_STATE_DIR}/candidates" "${CLEAN_WRKDIR}/old-state"
	if ! awk -F '|' '
		NF != 2 || $1 == "" || $1 ~ /[^0-9a-z.\/-]/ ||
		    $1 ~ /\.\./ || $1 !~ /^(bp|f|s|t|tp)\// ||
		    $2 !~ /^[0-9]+$/ { exit 1 }
	' "${CLEAN_WRKDIR}/old-state"; then
		echo "Malformed cleanup state" >&2
		exit 1
	fi
fi

awk -F '|' -v now=${CLEAN_NOW} '
	FILENAME == ARGV[1] { first_seen[$1] = $2; next }
	{
		if ($1 in first_seen) print $1 "|" first_seen[$1]
		else print $1 "|" now
	}
' "${CLEAN_WRKDIR}/old-state" "${CLEAN_WRKDIR}/candidates" |
    sort -t '|' -k 1,1 > "${CLEAN_WRKDIR}/new-state"
awk -F '|' -v cutoff=${CLEAN_CUTOFF} '$2 <= cutoff { print $1 }' \
    "${CLEAN_WRKDIR}/new-state" > "${CLEAN_WRKDIR}/due"

: > "${CLEAN_WRKDIR}/purge"
if [ -d "${CLEAN_QUARANTINE_DIR}" ] &&
    ! [ -L "${CLEAN_QUARANTINE_DIR}" ]; then
	for CLEAN_BATCH in "${CLEAN_QUARANTINE_DIR}"/*; do
		[ -e "${CLEAN_BATCH}" ] || continue
		[ -d "${CLEAN_BATCH}" ] && ! [ -L "${CLEAN_BATCH}" ] || continue
		CLEAN_BATCH_NAME=${CLEAN_BATCH##*/}
		CLEAN_BATCH_TIME=${CLEAN_BATCH_NAME%%.*}
		CLEAN_BATCH_PID=${CLEAN_BATCH_NAME#*.}
		case ${CLEAN_BATCH_TIME} in
		''|*[!0-9]*) continue ;;
		esac
		case ${CLEAN_BATCH_PID} in
		''|*[!0-9]*) continue ;;
		esac
		if [ ${CLEAN_BATCH_TIME} -lt ${CLEAN_QUARANTINE_CUTOFF} ]; then
			echo "${CLEAN_BATCH}" >> "${CLEAN_WRKDIR}/purge"
		fi
	done
fi

CLEAN_PRESENT_COUNT=`wc -l < "${CLEAN_WRKDIR}/present.sorted"`
CLEAN_LIVE_COUNT=`wc -l < "${CLEAN_WRKDIR}/live.sorted"`
CLEAN_CANDIDATE_COUNT=`wc -l < "${CLEAN_WRKDIR}/candidates"`
CLEAN_DUE_COUNT=`wc -l < "${CLEAN_WRKDIR}/due"`
CLEAN_PURGE_COUNT=`wc -l < "${CLEAN_WRKDIR}/purge"`
echo "`date`: ${CLEAN_PRESENT_COUNT} managed objects, ${CLEAN_LIVE_COUNT} live paths"
echo "`date`: ${CLEAN_CANDIDATE_COUNT} unreferenced, ${CLEAN_DUE_COUNT} past the ${CLEAN_GRACE_DAYS}-day grace period"
echo "`date`: ${CLEAN_PURGE_COUNT} quarantine batches past the ${CLEAN_QUARANTINE_DAYS}-day retention period"
while read CLEAN_UNEXPECTED; do
	[ -n "${CLEAN_UNEXPECTED}" ] || continue
	echo "Ignoring unexpected file ${CLEAN_UNEXPECTED}" >&2
done < "${CLEAN_WRKDIR}/unexpected"

if [ ${CLEAN_APPLY} = no ]; then
	while read CLEAN_DUE_PATH; do
		[ -n "${CLEAN_DUE_PATH}" ] || continue
		echo "Would quarantine ${CLEAN_DUE_PATH}"
	done < "${CLEAN_WRKDIR}/due"
	while read CLEAN_PURGE_PATH; do
		[ -n "${CLEAN_PURGE_PATH}" ] || continue
		echo "Would purge ${CLEAN_PURGE_PATH}"
	done < "${CLEAN_WRKDIR}/purge"
	echo "Dry run only; use --apply to update state and quarantine objects"
	exit 0
fi

if ! controls_unchanged; then
	echo "Publication changed before cleanup; retry later" >&2
	exit 1
fi

CLEAN_BATCH_DIR=
if [ -s "${CLEAN_WRKDIR}/due" ]; then
	CLEAN_BATCH_DIR=${CLEAN_QUARANTINE_DIR}/${CLEAN_NOW}.$$
	mkdir "${CLEAN_BATCH_DIR}"
	while read CLEAN_DUE_PATH; do
		[ -n "${CLEAN_DUE_PATH}" ] || continue
		CLEAN_SOURCE=${CLEAN_PUBDIR}/${CLEAN_DUE_PATH}
		if [ -L "${CLEAN_SOURCE}" ] || ! [ -f "${CLEAN_SOURCE}" ]; then
			echo "Candidate changed before quarantine: ${CLEAN_DUE_PATH}" >&2
			exit 1
		fi
		CLEAN_DESTDIR=${CLEAN_BATCH_DIR}/${CLEAN_DUE_PATH%/*}
		mkdir -p "${CLEAN_DESTDIR}"
		mv "${CLEAN_SOURCE}" "${CLEAN_DESTDIR}/"
		echo "Quarantined ${CLEAN_DUE_PATH}"
	done < "${CLEAN_WRKDIR}/due"
fi

awk -F '|' '
	FILENAME == ARGV[1] { due[$1] = 1; next }
	!($1 in due) { print }
' "${CLEAN_WRKDIR}/due" "${CLEAN_WRKDIR}/new-state" \
    > "${CLEAN_STATE_DIR}/candidates.new"
mv "${CLEAN_STATE_DIR}/candidates.new" "${CLEAN_STATE_DIR}/candidates"

while read CLEAN_PURGE_PATH; do
	[ -n "${CLEAN_PURGE_PATH}" ] || continue
	case ${CLEAN_PURGE_PATH} in
	"${CLEAN_QUARANTINE_DIR}"/*) ;;
	*)
		echo "Refusing unsafe quarantine purge path" >&2
		exit 1
		;;
	esac
	rm -r "${CLEAN_PURGE_PATH}"
	echo "Purged ${CLEAN_PURGE_PATH}"
done < "${CLEAN_WRKDIR}/purge"

echo "`date`: Cleanup complete"
