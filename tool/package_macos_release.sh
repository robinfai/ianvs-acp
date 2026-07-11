#!/bin/sh
set -euf

: "${IANVS_DEVELOPER_ID:?set IANVS_DEVELOPER_ID}"
: "${IANVS_NOTARY_PROFILE:?set IANVS_NOTARY_PROFILE}"
[ "${IANVS_DEVELOPER_ID}" != '-' ] || {
  printf '%s\n' 'error: ad-hoc signing is not allowed for distribution' >&2
  exit 1
}

umask 077
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "${script_dir}/.." && pwd)
cd "${project_root}"

app='build/macos/Build/Products/Release/ACP Client.app'
archive='build/ACP-Client.zip'
notary_dir=$(mktemp -d "${TMPDIR:-/tmp}/ianvs-acp-notary.XXXXXX")
notary_archive="${notary_dir}/ACP-Client.zip"
final_archive_dir=
final_archive_tmp=
cleanup() {
  rm -rf -- "${notary_dir}"
  if [ -n "${final_archive_dir}" ]; then
    rm -rf -- "${final_archive_dir}"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

flutter pub get
flutter build macos --release --no-pub
IANVS_CODESIGN_BIN=/usr/bin/codesign \
  "${script_dir}/sign_macos_bundle.sh" "${app}" "${IANVS_DEVELOPER_ID}"
"${script_dir}/verify_macos_bundle.sh" --distribution "${app}"

/usr/bin/ditto -c -k --keepParent "${app}" "${notary_archive}"
/usr/bin/xcrun notarytool submit "${notary_archive}" \
  --keychain-profile "${IANVS_NOTARY_PROFILE}" --wait
/usr/bin/xcrun stapler staple "${app}"
/usr/bin/xcrun stapler validate "${app}"
"${script_dir}/verify_macos_bundle.sh" --distribution "${app}"
/usr/sbin/spctl --assess --type execute --verbose=4 "${app}"
final_archive_dir=$(mktemp -d 'build/.ACP-Client.zip.XXXXXX')
final_archive_tmp="${final_archive_dir}/ACP-Client.zip"
/usr/bin/ditto -c -k --keepParent "${app}" "${final_archive_tmp}"
/bin/mv -f -- "${final_archive_tmp}" "${archive}"
final_archive_tmp=
rmdir "${final_archive_dir}"
final_archive_dir=
