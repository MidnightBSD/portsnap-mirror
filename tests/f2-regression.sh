#!/bin/sh -e

set -e

TEST_TMP=`mktemp -d "${TMPDIR:-/tmp}/portsnap-f2.XXXXXX"` || exit 1
cleanup () {
	if [ -n "${TEST_TMP}" ] && [ -d "${TEST_TMP}" ]; then
		rm -r "${TEST_TMP}"
	fi
}
trap cleanup 0
trap 'exit 1' 1 2 15

TEST_BINDIR=${TEST_TMP}/bin
mkdir -p "${TEST_BINDIR}"

cat > "${TEST_BINDIR}/phttpget" <<'EOF'
#!/bin/sh
shift
for TEST_PATH do
	if [ "${OMIT_OBJECT:-}" = "${TEST_PATH}" ]; then
		continue
	fi
	cp "${TEST_ORIGIN}/${TEST_PATH}" "${TEST_PATH##*/}"
	if [ "${FAIL_OBJECT:-}" = "${TEST_PATH}" ]; then
		exit 42
	fi
done
EOF

cat > "${TEST_BINDIR}/fetch" <<'EOF'
#!/bin/sh
for TEST_ARG do
	case ${TEST_ARG} in
	http://*) TEST_URL=${TEST_ARG} ;;
	esac
done
cp "${TEST_ORIGIN}/${TEST_URL##*/}" .
EOF

cat > "${TEST_BINDIR}/lam" <<'EOF'
#!/bin/sh
[ "$1" = "-s" ]
TEST_PREFIX=$2
TEST_INPUT=$3
shift 3
TEST_SUFFIX=
if [ "${1:-}" = "-s" ]; then
	TEST_SUFFIX=$2
fi
while read TEST_LINE; do
	printf '%s%s%s\n' "${TEST_PREFIX}" "${TEST_LINE}" "${TEST_SUFFIX}"
done < "${TEST_INPUT}"
EOF

cat > "${TEST_BINDIR}/sha256" <<'EOF'
#!/bin/sh
sha256sum | awk '{ print $1 }'
EOF

cat > "${TEST_BINDIR}/xargs" <<'EOF'
#!/bin/sh
TEST_INPUT=`cat`
if [ -z "${TEST_INPUT}" ]; then
	exit 0
fi
for TEST_WORD in ${TEST_INPUT}; do
	set -- "$@" "${TEST_WORD}"
done
"$@"
EOF

cat > "${TEST_BINDIR}/mktemp" <<'EOF'
#!/bin/sh
if [ "$1" = "-d" ] && [ "$2" = "-t" ]; then
	exec /usr/bin/mktemp -d "${TMPDIR:-/tmp}/$3.XXXXXX"
fi
exec /usr/bin/mktemp "$@"
EOF

cat > "${TEST_BINDIR}/bspatch" <<'EOF'
#!/bin/sh
dd if="$3" of="${3}.payload" bs=1 skip=32 2>/dev/null
TEST_EXPECTED=`sed -n '1p' "${3}.payload"`
TEST_ACTUAL=`sha256sum "$1" | awk '{ print $1 }'`
[ "${TEST_ACTUAL}" = "${TEST_EXPECTED}" ] || exit 1
sed '1d' "${3}.payload" > "$2"
rm "${3}.payload"
EOF

chmod +x "${TEST_BINDIR}/phttpget" "${TEST_BINDIR}/fetch" \
	"${TEST_BINDIR}/lam" "${TEST_BINDIR}/sha256" \
	"${TEST_BINDIR}/xargs" "${TEST_BINDIR}/mktemp" \
	"${TEST_BINDIR}/bspatch"

run_case () {
	TEST_SCRIPT=$1
	TEST_MODE=$2
	TEST_EXPECT=$3
	TEST_CASE=${TEST_TMP}/`basename ${TEST_SCRIPT}`-${TEST_MODE}
	TEST_ORIGIN=${TEST_CASE}/origin
	TEST_PUBDIR=${TEST_CASE}/pub

	mkdir -p "${TEST_ORIGIN}/bp" "${TEST_ORIGIN}/f" "${TEST_ORIGIN}/s" \
		"${TEST_ORIGIN}/t" \
		"${TEST_PUBDIR}/bp" \
		"${TEST_PUBDIR}/f" "${TEST_PUBDIR}/s" \
		"${TEST_PUBDIR}/t" "${TEST_PUBDIR}/tp" \
		"${TEST_CASE}/work"

	TEST_FILE_HASH=`printf 'valid file\n' | sha256sum | awk '{ print $1 }'`
	printf 'oldfile|%s\n' "${TEST_FILE_HASH}" > "${TEST_CASE}/INDEX.old"
	printf 'file|%s\n' "${TEST_FILE_HASH}" > "${TEST_CASE}/INDEX.new"
	TEST_OLD_HASH=`sha256sum "${TEST_CASE}/INDEX.old" | awk '{ print $1 }'`
	TEST_HASH=`sha256sum "${TEST_CASE}/INDEX.new" | awk '{ print $1 }'`
	printf 'A|%s\n' "${TEST_OLD_HASH}" > "${TEST_CASE}/metadata.old"
	printf 'A|%s\nB|%s\n' "${TEST_OLD_HASH}" "${TEST_HASH}" \
		> "${TEST_CASE}/metadata.new"
	TEST_META_OLD_HASH=`sha256sum "${TEST_CASE}/metadata.old" | awk '{ print $1 }'`
	TEST_META_NEW_HASH=`sha256sum "${TEST_CASE}/metadata.new" | awk '{ print $1 }'`
	printf 'INDEX|%s\n' "${TEST_HASH}" > "${TEST_CASE}/snapshot.tag"
	TEST_SNAPSHOT_HASH=`sha256sum "${TEST_CASE}/snapshot.tag" | awk '{ print $1 }'`
	TEST_TAG_HASH=`printf 'valid tag\n' | sha256sum | awk '{ print $1 }'`
	TEST_SENTINEL=`printf 'retained object\n' | sha256sum | awk '{ print $1 }'`
	TEST_BAD_HASH=0000000000000000000000000000000000000000000000000000000000000000
	TEST_LARGE_HASH=
	printf 'INDEX|200000|%s\nINDEX|200001|%s\n' \
		"${TEST_OLD_HASH}" "${TEST_HASH}" \
		> "${TEST_CASE}/bl"
	printf 'DESCRIBE|199999|%s\nDESCRIBE|200001|%s\n' \
		"${TEST_META_OLD_HASH}" "${TEST_META_NEW_HASH}" \
		> "${TEST_CASE}/tl"
	if [ "${TEST_MODE}" = large-valid-f ]; then
		dd if=/dev/zero of="${TEST_CASE}/large.valid" \
			bs=1048576 count=6 2>/dev/null
		TEST_LARGE_HASH=`sha256sum "${TEST_CASE}/large.valid" | \
			awk '{ print $1 }'`
		printf 'LARGE|200001|%s\n' "${TEST_LARGE_HASH}" \
			>> "${TEST_CASE}/tl"
	fi
	printf 's/%s.tgz\nt/%s\nt/%s\n' "${TEST_SNAPSHOT_HASH}" \
		"${TEST_SNAPSHOT_HASH}" "${TEST_TAG_HASH}" \
		> "${TEST_CASE}/el"
	gzip -c "${TEST_CASE}/bl" > "${TEST_ORIGIN}/bl.gz"
	gzip -c "${TEST_CASE}/tl" > "${TEST_ORIGIN}/tl.gz"
	gzip -c "${TEST_CASE}/el" > "${TEST_ORIGIN}/el.gz"
	printf 'public key\n' > "${TEST_ORIGIN}/pub.ssl"
	printf 'snapshot signature\n' > "${TEST_ORIGIN}/snapshot.ssl"
	printf 'new signature\n' > "${TEST_ORIGIN}/latest.ssl"
	TEST_BP_SIZE=`wc -c < "${TEST_CASE}/INDEX.new"`
	( printf 'BSDIFF40'
	  printf '\000\000\000\000\000\000\000\000'
	  printf '\000\000\000\000\000\000\000\000'
	  printf "\\`printf '%03o' ${TEST_BP_SIZE}`"
	  printf '\000\000\000\000\000\000\000'
	  printf '%s\n' "${TEST_OLD_HASH}"
	  sed -n '1,$p' "${TEST_CASE}/INDEX.new" ) \
		> "${TEST_ORIGIN}/bp/${TEST_OLD_HASH}-${TEST_HASH}"
	mkdir -p "${TEST_CASE}/snapshot/snap"
	gzip -c "${TEST_CASE}/INDEX.new" \
		> "${TEST_CASE}/snapshot/snap/${TEST_HASH}.gz"
	printf 'valid file\n' | gzip -c \
		> "${TEST_CASE}/snapshot/snap/${TEST_FILE_HASH}.gz"
	( cd "${TEST_CASE}/snapshot" && tar -czf \
		"${TEST_ORIGIN}/s/${TEST_SNAPSHOT_HASH}.tgz" snap )
	cp "${TEST_CASE}/snapshot.tag" \
		"${TEST_ORIGIN}/t/${TEST_SNAPSHOT_HASH}"
	case ${TEST_MODE} in
	bad-tag) printf 'invalid tag\n' > "${TEST_ORIGIN}/t/${TEST_TAG_HASH}" ;;
	*) printf 'valid tag\n' > "${TEST_ORIGIN}/t/${TEST_TAG_HASH}" ;;
	esac
	printf 'public key\n' > "${TEST_PUBDIR}/pub.ssl"
	: > "${TEST_PUBDIR}/indextimes"

	gzip -c "${TEST_CASE}/INDEX.old" \
		> "${TEST_ORIGIN}/f/${TEST_OLD_HASH}.gz"
	gzip -c "${TEST_CASE}/INDEX.new" \
		> "${TEST_ORIGIN}/f/${TEST_HASH}.gz"
	gzip -c "${TEST_CASE}/metadata.old" \
		> "${TEST_ORIGIN}/f/${TEST_META_OLD_HASH}.gz"
	gzip -c "${TEST_CASE}/metadata.new" \
		> "${TEST_ORIGIN}/f/${TEST_META_NEW_HASH}.gz"
	if [ -n "${TEST_LARGE_HASH}" ]; then
		gzip -c "${TEST_CASE}/large.valid" \
			> "${TEST_ORIGIN}/f/${TEST_LARGE_HASH}.gz"
	fi
	if [ "${TEST_MODE}" = bad-hash ]; then
		printf 'invalid metadata\n' | gzip -c \
			> "${TEST_ORIGIN}/f/${TEST_HASH}.gz"
	fi
	if [ "${TEST_MODE}" = bad-expanded-f ]; then
		dd if=/dev/zero bs=1048576 count=65 2>/dev/null | gzip -c \
			> "${TEST_ORIGIN}/f/${TEST_HASH}.gz"
	fi
	if [ "${TEST_MODE}" = bad-bp ]; then
		printf 'invalid binary patch\n' \
			> "${TEST_ORIGIN}/bp/${TEST_OLD_HASH}-${TEST_HASH}"
	fi
	if [ "${TEST_MODE}" = bad-bp-target-size ]; then
		( printf 'BSDIFF40'
		  printf '\000\000\000\000\000\000\000\000'
		  printf '\000\000\000\000\000\000\000\000'
		  printf '\001\000\000\004\000\000\000\000' ) \
			> "${TEST_ORIGIN}/bp/${TEST_OLD_HASH}-${TEST_HASH}"
	fi
	if [ "${TEST_MODE}" = bad-snapshot ]; then
		printf 'corrupt archived file\n' | gzip -c \
			> "${TEST_CASE}/snapshot/snap/${TEST_FILE_HASH}.gz"
		( cd "${TEST_CASE}/snapshot" && tar -czf \
			"${TEST_ORIGIN}/s/${TEST_SNAPSHOT_HASH}.tgz" snap )
	fi
	if [ "${TEST_MODE}" = bad-snapshot-link ]; then
		rm "${TEST_CASE}/snapshot/snap/${TEST_FILE_HASH}.gz"
		ln -s /tmp/portsnap-snapshot-escape \
			"${TEST_CASE}/snapshot/snap/${TEST_FILE_HASH}.gz"
		( cd "${TEST_CASE}/snapshot" && tar -czf \
			"${TEST_ORIGIN}/s/${TEST_SNAPSHOT_HASH}.tgz" snap )
	fi
	if [ "${TEST_MODE}" = bad-snapshot-duplicate ]; then
		( cd "${TEST_CASE}/snapshot" &&
		  tar -cf "${TEST_CASE}/snapshot.tar" snap &&
		  tar -rf "${TEST_CASE}/snapshot.tar" \
		    "snap/${TEST_FILE_HASH}.gz" )
		gzip -c "${TEST_CASE}/snapshot.tar" \
			> "${TEST_ORIGIN}/s/${TEST_SNAPSHOT_HASH}.tgz"
	fi

	case ${TEST_MODE} in
	unchanged|unchanged-skew|unchanged-extra|corrupt-existing-f|oversized-existing-f|corrupt-existing-t|corrupt-existing-bp|corrupt-existing-s|corrupt-existing-tp|corrupt-existing-tp-source|corrupt-existing-tp-bomb|failed-repair-preserves-existing|directory-existing|symlink-existing)
		printf 'new signature\n' > "${TEST_PUBDIR}/latest.ssl"
		cp "${TEST_ORIGIN}/bl.gz" "${TEST_PUBDIR}/bl.gz"
		cp "${TEST_ORIGIN}/tl.gz" "${TEST_PUBDIR}/tl.gz"
		cp "${TEST_ORIGIN}/el.gz" "${TEST_PUBDIR}/el.gz"
		cp "${TEST_PUBDIR}/bl.gz" "${TEST_CASE}/published-bl.gz"
		printf 'retained object\n' | gzip -c \
			> "${TEST_PUBDIR}/f/${TEST_SENTINEL}.gz"
		;;
	*) printf 'old signature\n' > "${TEST_PUBDIR}/latest.ssl" ;;
	esac
	if [ "${TEST_MODE}" = unchanged-skew ]; then
		: > "${TEST_CASE}/skew-bl"
		gzip -c "${TEST_CASE}/skew-bl" > "${TEST_ORIGIN}/bl.gz"
	fi
	case ${TEST_MODE} in
	corrupt-existing-f)
		printf 'corrupt metadata\n' | gzip -c \
			> "${TEST_PUBDIR}/f/${TEST_HASH}.gz"
		;;
	oversized-existing-f)
		dd if=/dev/zero \
			of="${TEST_PUBDIR}/f/${TEST_HASH}.gz" \
			bs=1 count=1 seek=67108864 2>/dev/null
		;;
	corrupt-existing-t)
		printf 'corrupt tag\n' > "${TEST_PUBDIR}/t/${TEST_TAG_HASH}"
		;;
	corrupt-existing-bp)
		printf 'corrupt binary patch\n' \
			> "${TEST_PUBDIR}/bp/${TEST_OLD_HASH}-${TEST_HASH}"
		;;
	corrupt-existing-s)
		printf 'corrupt archived file\n' | gzip -c \
			> "${TEST_CASE}/snapshot/snap/${TEST_FILE_HASH}.gz"
		( cd "${TEST_CASE}/snapshot" && tar -czf \
			"${TEST_PUBDIR}/s/${TEST_SNAPSHOT_HASH}.tgz" snap )
		;;
	changed-corrupt-existing)
		printf 'corrupt metadata\n' | gzip -c \
			> "${TEST_PUBDIR}/f/${TEST_HASH}.gz"
		printf 'corrupt tag\n' > "${TEST_PUBDIR}/t/${TEST_TAG_HASH}"
		printf 'corrupt binary patch\n' \
			> "${TEST_PUBDIR}/bp/${TEST_OLD_HASH}-${TEST_HASH}"
		printf 'corrupt snapshot\n' \
			> "${TEST_PUBDIR}/s/${TEST_SNAPSHOT_HASH}.tgz"
		;;
	corrupt-existing-tp|corrupt-existing-tp-source|corrupt-existing-tp-bomb)
		cp "${TEST_ORIGIN}/f/${TEST_META_OLD_HASH}.gz" \
			"${TEST_PUBDIR}/f/${TEST_META_OLD_HASH}.gz"
		cp "${TEST_ORIGIN}/f/${TEST_META_NEW_HASH}.gz" \
			"${TEST_PUBDIR}/f/${TEST_META_NEW_HASH}.gz"
		if [ "${TEST_MODE}" = corrupt-existing-tp-bomb ]; then
			dd if=/dev/zero bs=1048576 count=65 2>/dev/null | gzip -c \
				> "${TEST_PUBDIR}/tp/${TEST_META_OLD_HASH}-${TEST_META_NEW_HASH}.gz"
		else
			printf 'corrupt metadata patch\n' | gzip -c \
				> "${TEST_PUBDIR}/tp/${TEST_META_OLD_HASH}-${TEST_META_NEW_HASH}.gz"
		fi
		if [ "${TEST_MODE}" = corrupt-existing-tp-source ]; then
			printf 'corrupt metadata source\n' | gzip -c \
				> "${TEST_PUBDIR}/f/${TEST_META_OLD_HASH}.gz"
		fi
		;;
	failed-repair-preserves-existing)
		printf 'corrupt metadata to preserve\n' | gzip -c \
			> "${TEST_PUBDIR}/f/${TEST_HASH}.gz"
		;;
	directory-existing)
		mkdir "${TEST_PUBDIR}/f/${TEST_HASH}.gz"
		;;
	quarantine-extra|unchanged-extra)
		printf 'corrupt extra file\n' | gzip -c \
			> "${TEST_PUBDIR}/f/${TEST_BAD_HASH}.gz"
		printf 'corrupt extra tag\n' \
			> "${TEST_PUBDIR}/t/${TEST_BAD_HASH}"
		printf 'corrupt extra patch\n' \
			> "${TEST_PUBDIR}/bp/${TEST_BAD_HASH}-${TEST_BAD_HASH}"
		printf 'corrupt extra snapshot\n' \
			> "${TEST_PUBDIR}/s/${TEST_BAD_HASH}.tgz"
		printf 'corrupt extra metadata patch\n' | gzip -c \
			> "${TEST_PUBDIR}/tp/${TEST_BAD_HASH}-${TEST_BAD_HASH}.gz"
		;;
	symlink-existing)
		cp "${TEST_ORIGIN}/f/${TEST_META_OLD_HASH}.gz" \
			"${TEST_PUBDIR}/f/${TEST_META_OLD_HASH}.gz"
		cp "${TEST_ORIGIN}/f/${TEST_META_NEW_HASH}.gz" \
			"${TEST_PUBDIR}/f/${TEST_META_NEW_HASH}.gz"
		printf 'corrupt metadata patch\n' | gzip -c \
			> "${TEST_CASE}/tp-link.gz"
		ln -s "${TEST_ORIGIN}/f/${TEST_HASH}.gz" \
			"${TEST_PUBDIR}/f/${TEST_HASH}.gz"
		ln -s "${TEST_ORIGIN}/t/${TEST_TAG_HASH}" \
			"${TEST_PUBDIR}/t/${TEST_TAG_HASH}"
		ln -s "${TEST_ORIGIN}/bp/${TEST_OLD_HASH}-${TEST_HASH}" \
			"${TEST_PUBDIR}/bp/${TEST_OLD_HASH}-${TEST_HASH}"
		ln -s "${TEST_ORIGIN}/s/${TEST_SNAPSHOT_HASH}.tgz" \
			"${TEST_PUBDIR}/s/${TEST_SNAPSHOT_HASH}.tgz"
		ln -s "${TEST_CASE}/tp-link.gz" \
			"${TEST_PUBDIR}/tp/${TEST_META_OLD_HASH}-${TEST_META_NEW_HASH}.gz"
		;;
	esac

	sed -e 's#/usr/libexec/phttpget#phttpget#' \
	    -e 's#/usr/bin/bspatch#bspatch#' "${TEST_SCRIPT}" \
		> "${TEST_CASE}/mirror.sh"

	TEST_FAIL_OBJECT=
	TEST_OMIT_OBJECT=
	case ${TEST_MODE} in
	failure) TEST_FAIL_OBJECT=f/${TEST_HASH}.gz ;;
	missing|failed-repair-preserves-existing)
		TEST_OMIT_OBJECT=f/${TEST_HASH}.gz
		;;
	esac

	TEST_STATUS=0
	if ( cd "${TEST_CASE}/work" &&
	    PATH="${TEST_BINDIR}:${PATH}" \
	    TEST_ORIGIN="${TEST_ORIGIN}" \
	    FAIL_OBJECT="${TEST_FAIL_OBJECT}" \
	    OMIT_OBJECT="${TEST_OMIT_OBJECT}" \
	    sh -e "${TEST_CASE}/mirror.sh" example.invalid "${TEST_PUBDIR}" \
	    > "${TEST_CASE}/output" 2>&1 ); then
		TEST_STATUS=0
	else
		TEST_STATUS=$?
	fi

	case ${TEST_EXPECT} in
	success)
		if [ ${TEST_STATUS} -ne 0 ]; then
			cat "${TEST_CASE}/output"
			return 1
		fi
		[ -f "${TEST_PUBDIR}/f/${TEST_HASH}.gz" ]
		[ -f "${TEST_PUBDIR}/bp/${TEST_OLD_HASH}-${TEST_HASH}" ]
		[ -f "${TEST_PUBDIR}/s/${TEST_SNAPSHOT_HASH}.tgz" ]
		[ -f "${TEST_PUBDIR}/t/${TEST_TAG_HASH}" ]
		[ -f "${TEST_PUBDIR}/t/${TEST_SNAPSHOT_HASH}" ]
		[ `gunzip -c "${TEST_PUBDIR}/f/${TEST_HASH}.gz" | sha256sum | awk '{ print $1 }'` = "${TEST_HASH}" ]
		[ `sha256sum "${TEST_PUBDIR}/t/${TEST_TAG_HASH}" | awk '{ print $1 }'` = "${TEST_TAG_HASH}" ]
		[ ! -L "${TEST_PUBDIR}/f/${TEST_HASH}.gz" ]
		[ ! -L "${TEST_PUBDIR}/t/${TEST_TAG_HASH}" ]
		[ ! -L "${TEST_PUBDIR}/bp/${TEST_OLD_HASH}-${TEST_HASH}" ]
		[ ! -L "${TEST_PUBDIR}/s/${TEST_SNAPSHOT_HASH}.tgz" ]
		if [ -n "${TEST_LARGE_HASH}" ]; then
			[ -f "${TEST_PUBDIR}/f/${TEST_LARGE_HASH}.gz" ]
			[ `gunzip -c "${TEST_PUBDIR}/f/${TEST_LARGE_HASH}.gz" | \
			    sha256sum | awk '{ print $1 }'` = "${TEST_LARGE_HASH}" ]
		fi
		cmp -s "${TEST_ORIGIN}/bp/${TEST_OLD_HASH}-${TEST_HASH}" \
			"${TEST_PUBDIR}/bp/${TEST_OLD_HASH}-${TEST_HASH}"
		cmp -s "${TEST_ORIGIN}/s/${TEST_SNAPSHOT_HASH}.tgz" \
			"${TEST_PUBDIR}/s/${TEST_SNAPSHOT_HASH}.tgz"
		cmp -s "${TEST_ORIGIN}/latest.ssl" "${TEST_PUBDIR}/latest.ssl"
		if [ -f "${TEST_CASE}/published-bl.gz" ]; then
			cmp -s "${TEST_CASE}/published-bl.gz" "${TEST_PUBDIR}/bl.gz"
			[ ! -f "${TEST_PUBDIR}/f/${TEST_SENTINEL}.gz" ]
		fi
	if [ "${TEST_MODE}" = corrupt-existing-tp ] ||
	    [ "${TEST_MODE}" = corrupt-existing-tp-source ] ||
	    [ "${TEST_MODE}" = corrupt-existing-tp-bomb ] ||
	    [ "${TEST_MODE}" = symlink-existing ]; then
			[ -f "${TEST_PUBDIR}/tp/${TEST_META_OLD_HASH}-${TEST_META_NEW_HASH}.gz" ]
			gunzip -t "${TEST_PUBDIR}/tp/${TEST_META_OLD_HASH}-${TEST_META_NEW_HASH}.gz"
			gunzip -c "${TEST_PUBDIR}/tp/${TEST_META_OLD_HASH}-${TEST_META_NEW_HASH}.gz" \
				> "${TEST_CASE}/tp.diff"
			gunzip -c "${TEST_PUBDIR}/f/${TEST_META_OLD_HASH}.gz" \
				> "${TEST_CASE}/tp.old"
			cut -c 2- "${TEST_CASE}/tp.diff" |
				join -t '|' -v 2 - "${TEST_CASE}/tp.old" \
				> "${TEST_CASE}/tp.tmp"
			awk '/^\+/ { print substr($0, 2) }' "${TEST_CASE}/tp.diff" |
				sort -k 1,1 -t '|' -m - "${TEST_CASE}/tp.tmp" \
				> "${TEST_CASE}/tp.new"
			[ `sha256sum "${TEST_CASE}/tp.new" | awk '{ print $1 }'` = \
				"${TEST_META_NEW_HASH}" ]
			[ ! -L "${TEST_PUBDIR}/tp/${TEST_META_OLD_HASH}-${TEST_META_NEW_HASH}.gz" ]
		fi
		if [ "${TEST_MODE}" = quarantine-extra ] ||
		    [ "${TEST_MODE}" = unchanged-extra ]; then
			[ ! -e "${TEST_PUBDIR}/f/${TEST_BAD_HASH}.gz" ]
			[ ! -e "${TEST_PUBDIR}/t/${TEST_BAD_HASH}" ]
			[ ! -e "${TEST_PUBDIR}/bp/${TEST_BAD_HASH}-${TEST_BAD_HASH}" ]
			[ ! -e "${TEST_PUBDIR}/s/${TEST_BAD_HASH}.tgz" ]
			[ ! -e "${TEST_PUBDIR}/tp/${TEST_BAD_HASH}-${TEST_BAD_HASH}.gz" ]
		fi
		;;
	failure)
		[ ${TEST_STATUS} -ne 0 ]
		if [ "${TEST_MODE}" = failed-repair-preserves-existing ]; then
			[ -f "${TEST_PUBDIR}/f/${TEST_HASH}.gz" ]
			[ "`gunzip -c "${TEST_PUBDIR}/f/${TEST_HASH}.gz"`" = \
				"corrupt metadata to preserve" ]
		elif [ "${TEST_MODE}" = directory-existing ]; then
			[ -d "${TEST_PUBDIR}/f/${TEST_HASH}.gz" ]
		else
			[ ! -f "${TEST_PUBDIR}/f/${TEST_HASH}.gz" ]
		fi
		[ ! -f "${TEST_PUBDIR}/bp/${TEST_OLD_HASH}-${TEST_HASH}" ]
		[ ! -f "${TEST_PUBDIR}/s/${TEST_SNAPSHOT_HASH}.tgz" ]
		[ ! -f "${TEST_PUBDIR}/t/${TEST_TAG_HASH}" ]
		if [ "${TEST_MODE}" = failed-repair-preserves-existing ] ||
		    [ "${TEST_MODE}" = directory-existing ]; then
			grep -q '^new signature$' "${TEST_PUBDIR}/latest.ssl"
		else
			grep -q '^old signature$' "${TEST_PUBDIR}/latest.ssl"
		fi
		;;
	esac
}

TEST_SCRIPT=pmirror.sh
run_case "${TEST_SCRIPT}" failure failure
run_case "${TEST_SCRIPT}" missing failure
run_case "${TEST_SCRIPT}" bad-hash failure
run_case "${TEST_SCRIPT}" bad-expanded-f failure
run_case "${TEST_SCRIPT}" bad-tag failure
run_case "${TEST_SCRIPT}" bad-bp failure
run_case "${TEST_SCRIPT}" bad-bp-target-size failure
run_case "${TEST_SCRIPT}" bad-snapshot failure
run_case "${TEST_SCRIPT}" bad-snapshot-link failure
run_case "${TEST_SCRIPT}" bad-snapshot-duplicate failure
run_case "${TEST_SCRIPT}" success success
run_case "${TEST_SCRIPT}" large-valid-f success
run_case "${TEST_SCRIPT}" unchanged success
run_case "${TEST_SCRIPT}" unchanged-skew success
run_case "${TEST_SCRIPT}" unchanged-extra success
run_case "${TEST_SCRIPT}" corrupt-existing-f success
run_case "${TEST_SCRIPT}" oversized-existing-f success
run_case "${TEST_SCRIPT}" corrupt-existing-t success
run_case "${TEST_SCRIPT}" corrupt-existing-bp success
run_case "${TEST_SCRIPT}" corrupt-existing-s success
run_case "${TEST_SCRIPT}" changed-corrupt-existing success
run_case "${TEST_SCRIPT}" corrupt-existing-tp success
run_case "${TEST_SCRIPT}" corrupt-existing-tp-source success
run_case "${TEST_SCRIPT}" corrupt-existing-tp-bomb success
run_case "${TEST_SCRIPT}" quarantine-extra success
run_case "${TEST_SCRIPT}" symlink-existing success
run_case "${TEST_SCRIPT}" failed-repair-preserves-existing failure
run_case "${TEST_SCRIPT}" directory-existing failure

echo "F2/F5 regression tests passed"
