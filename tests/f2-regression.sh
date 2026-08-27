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
while read TEST_LINE; do
	printf '%s%s\n' "${TEST_PREFIX}" "${TEST_LINE}"
done < "$3"
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

chmod +x "${TEST_BINDIR}/phttpget" "${TEST_BINDIR}/fetch" \
	"${TEST_BINDIR}/lam" "${TEST_BINDIR}/sha256" \
	"${TEST_BINDIR}/xargs" "${TEST_BINDIR}/mktemp"

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

	TEST_HASH=`printf 'valid metadata\n' | sha256sum | awk '{ print $1 }'`
	TEST_TAG_HASH=`printf 'valid tag\n' | sha256sum | awk '{ print $1 }'`
	TEST_SENTINEL=0000000000000000000000000000000000000000000000000000000000000000
	printf 'INDEX|200000|%s|200001|%s\n' "${TEST_HASH}" "${TEST_HASH}" \
		> "${TEST_CASE}/bl"
	: > "${TEST_CASE}/tl"
	printf 's/%s.tgz\nt/%s\n' "${TEST_HASH}" "${TEST_TAG_HASH}" \
		> "${TEST_CASE}/el"
	gzip -c "${TEST_CASE}/bl" > "${TEST_ORIGIN}/bl.gz"
	gzip -c "${TEST_CASE}/tl" > "${TEST_ORIGIN}/tl.gz"
	gzip -c "${TEST_CASE}/el" > "${TEST_ORIGIN}/el.gz"
	printf 'public key\n' > "${TEST_ORIGIN}/pub.ssl"
	printf 'snapshot signature\n' > "${TEST_ORIGIN}/snapshot.ssl"
	printf 'new signature\n' > "${TEST_ORIGIN}/latest.ssl"
	printf 'binary patch\n' > "${TEST_ORIGIN}/bp/${TEST_HASH}-${TEST_HASH}"
	printf 'snapshot\n' > "${TEST_ORIGIN}/s/${TEST_HASH}.tgz"
	case ${TEST_MODE} in
	bad-tag) printf 'invalid tag\n' > "${TEST_ORIGIN}/t/${TEST_TAG_HASH}" ;;
	*) printf 'valid tag\n' > "${TEST_ORIGIN}/t/${TEST_TAG_HASH}" ;;
	esac
	printf 'public key\n' > "${TEST_PUBDIR}/pub.ssl"
	: > "${TEST_PUBDIR}/indextimes"

	case ${TEST_MODE} in
	bad-hash)
		printf 'invalid metadata\n' | gzip -c \
			> "${TEST_ORIGIN}/f/${TEST_HASH}.gz"
		;;
	*)
		printf 'valid metadata\n' | gzip -c \
			> "${TEST_ORIGIN}/f/${TEST_HASH}.gz"
		;;
	esac

	case ${TEST_MODE} in
	unchanged|unchanged-skew)
		printf 'new signature\n' > "${TEST_PUBDIR}/latest.ssl"
		cp "${TEST_ORIGIN}/bl.gz" "${TEST_PUBDIR}/bl.gz"
		cp "${TEST_ORIGIN}/tl.gz" "${TEST_PUBDIR}/tl.gz"
		cp "${TEST_ORIGIN}/el.gz" "${TEST_PUBDIR}/el.gz"
		cp "${TEST_PUBDIR}/bl.gz" "${TEST_CASE}/published-bl.gz"
		printf 'retained object\n' \
			> "${TEST_PUBDIR}/f/${TEST_SENTINEL}.gz"
		;;
	*) printf 'old signature\n' > "${TEST_PUBDIR}/latest.ssl" ;;
	esac
	if [ "${TEST_MODE}" = unchanged-skew ]; then
		: > "${TEST_CASE}/skew-bl"
		gzip -c "${TEST_CASE}/skew-bl" > "${TEST_ORIGIN}/bl.gz"
	fi

	sed 's#/usr/libexec/phttpget#phttpget#' "${TEST_SCRIPT}" \
		> "${TEST_CASE}/mirror.sh"

	TEST_FAIL_OBJECT=
	TEST_OMIT_OBJECT=
	case ${TEST_MODE} in
	failure) TEST_FAIL_OBJECT=f/${TEST_HASH}.gz ;;
	missing) TEST_OMIT_OBJECT=f/${TEST_HASH}.gz ;;
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
		[ -f "${TEST_PUBDIR}/bp/${TEST_HASH}-${TEST_HASH}" ]
		[ -f "${TEST_PUBDIR}/s/${TEST_HASH}.tgz" ]
		[ -f "${TEST_PUBDIR}/t/${TEST_TAG_HASH}" ]
		[ `gunzip -c "${TEST_PUBDIR}/f/${TEST_HASH}.gz" | sha256sum | awk '{ print $1 }'` = "${TEST_HASH}" ]
		[ `sha256sum "${TEST_PUBDIR}/t/${TEST_TAG_HASH}" | awk '{ print $1 }'` = "${TEST_TAG_HASH}" ]
		cmp -s "${TEST_ORIGIN}/latest.ssl" "${TEST_PUBDIR}/latest.ssl"
		if [ -f "${TEST_CASE}/published-bl.gz" ]; then
			cmp -s "${TEST_CASE}/published-bl.gz" "${TEST_PUBDIR}/bl.gz"
			[ -f "${TEST_PUBDIR}/f/${TEST_SENTINEL}.gz" ]
		fi
		;;
	failure)
		[ ${TEST_STATUS} -ne 0 ]
		[ ! -f "${TEST_PUBDIR}/f/${TEST_HASH}.gz" ]
		[ ! -f "${TEST_PUBDIR}/bp/${TEST_HASH}-${TEST_HASH}" ]
		[ ! -f "${TEST_PUBDIR}/s/${TEST_HASH}.tgz" ]
		[ ! -f "${TEST_PUBDIR}/t/${TEST_TAG_HASH}" ]
		grep -q '^old signature$' "${TEST_PUBDIR}/latest.ssl"
		;;
	esac
}

for TEST_SCRIPT in pmirror.sh ps-mirror.sh; do
	run_case "${TEST_SCRIPT}" failure failure
	run_case "${TEST_SCRIPT}" missing failure
	run_case "${TEST_SCRIPT}" bad-hash failure
	run_case "${TEST_SCRIPT}" bad-tag failure
	run_case "${TEST_SCRIPT}" success success
	run_case "${TEST_SCRIPT}" unchanged success
	run_case "${TEST_SCRIPT}" unchanged-skew success
done

echo "F2 regression tests passed"
