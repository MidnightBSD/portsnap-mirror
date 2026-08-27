#!/bin/sh -e

set -e
umask 077

TEST_TMP=`mktemp -d "${TMPDIR:-/tmp}/portsnap-clean-test.XXXXXX"` || exit 1
cleanup () {
	if [ -n "${TEST_TMP}" ] && [ -d "${TEST_TMP}" ]; then
		rm -r "${TEST_TMP}"
	fi
}
trap cleanup 0
trap 'exit 1' 1 2 15

TEST_PUB=${TEST_TMP}/htmldocs
TEST_STATE=${TEST_TMP}/.portsnap-clean
mkdir -p "${TEST_PUB}/bp" "${TEST_PUB}/f" "${TEST_PUB}/s" \
	"${TEST_PUB}/t" "${TEST_PUB}/tp"

TEST_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
TEST_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
TEST_C=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
TEST_D=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
TEST_E=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
TEST_F=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff

write_controls () {
	printf 'file|200000|%s\nfile|200001|%s\n' "${TEST_A}" "${TEST_B}" |
		gzip -c > "${TEST_PUB}/bl.gz"
	printf 'INDEX|200000|%s\nINDEX|200001|%s\n' "${TEST_C}" "${TEST_D}" |
		gzip -c > "${TEST_PUB}/tl.gz"
	printf 's/%s.tgz\nt/%s\nt/%s\n' "${TEST_E}" "${TEST_E}" "${TEST_F}" |
		gzip -c > "${TEST_PUB}/el.gz"
	printf 'latest\n' > "${TEST_PUB}/latest.ssl"
	printf 'public\n' > "${TEST_PUB}/pub.ssl"
	printf 'snapshot\n' > "${TEST_PUB}/snapshot.ssl"
}

write_controls
for TEST_PATH in \
	"f/${TEST_A}.gz" "f/${TEST_B}.gz" "f/${TEST_C}.gz" "f/${TEST_D}.gz" \
	"bp/${TEST_A}-${TEST_B}" "s/${TEST_E}.tgz" "t/${TEST_E}" "t/${TEST_F}" \
	"tp/${TEST_C}-${TEST_D}.gz"; do
	printf 'live\n' > "${TEST_PUB}/${TEST_PATH}"
done
for TEST_PATH in \
	"f/${TEST_E}.gz" "bp/${TEST_E}-${TEST_F}" "s/${TEST_F}.tgz" \
	"t/${TEST_A}" "tp/${TEST_E}-${TEST_F}.gz"; do
	printf 'stale\n' > "${TEST_PUB}/${TEST_PATH}"
done
printf 'operator file\n' > "${TEST_PUB}/f/README"

if ! sh ./portsnap-clean.sh --grace-days 0 "${TEST_PUB}" \
	> "${TEST_TMP}/dry-run" 2>&1; then
	cat "${TEST_TMP}/dry-run"
	exit 1
fi
[ ! -e "${TEST_STATE}" ]
[ -f "${TEST_PUB}/f/${TEST_E}.gz" ]
grep -q "Would quarantine f/${TEST_E}.gz" "${TEST_TMP}/dry-run"

sh ./portsnap-clean.sh --apply --grace-days 1 "${TEST_PUB}" \
	> "${TEST_TMP}/first-apply" 2>&1
[ -f "${TEST_PUB}/f/${TEST_E}.gz" ]
[ -s "${TEST_STATE}/candidates" ]
sed 's/|[0-9][0-9]*$/|1/' "${TEST_STATE}/candidates" \
	> "${TEST_STATE}/candidates.old"
mv "${TEST_STATE}/candidates.old" "${TEST_STATE}/candidates"

sh ./portsnap-clean.sh --apply --grace-days 1 "${TEST_PUB}" \
	> "${TEST_TMP}/second-apply" 2>&1
for TEST_PATH in \
	"f/${TEST_E}.gz" "bp/${TEST_E}-${TEST_F}" "s/${TEST_F}.tgz" \
	"t/${TEST_A}" "tp/${TEST_E}-${TEST_F}.gz"; do
	[ ! -e "${TEST_PUB}/${TEST_PATH}" ]
	done
for TEST_PATH in \
	"f/${TEST_A}.gz" "f/${TEST_B}.gz" "f/${TEST_C}.gz" "f/${TEST_D}.gz" \
	"bp/${TEST_A}-${TEST_B}" "s/${TEST_E}.tgz" "t/${TEST_E}" "t/${TEST_F}" \
	"tp/${TEST_C}-${TEST_D}.gz" "f/README"; do
	[ -f "${TEST_PUB}/${TEST_PATH}" ]
done
[ `find "${TEST_STATE}/quarantine" -type f | wc -l` -eq 5 ]

printf 'candidate\n' > "${TEST_PUB}/f/${TEST_E}.gz"
sh ./portsnap-clean.sh --apply --grace-days 1 "${TEST_PUB}" >/dev/null
grep -q "f/${TEST_E}.gz" "${TEST_STATE}/candidates"
printf 'restored|200002|%s\n' "${TEST_E}" > "${TEST_TMP}/tl.extra"
gunzip -c "${TEST_PUB}/tl.gz" >> "${TEST_TMP}/tl.extra"
gzip -c "${TEST_TMP}/tl.extra" > "${TEST_PUB}/tl.gz"
sh ./portsnap-clean.sh --apply --grace-days 1 "${TEST_PUB}" >/dev/null
! grep -q "f/${TEST_E}.gz" "${TEST_STATE}/candidates"
[ -f "${TEST_PUB}/f/${TEST_E}.gz" ]

cp "${TEST_PUB}/el.gz" "${TEST_TMP}/el.valid.gz"
printf 's/%s.tgz\nt/%s\n' "${TEST_E}" "${TEST_F}" |
	gzip -c > "${TEST_PUB}/el.gz"
if sh ./portsnap-clean.sh --apply --grace-days 0 "${TEST_PUB}" \
	> "${TEST_TMP}/incomplete-el-output" 2>&1; then
	echo "Incomplete snapshot manifest cleanup unexpectedly succeeded" >&2
	exit 1
fi
mv "${TEST_TMP}/el.valid.gz" "${TEST_PUB}/el.gz"

cp "${TEST_PUB}/bl.gz" "${TEST_TMP}/bl.valid.gz"
printf 'malformed\n' | gzip -c > "${TEST_PUB}/bl.gz"
if sh ./portsnap-clean.sh --apply --grace-days 0 "${TEST_PUB}" \
	> "${TEST_TMP}/malformed-output" 2>&1; then
	echo "Malformed manifest cleanup unexpectedly succeeded" >&2
	exit 1
fi
[ -f "${TEST_PUB}/f/${TEST_E}.gz" ]
mv "${TEST_TMP}/bl.valid.gz" "${TEST_PUB}/bl.gz"

mkdir -p "${TEST_STATE}/quarantine/1.1/f"
printf 'old quarantine\n' > "${TEST_STATE}/quarantine/1.1/f/old.gz"
sh ./portsnap-clean.sh --apply --quarantine-days 1 "${TEST_PUB}" >/dev/null
[ ! -e "${TEST_STATE}/quarantine/1.1" ]

TEST_NO_TP=${TEST_TMP}/secondary/htmldocs
mkdir -p "${TEST_NO_TP}/bp" "${TEST_NO_TP}/f" "${TEST_NO_TP}/s" \
	"${TEST_NO_TP}/t"
cp "${TEST_PUB}/bl.gz" "${TEST_PUB}/tl.gz" "${TEST_PUB}/el.gz" \
	"${TEST_PUB}/latest.ssl" "${TEST_PUB}/pub.ssl" \
	"${TEST_PUB}/snapshot.ssl" "${TEST_NO_TP}/"
sh ./portsnap-clean.sh "${TEST_NO_TP}" >/dev/null
[ ! -e "${TEST_TMP}/secondary/.portsnap-clean" ]
chmod g+w "${TEST_NO_TP}"
if sh ./portsnap-clean.sh "${TEST_NO_TP}" >/dev/null 2>&1; then
	echo "Writable publication directory cleanup unexpectedly succeeded" >&2
	exit 1
fi

echo "Manifest-aware cleanup regression tests passed"
