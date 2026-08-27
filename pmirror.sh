#!/bin/sh -e

#-
# Copyright 2005 Colin Percival
# All rights reserved
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted providing that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
# IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
# WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
# DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
# OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
# STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
# IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.

# READ THIS BEFORE USING THIS CODE
# --------------------------------
#
# On average, portsnap requires 2-5MB/month of bandwidth to keep a
# single machine up to date.  If several machines are sharing an
# HTTP proxy, a significant fraction of this can be cached.
#
# In contrast, using this code to keep a portsnap *mirror* up to
# date requires roughly 1GB of disk space and 5GB/month of bandwidth.
# This is because of the "graceful failure" mechanisms built into
# portsnap -- it can usually take advantage of pregenerated patches,
# but a mirror needs to have lots of larger files just in case they
# are needed.
#
# This means that, in terms of bandwidth, running a portsnap mirror
# is completely and utterly pointless unless you expect more than
# 1000 portsnap-running systems to be using the mirror.  In fact,
# it's worse than pointless, since it would consume bandwidth and
# increase the load on existing mirrors (since the mirroring would
# require more work than serving those <1000 machines from the
# existing mirrors).
#
# For reference, the number of systems running portsnap at the end
# of 2005 is roughly 4500.
#
# In short: Even if you already run MidnightBSD FTP
# mirrors, you shouldn't necessarily start running a portsnap mirror
# as well. 

# Usage:
# lockf -s -t 0 lockfile	\
#	sh -e pmirror.sh portsnap1.midnightbsd.org /path/to/www

if [ $# -ne 2 ]; then
	echo "Usage: pmirror.sh portsnap1.midnightbsd.org /path/to/www"
	exit 1
fi

WRKDIR=`mktemp -d -t pmirror` || exit 1
chown :`id -ng` ${WRKDIR}
cd ${WRKDIR}

STAGEDIR=
cleanup () {
	cd /tmp/
	if [ -n "${STAGEDIR}" ] && [ -d "${STAGEDIR}" ]; then
		rm -r "${STAGEDIR}"
	fi
	if [ -d "${WRKDIR}" ]; then
		rm -r "${WRKDIR}"
	fi
}
trap cleanup 0
trap 'exit 1' 1 2 15

SERVER=$1
PUBDIR=$2
PHTTPGET="/usr/libexec/phttpget ${SERVER}"
BSPATCH=/usr/bin/bspatch
SNAPSHOT_MAX_ARCHIVE_BYTES=268435456
SNAPSHOT_MAX_EXPANDED_BYTES=1073741824
OBJECT_MAX_EXPANDED_BYTES=67108864
OBJECT_MAX_SOURCE_BYTES=67108864
METADATA_PATCH_MAX_SOURCE_BYTES=100000

# Bounded gzip expansion which requires the producer to reach a clean EOF.  The
# FIFO lets POSIX sh preserve both command statuses without non-portable
# pipefail.  COUNT is one MiB block beyond MAX_BYTES so oversize streams fail.
expand_gzip_file () {
	EXPAND_GZIP_SOURCE=$1
	EXPAND_GZIP_OUTPUT=$2
	EXPAND_GZIP_MAX_BYTES=$3
	EXPAND_GZIP_COUNT=$4
	EXPAND_GZIP_FIFO=${WRKDIR}/gzip.verify.fifo

	rm -f "${EXPAND_GZIP_FIFO}" "${EXPAND_GZIP_OUTPUT}"
	mkfifo "${EXPAND_GZIP_FIFO}"
	gunzip -c "${EXPAND_GZIP_SOURCE}" > "${EXPAND_GZIP_FIFO}" 2>/dev/null &
	EXPAND_GZIP_PID=$!
	EXPAND_GZIP_DD_STATUS=0
	dd if="${EXPAND_GZIP_FIFO}" of="${EXPAND_GZIP_OUTPUT}" \
	    bs=1048576 count=${EXPAND_GZIP_COUNT} 2>/dev/null ||
	    EXPAND_GZIP_DD_STATUS=$?
	EXPAND_GZIP_STATUS=0
	wait ${EXPAND_GZIP_PID} || EXPAND_GZIP_STATUS=$?
	rm -f "${EXPAND_GZIP_FIFO}"
	if [ ${EXPAND_GZIP_DD_STATUS} -ne 0 ] ||
	    [ ${EXPAND_GZIP_STATUS} -ne 0 ] ||
	    [ `wc -c < "${EXPAND_GZIP_OUTPUT}"` -gt \
	    ${EXPAND_GZIP_MAX_BYTES} ]; then
		return 1
	fi
	return 0
}

hash_gzip_file () {
	HASH_GZIP_SOURCE=$1
	HASH_GZIP_OUTPUT=$2

	expand_gzip_file "${HASH_GZIP_SOURCE}" "${HASH_GZIP_OUTPUT}" \
	    ${OBJECT_MAX_EXPANDED_BYTES} 65 || return 1
	sha256 < "${HASH_GZIP_OUTPUT}"
}

# Read the signed little-endian target size from a BSDIFF40 header.  Reject
# malformed and oversized declarations before bspatch can allocate its output.
binary_patch_target_size () {
	BINARY_PATCH_PATH=$1

	if [ `wc -c < "${BINARY_PATCH_PATH}"` -lt 32 ] ||
	    [ "`dd if="${BINARY_PATCH_PATH}" bs=1 count=8 2>/dev/null`" != \
	    BSDIFF40 ]; then
		return 1
	fi
	od -An -tu1 -j 24 -N 8 "${BINARY_PATCH_PATH}" 2>/dev/null |
	    awk '
	        NF != 8 { exit 1 }
	        {
	            value = $8 % 128
	            for (i = 7; i >= 1; i--)
	                value = value * 256 + $i
	            if ($8 >= 128)
	                value = -value
	            printf "%.0f\n", value
	        }
	    '
}

# Fetch a list of missing files into the private staging directory.  Keep the
# phttpget status separate from the filtered log output so a failed transfer
# always aborts the run.
fetch_missing_files () {
	FETCH_SUBDIR=$1
	FETCH_MISSING=$2
	FETCH_LIST=${WRKDIR}/${FETCH_SUBDIR}.fetch
	FETCH_LOG=${WRKDIR}/${FETCH_SUBDIR}.fetch.log

	if ! [ -s "${FETCH_MISSING}" ]; then
		return 0
	fi

	lam -s "${FETCH_SUBDIR}/" "${FETCH_MISSING}" > "${FETCH_LIST}"
	if ! ( cd "${STAGEDIR}/${FETCH_SUBDIR}" && \
	    xargs ${PHTTPGET} < "${FETCH_LIST}" ) \
	    > "${FETCH_LOG}" 2>&1; then
		grep -v "200 OK" "${FETCH_LOG}" || true
		echo "Failed to fetch required ${FETCH_SUBDIR} files" >&2
		return 1
	fi
	grep -v "200 OK" "${FETCH_LOG}" || true

	while read FETCH_FILE; do
		if ! [ -f "${STAGEDIR}/${FETCH_SUBDIR}/${FETCH_FILE}" ]; then
			echo "Missing staged ${FETCH_SUBDIR}/${FETCH_FILE}" >&2
			return 1
		fi
	done < "${FETCH_MISSING}"
}

install_staged_files () {
	INSTALL_SUBDIR=$1
	INSTALL_MISSING=$2

	while read INSTALL_FILE; do
		INSTALL_DEST=${PUBDIR}/${INSTALL_SUBDIR}/${INSTALL_FILE}
		if [ -e "${INSTALL_DEST}" ] && [ ! -f "${INSTALL_DEST}" ] &&
		    [ ! -L "${INSTALL_DEST}" ]; then
			echo "Refusing to replace unexpected ${INSTALL_SUBDIR}/${INSTALL_FILE} object type" >&2
			return 1
		fi
		mv -f "${STAGEDIR}/${INSTALL_SUBDIR}/${INSTALL_FILE}" \
		    "${INSTALL_DEST}"
	done < "${INSTALL_MISSING}"
}

quarantine_unrepaired_files () {
	QUARANTINE_SUBDIR=$1
	QUARANTINE_INVALID=$2
	QUARANTINE_REPAIRED=$3
	QUARANTINE_LIST=${WRKDIR}/${QUARANTINE_SUBDIR}.quarantine

	comm -23 "${QUARANTINE_INVALID}" "${QUARANTINE_REPAIRED}" \
	    > "${QUARANTINE_LIST}"
	while read QUARANTINE_FILE; do
		QUARANTINE_PATH=${PUBDIR}/${QUARANTINE_SUBDIR}/${QUARANTINE_FILE}
		if [ -e "${QUARANTINE_PATH}" ] || [ -L "${QUARANTINE_PATH}" ]; then
			if [ ! -f "${QUARANTINE_PATH}" ] &&
			    [ ! -L "${QUARANTINE_PATH}" ]; then
				echo "Refusing to quarantine unexpected ${QUARANTINE_SUBDIR}/${QUARANTINE_FILE} object type" >&2
				return 1
			fi
			mkdir -p "${STAGEDIR}/quarantine/${QUARANTINE_SUBDIR}"
			mv "${QUARANTINE_PATH}" \
			    "${STAGEDIR}/quarantine/${QUARANTINE_SUBDIR}/${QUARANTINE_FILE}"
		fi
	done < "${QUARANTINE_LIST}"
}

verify_required_files () {
	VERIFY_SUBDIR=$1
	VERIFY_WANTED=$2

	while read VERIFY_FILE; do
		if ! [ -f "${PUBDIR}/${VERIFY_SUBDIR}/${VERIFY_FILE}" ]; then
			echo "Missing required ${VERIFY_SUBDIR}/${VERIFY_FILE}" >&2
			return 1
		fi
	done < "${VERIFY_WANTED}"
}

# Return a stable, private copy for validation.  Published files are never
# moved aside before a validated replacement is ready: installation atomically
# replaces a regular file or symlink, while a failed run leaves publication
# unchanged.  Unexpected node types are an operator error and abort the run.
validation_path () {
	VALIDATION_BASE=$1
	VALIDATION_SUBDIR=$2
	VALIDATION_FILE=$3
	VALIDATION_SOURCE=${VALIDATION_BASE}/${VALIDATION_SUBDIR}/${VALIDATION_FILE}

	if [ ! -e "${VALIDATION_SOURCE}" ] && [ ! -L "${VALIDATION_SOURCE}" ]; then
		return 1
	fi
	if [ -L "${VALIDATION_SOURCE}" ]; then
		return 1
	fi
	if [ ! -f "${VALIDATION_SOURCE}" ]; then
		echo "Unexpected ${VALIDATION_SUBDIR}/${VALIDATION_FILE} object type" >&2
		return 2
	fi
	case ${VALIDATION_SUBDIR} in
	s) VALIDATION_MAX_BYTES=${SNAPSHOT_MAX_ARCHIVE_BYTES} ;;
	tp) VALIDATION_MAX_BYTES=${METADATA_PATCH_MAX_SOURCE_BYTES} ;;
	*) VALIDATION_MAX_BYTES=${OBJECT_MAX_SOURCE_BYTES} ;;
	esac
	VALIDATION_SIZE=`wc -c < "${VALIDATION_SOURCE}"` || return 2
	if [ ${VALIDATION_SIZE} -gt ${VALIDATION_MAX_BYTES} ]; then
		echo "Oversized ${VALIDATION_SUBDIR}/${VALIDATION_FILE}" >&2
		return 1
	fi
	if [ "${VALIDATION_BASE}" = "${STAGEDIR}" ]; then
		echo "${VALIDATION_SOURCE}"
		return 0
	fi
	if ! mkdir -p "${STAGEDIR}/scrub/${VALIDATION_SUBDIR}"; then
		return 2
	fi
	VALIDATION_COPY=${STAGEDIR}/scrub/${VALIDATION_SUBDIR}/${VALIDATION_FILE}
	if ! cp "${VALIDATION_SOURCE}" "${VALIDATION_COPY}"; then
		return 2
	fi
	echo "${VALIDATION_COPY}"
}

find_valid_object () {
	FIND_SUBDIR=$1
	FIND_FILE=$2

	if [ -f "${STAGEDIR}/${FIND_SUBDIR}/${FIND_FILE}" ] &&
	    [ ! -L "${STAGEDIR}/${FIND_SUBDIR}/${FIND_FILE}" ]; then
		echo "${STAGEDIR}/${FIND_SUBDIR}/${FIND_FILE}"
		return 0
	fi
	if [ -f "${STAGEDIR}/scrub/${FIND_SUBDIR}/${FIND_FILE}" ] &&
	    [ ! -L "${STAGEDIR}/scrub/${FIND_SUBDIR}/${FIND_FILE}" ]; then
		echo "${STAGEDIR}/scrub/${FIND_SUBDIR}/${FIND_FILE}"
		return 0
	fi
	return 1
}

# The publication directory must be writable only by the mirror operator.
# Reject symlinks and validate content-addressed objects before treating an
# existing object as usable.  Invalid objects are omitted from the valid list
# so they are fetched into the private staging directory and replaced.
validate_content_addressed_files () {
	VALIDATE_BASE=$1
	VALIDATE_SUBDIR=$2
	VALIDATE_WANTED=$3
	VALIDATE_VALID=$4

	: > "${VALIDATE_VALID}"
	while read VALIDATE_FILE; do
		VALIDATE_PATH=`validation_path "${VALIDATE_BASE}" \
		    "${VALIDATE_SUBDIR}" "${VALIDATE_FILE}"` || {
			VALIDATE_STATUS=$?
			if [ ${VALIDATE_STATUS} -eq 2 ]; then return 1; fi
			VALIDATE_PATH=
		}
		VALIDATE_HASH=
		case ${VALIDATE_SUBDIR} in
		f)
			if [ -f "${VALIDATE_PATH}" ] &&
			    [ ! -L "${VALIDATE_PATH}" ]; then
				VALIDATE_HASH=`hash_gzip_file "${VALIDATE_PATH}" \
				    "${WRKDIR}/f.verify.uncompressed"` || true
			fi
			VALIDATE_EXPECTED=${VALIDATE_FILE%.gz}
			;;
		t)
			if [ -f "${VALIDATE_PATH}" ] &&
			    [ ! -L "${VALIDATE_PATH}" ]; then
				VALIDATE_HASH=`sha256 < "${VALIDATE_PATH}"`
			fi
			VALIDATE_EXPECTED=${VALIDATE_FILE}
			;;
		*)
			echo "Cannot content-validate ${VALIDATE_SUBDIR} files" >&2
			return 1
			;;
		esac

		if [ "${VALIDATE_HASH}" = "${VALIDATE_EXPECTED}" ]; then
			echo "${VALIDATE_FILE}" >> "${VALIDATE_VALID}"
		else
			echo "Invalid ${VALIDATE_SUBDIR}/${VALIDATE_FILE}" >&2
		fi
	done < "${VALIDATE_WANTED}"
}

validate_binary_patches () {
	VALIDATE_BASE=$1
	VALIDATE_WANTED=$2
	VALIDATE_VALID=$3
	VALIDATE_OLD=${WRKDIR}/bp.verify.old
	VALIDATE_NEW=${WRKDIR}/bp.verify.new

	: > "${VALIDATE_VALID}"
	while read VALIDATE_FILE; do
		VALIDATE_PATH=`validation_path "${VALIDATE_BASE}" bp \
		    "${VALIDATE_FILE}"` || {
			VALIDATE_STATUS=$?
			if [ ${VALIDATE_STATUS} -eq 2 ]; then return 1; fi
			VALIDATE_PATH=
		}
		VALIDATE_FROM=${VALIDATE_FILE%-*}
		VALIDATE_TO=${VALIDATE_FILE#*-}
		VALIDATE_SOURCE=
		VALIDATE_HASH=
		VALIDATE_SOURCE=`find_valid_object f "${VALIDATE_FROM}.gz"` || true
		VALIDATE_TARGET_SIZE=
		if [ -n "${VALIDATE_PATH}" ]; then
			VALIDATE_TARGET_SIZE=`binary_patch_target_size \
			    "${VALIDATE_PATH}"` || true
		fi
		rm -f "${VALIDATE_OLD}" "${VALIDATE_NEW}"
		if [ -f "${VALIDATE_PATH}" ] && [ ! -L "${VALIDATE_PATH}" ] &&
		    [ -n "${VALIDATE_SOURCE}" ] &&
		    [ -n "${VALIDATE_TARGET_SIZE}" ] &&
		    [ ${VALIDATE_TARGET_SIZE} -ge 0 ] &&
		    [ ${VALIDATE_TARGET_SIZE} -le ${OBJECT_MAX_EXPANDED_BYTES} ] &&
		    expand_gzip_file "${VALIDATE_SOURCE}" "${VALIDATE_OLD}" \
		    ${OBJECT_MAX_EXPANDED_BYTES} 65 &&
		    ${BSPATCH} "${VALIDATE_OLD}" "${VALIDATE_NEW}" \
		    "${VALIDATE_PATH}" >/dev/null 2>&1 &&
		    [ -f "${VALIDATE_NEW}" ] && [ ! -L "${VALIDATE_NEW}" ] &&
		    [ `wc -c < "${VALIDATE_NEW}"` -eq \
		    ${VALIDATE_TARGET_SIZE} ]; then
			VALIDATE_HASH=`sha256 < "${VALIDATE_NEW}"`
		fi
		if [ "${VALIDATE_HASH}" = "${VALIDATE_TO}" ]; then
			echo "${VALIDATE_FILE}" >> "${VALIDATE_VALID}"
		else
			echo "Invalid bp/${VALIDATE_FILE}" >&2
		fi
	done < "${VALIDATE_WANTED}"
	rm -f "${VALIDATE_OLD}" "${VALIDATE_NEW}"
}

validate_metadata_patches () {
	VALIDATE_BASE=$1
	VALIDATE_WANTED=$2
	VALIDATE_VALID=$3
	VALIDATE_DIFF=${WRKDIR}/tp.verify.diff
	VALIDATE_OLD=${WRKDIR}/tp.verify.old
	VALIDATE_TMP=${WRKDIR}/tp.verify.tmp
	VALIDATE_NEW=${WRKDIR}/tp.verify.new

	: > "${VALIDATE_VALID}"
	while read VALIDATE_FILE; do
		VALIDATE_PATH=`validation_path "${VALIDATE_BASE}" tp \
		    "${VALIDATE_FILE}"` || {
			VALIDATE_STATUS=$?
			if [ ${VALIDATE_STATUS} -eq 2 ]; then return 1; fi
			VALIDATE_PATH=
		}
		VALIDATE_PAIR=${VALIDATE_FILE%.gz}
		VALIDATE_FROM=${VALIDATE_PAIR%-*}
		VALIDATE_TO=${VALIDATE_PAIR#*-}
		VALIDATE_SOURCE=
		VALIDATE_HASH=
		VALIDATE_SOURCE=`find_valid_object f "${VALIDATE_FROM}.gz"` || true
		rm -f "${VALIDATE_DIFF}" "${VALIDATE_OLD}" \
		    "${VALIDATE_TMP}" "${VALIDATE_NEW}"
		if [ -f "${VALIDATE_PATH}" ] && [ ! -L "${VALIDATE_PATH}" ] &&
		    [ -n "${VALIDATE_SOURCE}" ] &&
		    expand_gzip_file "${VALIDATE_PATH}" "${VALIDATE_DIFF}" \
		    ${OBJECT_MAX_EXPANDED_BYTES} 65 &&
		    expand_gzip_file "${VALIDATE_SOURCE}" "${VALIDATE_OLD}" \
		    ${OBJECT_MAX_EXPANDED_BYTES} 65; then
			cut -c 2- "${VALIDATE_DIFF}" |
			    join -t '|' -v 2 - "${VALIDATE_OLD}" > "${VALIDATE_TMP}"
			awk '/^\+/ { print substr($0, 2) }' "${VALIDATE_DIFF}" |
			    sort -k 1,1 -t '|' -m - "${VALIDATE_TMP}" \
			    > "${VALIDATE_NEW}"
			VALIDATE_HASH=`sha256 < "${VALIDATE_NEW}"`
		fi
		if [ "${VALIDATE_HASH}" = "${VALIDATE_TO}" ]; then
			echo "${VALIDATE_FILE}" >> "${VALIDATE_VALID}"
		else
			echo "Invalid tp/${VALIDATE_FILE}" >&2
		fi
	done < "${VALIDATE_WANTED}"
	rm -f "${VALIDATE_DIFF}" "${VALIDATE_OLD}" \
	    "${VALIDATE_TMP}" "${VALIDATE_NEW}"
}

validate_snapshots () {
	VALIDATE_BASE=$1
	VALIDATE_WANTED=$2
	VALIDATE_VALID=$3
	VALIDATE_DIR=${WRKDIR}/snapshot.verify

	: > "${VALIDATE_VALID}"
	while read VALIDATE_FILE; do
		VALIDATE_PATH=`validation_path "${VALIDATE_BASE}" s \
		    "${VALIDATE_FILE}"` || {
			VALIDATE_STATUS=$?
			if [ ${VALIDATE_STATUS} -eq 2 ]; then return 1; fi
			VALIDATE_PATH=
		}
		VALIDATE_TAG_HASH=${VALIDATE_FILE%.tgz}
		VALIDATE_TAG=
		VALIDATE_TAG=`find_valid_object t "${VALIDATE_TAG_HASH}"` || true
		rm -rf "${VALIDATE_DIR}"
		mkdir -p "${VALIDATE_DIR}"
		VALIDATE_OK=no
		if [ -f "${VALIDATE_PATH}" ] && [ ! -L "${VALIDATE_PATH}" ] &&
		    [ `wc -c < "${VALIDATE_PATH}"` -le \
		    ${SNAPSHOT_MAX_ARCHIVE_BYTES} ] &&
		    expand_gzip_file "${VALIDATE_PATH}" \
		    "${VALIDATE_DIR}/snapshot.tar" \
		    ${SNAPSHOT_MAX_EXPANDED_BYTES} 1025 &&
		    [ -n "${VALIDATE_TAG}" ] &&
		    ! grep -qvE '^[0-9A-Z.]+\|[0-9a-f]{64}$' "${VALIDATE_TAG}" &&
		    [ `grep '^INDEX|' "${VALIDATE_TAG}" | wc -l` -eq 1 ] &&
		    tar -tf "${VALIDATE_DIR}/snapshot.tar" \
		    > "${VALIDATE_DIR}/members" 2>/dev/null &&
		    [ `sort "${VALIDATE_DIR}/members" | uniq -d | wc -l` -eq 0 ] &&
		    ! grep -qvE '^snap/([0-9a-f]{64}\.gz)?$' \
		    "${VALIDATE_DIR}/members" &&
		    tar -tvf "${VALIDATE_DIR}/snapshot.tar" \
		    > "${VALIDATE_DIR}/members.verbose" 2>/dev/null &&
		    ! grep -qvE '^[-d]' "${VALIDATE_DIR}/members.verbose" &&
		    ! grep -Eq ' (link to|->) ' "${VALIDATE_DIR}/members.verbose" &&
		    awk -v max=${SNAPSHOT_MAX_EXPANDED_BYTES} '
		        $2 ~ /^[0-9]+$/ { size = $5 }
		        $2 !~ /^[0-9]+$/ { size = $3 }
		        size !~ /^[0-9]+$/ { exit 1 }
		        { total += size; if (total > max) exit 1 }
		    ' "${VALIDATE_DIR}/members.verbose"; then
			VALIDATE_INDEX_HASH=`grep '^INDEX|' "${VALIDATE_TAG}" |
			    cut -f 2 -d '|'`
			if tar -xf "${VALIDATE_DIR}/snapshot.tar" -C "${VALIDATE_DIR}" \
			    --no-same-owner --no-same-permissions >/dev/null 2>&1 &&
			    [ -f "${VALIDATE_DIR}/snap/${VALIDATE_INDEX_HASH}.gz" ] &&
			    [ ! -L "${VALIDATE_DIR}/snap/${VALIDATE_INDEX_HASH}.gz" ] &&
			    [ `hash_gzip_file \
			    "${VALIDATE_DIR}/snap/${VALIDATE_INDEX_HASH}.gz" \
			    "${VALIDATE_DIR}/INDEX"` = "${VALIDATE_INDEX_HASH}" ]; then
				if ! grep -qvE '^[-_+./@0-9A-Za-z]+\|[0-9a-f]{64}$' \
				    "${VALIDATE_DIR}/INDEX" &&
				    ! fgrep -q './' "${VALIDATE_DIR}/INDEX"; then
					cut -f 2 -d '|' "${VALIDATE_TAG}" \
					    "${VALIDATE_DIR}/INDEX" | sort -u \
					    > "${VALIDATE_DIR}/hashes"
					lam -s 'snap/' "${VALIDATE_DIR}/hashes" \
					    -s '.gz' > "${VALIDATE_DIR}/expected"
					find "${VALIDATE_DIR}/snap" -mindepth 1 |
					    sed "s#^${VALIDATE_DIR}/##" | sort \
					    > "${VALIDATE_DIR}/actual"
					if cmp -s "${VALIDATE_DIR}/expected" \
					    "${VALIDATE_DIR}/actual"; then
						VALIDATE_OK=yes
						while read VALIDATE_HASH; do
							VALIDATE_OBJECT=${VALIDATE_DIR}/snap/${VALIDATE_HASH}.gz
							if ! [ -f "${VALIDATE_OBJECT}" ] ||
							    [ -L "${VALIDATE_OBJECT}" ] ||
							    ! [ `hash_gzip_file "${VALIDATE_OBJECT}" \
							    "${VALIDATE_DIR}/object"` = \
							    "${VALIDATE_HASH}" ]; then
								VALIDATE_OK=no
								break
							fi
						done < "${VALIDATE_DIR}/hashes"
					fi
				fi
			fi
		fi
		if [ "${VALIDATE_OK}" = yes ]; then
			echo "${VALIDATE_FILE}" >> "${VALIDATE_VALID}"
		else
			echo "Invalid s/${VALIDATE_FILE}" >&2
		fi
	done < "${VALIDATE_WANTED}"
	rm -rf "${VALIDATE_DIR}"
}

export HTTP_USER_AGENT="pmirror/0.9"

# If ${PUBDIR}/pub.ssl does not exist, assume we have an empty
# mirror directory and set things up.
if ! [ -f ${PUBDIR}/pub.ssl ]; then
	mkdir -p ${PUBDIR} ${PUBDIR}/bp ${PUBDIR}/f	\
	    ${PUBDIR}/s ${PUBDIR}/t ${PUBDIR}/tp
	touch ${PUBDIR}/latest.ssl
	echo 'User-agent: *' > ${PUBDIR}/robots.txt
	echo 'Disallow: /' >> ${PUBDIR}/robots.txt
fi

# Keep staged downloads inside PUBDIR so installation is an atomic rename on
# the publication filesystem.  mktemp creates this directory mode 0700.
STAGEDIR=`mktemp -d "${PUBDIR}/.pmirror-stage.XXXXXX"` || exit 1
mkdir -p "${STAGEDIR}/bp" "${STAGEDIR}/f" \
	"${STAGEDIR}/s" "${STAGEDIR}/t" "${STAGEDIR}/tp"

if ! ${PHTTPGET} pub.ssl snapshot.ssl latest.ssl > control.fetch.log 2>&1; then
	grep -v "200 OK" control.fetch.log || true
	echo "Failed to fetch portsnap control files" >&2
	exit 1
fi
grep -v "200 OK" control.fetch.log || true
[ -f pub.ssl -a -f snapshot.ssl -a -f latest.ssl ]

LATEST_UNCHANGED=no
if cmp -s latest.ssl ${PUBDIR}/latest.ssl; then
	LATEST_UNCHANGED=yes
	echo "`date`: Latest snapshot unchanged; verifying mirror contents"
fi

echo "`date`: Fetching binary files list"
rm -f bl.gz bl bp.wanted bp.present
if [ ${LATEST_UNCHANGED} = yes ]; then
	cp ${PUBDIR}/bl.gz bl.gz
else
	fetch -q http://${SERVER}/bl.gz
fi
[ -f bl.gz ] || exit 1
gunzip -c bl.gz > bl

echo "`date`: Constructing list of binary patches wanted"
LASTSNAP=`cut -f 2 -d '|' bl | grep -E '^[0-9]+$' | sort -urn | head -1`
awk -F \| -v cutoff=`expr ${LASTSNAP} - 86400`		\
	'{ if ($2 > cutoff) { print } }' bl |
	join -t '|' bl - |
	awk -F \| '{ if ($4 > $2) { print $3 "-" $5 } }' |
	sort -u | grep -E '^[0-9a-f]{64}-[0-9a-f]{64}$' > bp.wanted
( cd ${PUBDIR}/bp/ && ls ) |
	grep -E '^[0-9a-f]{64}-[0-9a-f]{64}$' > bp.present || true

echo "`date`: Fetching metadata files list"
rm -f tl.gz tl
if [ ${LATEST_UNCHANGED} = yes ]; then
	cp ${PUBDIR}/tl.gz tl.gz
else
	fetch -q http://${SERVER}/tl.gz
fi
[ -f tl.gz ] || exit 1
gunzip -c tl.gz > tl

echo "`date`: Constructing list of files wanted"
awk -F \| -v cutoff=`expr ${LASTSNAP} - 86400`		\
	'{ if ($2 > cutoff) { print $3 ".gz" } }' bl |
	grep -E '^[0-9a-f]{64}\.gz$' > f.wanted || true
awk -F \| -v cutoff=`expr ${LASTSNAP} - 691200`		\
	'{ if ($2 > cutoff) { print $3 ".gz" } }' tl |
	grep -E '^[0-9a-f]{64}\.gz$' >> f.wanted || true
tr '-' '\n' < bp.wanted | sed 's/$/.gz/' |
	grep -E '^[0-9a-f]{64}\.gz$' >> f.wanted || true
sort -u f.wanted > f.wanted.tmp
mv f.wanted.tmp f.wanted
( cd ${PUBDIR}/f/ && ls ) |
	grep -E '^[0-9a-f]{64}\.gz$' > f.present || true
validate_content_addressed_files "${PUBDIR}" f f.present f.present.valid
comm -23 f.present f.present.valid > f.invalid
echo "`date`: Fetching needed files"
comm -13 f.present.valid f.wanted > f.missing
fetch_missing_files f f.missing
validate_content_addressed_files "${STAGEDIR}" f f.missing f.staged.valid
cmp -s f.missing f.staged.valid || exit 1

echo "`date`: Verifying and fetching needed binary patches"
comm -12 bp.present bp.wanted > bp.scrub
validate_binary_patches "${PUBDIR}" bp.scrub bp.present.valid
comm -13 bp.present.valid bp.wanted > bp.missing
fetch_missing_files bp bp.missing
validate_binary_patches "${STAGEDIR}" bp.missing bp.staged.valid
cmp -s bp.missing bp.staged.valid || exit 1

echo "`date`: Fetching extra files list"
rm -f el.gz el
if [ ${LATEST_UNCHANGED} = yes ]; then
	cp ${PUBDIR}/el.gz el.gz
else
	fetch -q http://${SERVER}/el.gz
fi
[ -f el.gz ] || exit 1
gunzip -c el.gz > el

echo "`date`: Constructing list of tags wanted"
grep -E '^t/' el | cut -f 2 -d '/' |
	sort -u | grep -E '^[0-9a-f]{64}$' > t.wanted || true
( cd ${PUBDIR}/t/ && ls ) |
	grep -E '^[0-9a-f]{64}$' > t.present || true
validate_content_addressed_files "${PUBDIR}" t t.present t.present.valid
comm -23 t.present t.present.valid > t.invalid
echo "`date`: Fetching needed tags"
comm -13 t.present.valid t.wanted > t.missing
fetch_missing_files t t.missing
validate_content_addressed_files "${STAGEDIR}" t t.missing t.staged.valid
cmp -s t.missing t.staged.valid || exit 1

echo "`date`: Constructing list of snapshots wanted"
grep -E '^s/' el | cut -f 2 -d '/' |
	sort -u | grep -E '^[0-9a-f]{64}\.tgz$' > s.wanted || true
( cd ${PUBDIR}/s/ && ls ) |
	grep -E '^[0-9a-f]{64}\.tgz$' > s.present || true
echo "`date`: Verifying and fetching needed snapshots"
comm -12 s.present s.wanted > s.scrub
validate_snapshots "${PUBDIR}" s.scrub s.present.valid
comm -13 s.present.valid s.wanted > s.missing
fetch_missing_files s s.missing
validate_snapshots "${STAGEDIR}" s.missing s.staged.valid
cmp -s s.missing s.staged.valid || exit 1

echo "`date`: Installing and verifying needed files"
install_staged_files bp bp.missing
install_staged_files f f.missing
install_staged_files s s.missing
install_staged_files t t.missing
quarantine_unrepaired_files f f.invalid f.missing
quarantine_unrepaired_files t t.invalid t.missing
verify_required_files bp bp.wanted
verify_required_files f f.wanted
verify_required_files s s.wanted
verify_required_files t t.wanted
validate_content_addressed_files "${PUBDIR}" f f.wanted f.final.valid
cmp -s f.wanted f.final.valid || exit 1
validate_content_addressed_files "${PUBDIR}" t t.wanted t.final.valid
cmp -s t.wanted t.final.valid || exit 1
validate_binary_patches "${PUBDIR}" bp.wanted bp.final.valid
cmp -s bp.wanted bp.final.valid || exit 1
validate_snapshots "${PUBDIR}" s.wanted s.final.valid
cmp -s s.wanted s.final.valid || exit 1

# Don't bother deleting old tag files.  They don't take up any
# significant space, and keeping them is useful for statistical
# purposes.
# echo "`date`: Removing unneeded tags"
# comm -23 t.present t.wanted | ( cd ${PUBDIR}/t/ && xargs rm )

echo "`date`: Constructing list of metadata patches wanted"
awk -F \| -v cutoff=`expr ${LASTSNAP} - 86400`		\
	'{ if ($2 > cutoff) { print } }' tl |
	join -t '|' tl - |
	awk -F \| '{ if ($4 > $2) { print $3 "-" $5 ".gz" } }' |
	sort -u | grep -E '^[0-9a-f]{64}-[0-9a-f]{64}\.gz$' > tp.wanted || true
awk -F \| -v cutoff=`expr ${LASTSNAP} - 86400`		\
	'{ if ($2 > cutoff) { print } }' tl |
	join -t '|' tl - |
	fgrep "|${LASTSNAP}|" |
	awk -F \| '{ if ($4 > $2) { print $3 "-" $5 ".gz" } }' |
	sort -u | grep -E '^[0-9a-f]{64}-[0-9a-f]{64}\.gz$' > tp.needed || true
( cd ${PUBDIR}/tp/ && ls ) |
	grep -E '^[0-9a-f]{64}-[0-9a-f]{64}\.gz$' > tp.present || true
comm -12 tp.present tp.wanted > tp.scrub
validate_metadata_patches "${PUBDIR}" tp.scrub tp.present.valid
comm -23 tp.scrub tp.present.valid > tp.invalid

echo "`date`: Generating needed metadata patches"
# This generates lines of the form RECENTHASH|OLDHASH|NEWHASH,
# where RECENTHASH is the most recent metadata file of the same
# type which existed prior to this mirroring run.
# This list is also sorted starting with the most recent OLDHASH.
#
# If there are no existing metadata files of the relevant type
# then the metadata patches won't be created.  Sorry.  They'll
# all be created the next time.

sort -k 3 -t '|' tl > tl.sorted

cut -f 1 -d '.' f.final.valid |
	join -2 3 -t '|' - tl.sorted |
	sort -k 3 -t '|' |
	perl -e '
		while (<>) {
			@_ = split /\|/;
			$l{$_[1]} = $_[0]
		};
		for $f (sort(keys %l)) {
			print "$f|$l{$f}\n"
		}' > metadata.latest

: > tp.generated
comm -13 tp.present.valid tp.needed |
	cut -f 1 -d '.' |
	tr '-' '|' |
	join -o 1.1,1.2,2.1,2.2 -1 3 -t '|' tl.sorted - |
	sort |
	join -o 1.2,2.2,2.3,2.4 -t '|' metadata.latest - |
	sort -rn -k 2 -t '|' |
	cut -f 1,3,4 -d '|' |
while read LINE; do
	X=`echo ${LINE} | cut -f 2 -d '|'`
	Y=`echo ${LINE} | cut -f 3 -d '|'`
	M=`echo ${LINE} | cut -f 1 -d '|'`

	if ! grep -Fqx "${X}-${M}.gz" tp.present.valid ||
	    ! grep -Fqx "${M}-${Y}.gz" tp.present.valid; then
		X_SOURCE=`find_valid_object f "${X}.gz"` || exit 1
		Y_SOURCE=`find_valid_object f "${Y}.gz"` || exit 1
		gunzip -c "${X_SOURCE}" | sort > ${X}
		gunzip -c "${Y_SOURCE}" | sort > ${Y}
		perl -e '
			open F, $ARGV[0];
			open G, $ARGV[1];
			$s = <F>;
			$t = <G>;
			do {
				if ($s eq $t) {
					$s = <F>;
					$t = <G>;
				} elsif ((! $t) || ($s && ($s lt $t))) {
					@s = split /\|/, $s;
					print "-$s[0]\n";
					$s = <F>;
				} else {
					print "+$t";
					$t = <G>;
				}
			} while ($s || $t)' ${X} ${Y} |
			sort -k 1.2,1 -t '|' > ${X}-${Y}
		rm ${X} ${Y}
	else
		XM_SOURCE=`find_valid_object tp "${X}-${M}.gz"` || exit 1
		MY_SOURCE=`find_valid_object tp "${M}-${Y}.gz"` || exit 1
		gunzip -c "${XM_SOURCE}" | sort -r |
			sort -s -k 1.2,1 -t '|' > ${X}-${M}
		gunzip -c "${MY_SOURCE}" | sort -r |
			sort -s -k 1.2,1 -t '|' > ${M}-${Y}
		perl -e '
			open F, $ARGV[0];
			open G, $ARGV[1];
			$s = <F>;
			$t = <G>;
			while ($s || $t) {
				chomp $s;
				chomp $t;

				if (! $t) {
					print "$s\n";
					$s = <F>;
					next;
				};
				if (! $s) {
					print "$t\n";
					$t = <G>;
					next;
				};

				@s = split //, $s, 2;
				@s2 = split /\|/, $s[1];
				@t = split //, $t, 2;
				@t2 = split /\|/, $t[1];

				if ($s2[0] lt $t2[0]) {
					print "$s\n";
					$s = <F>;
					next;
				};
				if ($s2[0] gt $t2[0]) {
					print "$t\n";
					$t = <G>;
					next;
				};

				if ($s[0] eq "-") {
					print "$s\n";
				} else {
					$t = <G>;
				};
				$s = <F>;
			}' ${X}-${M} ${M}-${Y}		\
			> ${X}-${Y}
		rm ${X}-${M} ${M}-${Y}
	fi

	gzip -9n ${X}-${Y}
	if [ `wc -c < ${X}-${Y}.gz` -lt 100000 ]; then
		mv ${X}-${Y}.gz ${STAGEDIR}/tp/
		echo "${X}-${Y}.gz" >> tp.generated
	else
		rm ${X}-${Y}.gz
	fi
done

sort -u tp.generated > tp.generated.sorted
mv tp.generated.sorted tp.generated
validate_metadata_patches "${STAGEDIR}" tp.generated tp.staged.valid
cmp -s tp.generated tp.staged.valid || exit 1
install_staged_files tp tp.generated
# Invalid optional patches which could not be regenerated under the size policy
# are removed only after every staged repair has validated.
comm -23 tp.invalid tp.generated > tp.remove
while read TP_REMOVE; do
	TP_REMOVE_PATH=${PUBDIR}/tp/${TP_REMOVE}
	if [ -e "${TP_REMOVE_PATH}" ] || [ -L "${TP_REMOVE_PATH}" ]; then
		if [ ! -f "${TP_REMOVE_PATH}" ] && [ ! -L "${TP_REMOVE_PATH}" ]; then
			echo "Refusing to remove unexpected tp/${TP_REMOVE} object type" >&2
			exit 1
		fi
		mkdir -p "${STAGEDIR}/quarantine/tp"
		mv "${TP_REMOVE_PATH}" "${STAGEDIR}/quarantine/tp/${TP_REMOVE}"
	fi
done < tp.remove
( cd ${PUBDIR}/tp/ && ls ) |
	grep -E '^[0-9a-f]{64}-[0-9a-f]{64}\.gz$' > tp.retained || true
comm -12 tp.retained tp.wanted > tp.final
validate_metadata_patches "${PUBDIR}" tp.final tp.final.valid
cmp -s tp.final tp.final.valid || exit 1

echo "`date`: Removing unneeded metadata patches"
( cd ${PUBDIR}/tp/ && ls ) |
	grep -E '^[0-9a-f]{64}-[0-9a-f]{64}\.gz$' > tp.prune || true
comm -23 tp.prune tp.wanted | ( cd ${PUBDIR}/tp/ && xargs rm )

echo "`date`: Removing unneeded binary patches"
( cd ${PUBDIR}/bp/ && ls ) |
	grep -E '^[0-9a-f]{64}-[0-9a-f]{64}$' > bp.prune || true
comm -23 bp.prune bp.wanted | ( cd ${PUBDIR}/bp/ && xargs rm )
echo "`date`: Removing unneeded files"
( cd ${PUBDIR}/f/ && ls ) |
	grep -E '^[0-9a-f]{64}\.gz$' > f.prune || true
comm -23 f.prune f.wanted | ( cd ${PUBDIR}/f/ && xargs rm )
echo "`date`: Removing unneeded snapshots"
( cd ${PUBDIR}/s/ && ls ) |
	grep -E '^[0-9a-f]{64}\.tgz$' > s.prune || true
comm -23 s.prune s.wanted | ( cd ${PUBDIR}/s/ && xargs rm )

if [ ${LATEST_UNCHANGED} = no ]; then
	echo "`date`: Publishing file lists and signatures"
	mv bl.gz el.gz tl.gz ${PUBDIR}
	mv latest.ssl pub.ssl snapshot.ssl ${PUBDIR}
else
	rm bl.gz el.gz tl.gz latest.ssl pub.ssl snapshot.ssl
fi

rm -f bp.prune f.prune s.prune tp.prune

echo "`date`: Removing temporary files"
rm bl el tl
rm tl.sorted metadata.latest
rm bp.wanted bp.present bp.scrub bp.present.valid bp.missing bp.staged.valid
rm bp.final.valid
rm f.wanted f.present f.present.valid f.invalid f.quarantine f.missing f.staged.valid
rm f.final.valid
rm s.present s.scrub s.present.valid s.wanted s.missing s.staged.valid
rm s.final.valid
rm t.present t.present.valid t.invalid t.quarantine t.wanted t.missing t.staged.valid
rm t.final.valid
rm tp.present tp.present.valid tp.wanted tp.needed tp.generated
rm tp.scrub tp.invalid tp.remove tp.staged.valid tp.retained tp.final tp.final.valid

# Temporary and staging directories are removed by the exit trap.
