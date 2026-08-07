#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
package_script="${root}/tool/package_macos_release.sh"
sign_script="${root}/tool/sign_macos_bundle.sh"
rust_build_script="${root}/macos/scripts/build_ianvs_acp_rust.sh"
bundle_verify_script="${root}/tool/verify_macos_bundle.sh"
workflow="${root}/.github/workflows/macos.yml"
dependabot="${root}/.github/dependabot.yml"

test -x "${package_script}"
test -x "${sign_script}"
test -x "${rust_build_script}"
test -x "${bundle_verify_script}"
test -f "${workflow}"
test -f "${dependabot}"

sandbox=$(mktemp -d "${TMPDIR:-/tmp}/ianvs-acp-release-contract.XXXXXX")
cleanup() {
  rm -rf -- "${sandbox}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fake_bin="${sandbox}/bin"
trace="${sandbox}/trace"
mkdir -p "${fake_bin}"
for command in flutter ditto xcrun spctl codesign; do
  command_path="${fake_bin}/${command}"
  printf '%s\n' '#!/bin/sh' 'printf "%s\\n" "$0" >>"${RELEASE_TRACE}"' \
    'exit 99' >"${command_path}"
  chmod +x "${command_path}"
done

cat >"${fake_bin}/codesign" <<'FAKE_CODESIGN'
#!/bin/sh
set -eu

saw_runtime=0
saw_timestamp=0
last_argument=
while [ "$#" -gt 0 ]; do
  argument=$1
  shift
  case "${argument}" in
    --deep)
      exit 90
      ;;
    --options)
      [ "$#" -gt 0 ] || exit 91
      [ "$1" = runtime ] || exit 92
      saw_runtime=1
      last_argument=$1
      shift
      ;;
    --timestamp)
      saw_timestamp=1
      ;;
    --sign | --entitlements)
      [ "$#" -gt 0 ] || exit 93
      last_argument=$1
      shift
      ;;
    *)
      last_argument=${argument}
      ;;
  esac
done

[ "${saw_runtime}" -eq 1 ] || exit 94
[ "${saw_timestamp}" -eq 1 ] || exit 95
printf '%s\n' "${last_argument}" >>"${RELEASE_TRACE}"
FAKE_CODESIGN
chmod +x "${fake_bin}/codesign"

assert_package_rejects_missing_credentials() {
  set +e
  PATH="${fake_bin}:/usr/bin:/bin" RELEASE_TRACE="${trace}" \
    env -u IANVS_DEVELOPER_ID -u IANVS_NOTARY_PROFILE \
    "${package_script}" >/dev/null 2>&1
  status=$?
  set -e
  test "${status}" -ne 0
  test ! -s "${trace}"

  set +e
  PATH="${fake_bin}:/usr/bin:/bin" RELEASE_TRACE="${trace}" \
    IANVS_DEVELOPER_ID='contract-test-identity' \
    env -u IANVS_NOTARY_PROFILE "${package_script}" >/dev/null 2>&1
  status=$?
  set -e
  test "${status}" -ne 0
  test ! -s "${trace}"
}

assert_failed_release_preserves_previous_archive() {
  fixture_root="${sandbox}/package-fixture"
  fixture_script="${fixture_root}/tool/package_macos_release.sh"
  fixture_archive="${fixture_root}/build/ACP-Client.zip"
  mkdir -p "${fixture_root}/tool" "${fixture_root}/build" \
    "${sandbox}/package-tmp"
  cp "${package_script}" "${fixture_script}"
  chmod +x "${fixture_script}"
  printf '%s\n' 'previous-verified-release' >"${fixture_archive}"
  : >"${trace}"

  set +e
  PATH="${fake_bin}:/usr/bin:/bin" \
    TMPDIR="${sandbox}/package-tmp" RELEASE_TRACE="${trace}" \
    IANVS_DEVELOPER_ID='contract-test-identity' \
    IANVS_NOTARY_PROFILE='contract-test-profile' \
    "${fixture_script}" >/dev/null 2>&1
  status=$?
  set -e

  test "${status}" -eq 99
  test "$(cat "${fixture_archive}")" = 'previous-verified-release'
}

assert_sign_rejects_adhoc_identity() {
  app="${sandbox}/Fixture.app"
  mkdir -p "${app}"
  : >"${trace}"
  set +e
  PATH="${fake_bin}:/usr/bin:/bin" RELEASE_TRACE="${trace}" \
    "${sign_script}" "${app}" - >/dev/null 2>&1
  status=$?
  set -e
  test "${status}" -ne 0
  test ! -s "${trace}"
}

assert_nested_signing_order() {
  app="${sandbox}/Fixture With Spaces.app"
  outer_framework="${app}/Contents/Frameworks/Outer.framework"
  outer_binary="${outer_framework}/Versions/A/Outer"
  inner_framework="${outer_framework}/Versions/A/Frameworks/Inner.framework"
  inner_binary="${inner_framework}/Versions/A/Inner"
  helper_app="${app}/Contents/Frameworks/Helper Tool.app"
  helper_binary="${helper_app}/Contents/MacOS/Helper Tool"
  standalone_dylib="${app}/Contents/Frameworks/libfixture.dylib"
  mkdir -p "$(dirname -- "${outer_binary}")" \
    "$(dirname -- "${inner_binary}")" \
    "$(dirname -- "${helper_binary}")"
  cp /bin/echo "${outer_binary}"
  cp /bin/echo "${inner_binary}"
  cp /bin/echo "${helper_binary}"
  cp /bin/echo "${standalone_dylib}"
  : >"${trace}"

  RELEASE_TRACE="${trace}" IANVS_CODESIGN_BIN="${fake_bin}/codesign" \
    "${sign_script}" "${app}" 'Developer ID Application: Contract Test'

  line_of() {
    grep -n -F -x "$1" "${trace}" | cut -d: -f1
  }
  inner_binary_line=$(line_of "${inner_binary}")
  inner_framework_line=$(line_of "${inner_framework}")
  outer_binary_line=$(line_of "${outer_binary}")
  outer_framework_line=$(line_of "${outer_framework}")
  helper_binary_line=$(line_of "${helper_binary}")
  helper_app_line=$(line_of "${helper_app}")
  standalone_line=$(line_of "${standalone_dylib}")
  app_line=$(line_of "${app}")
  final_line=$(wc -l <"${trace}" | tr -d ' ')

  test "${inner_binary_line}" -lt "${inner_framework_line}"
  test "${inner_framework_line}" -lt "${outer_framework_line}"
  test "${outer_binary_line}" -lt "${outer_framework_line}"
  test "${helper_binary_line}" -lt "${helper_app_line}"
  test "${standalone_line}" -lt "${app_line}"
  test "${app_line}" -eq "${final_line}"
}

assert_static_release_contract() {
  grep -q -- '--options runtime' "${sign_script}"
  grep -q -- '--timestamp' "${sign_script}"
  grep -q -- '-depth' "${sign_script}"
  ! grep -Eq 'codesign[^\n]*--deep|set[[:space:]]+-x' \
    "${sign_script}" "${package_script}"
  grep -Eq 'verify_macos_bundle[.]sh.*--distribution' "${package_script}"

  notary_line=$(grep -n 'notarytool submit' "${package_script}" | cut -d: -f1)
  staple_line=$(grep -n 'stapler staple' "${package_script}" | cut -d: -f1)
  validate_line=$(grep -n 'stapler validate' "${package_script}" | cut -d: -f1)
  assess_line=$(grep -n 'spctl.*--assess' "${package_script}" | cut -d: -f1)
  notary_archive_line=$(grep -n '/usr/bin/ditto' "${package_script}" \
    | head -1 | cut -d: -f1)
  final_archive_line=$(grep -n '/usr/bin/ditto' "${package_script}" \
    | tail -1 | cut -d: -f1)
  test "${notary_archive_line}" -lt "${notary_line}"
  test "${notary_line}" -lt "${staple_line}"
  test "${staple_line}" -lt "${validate_line}"
  test "${validate_line}" -lt "${assess_line}"
  test "${assess_line}" -lt "${final_archive_line}"
  grep -q 'notary_archive' "${package_script}"
  grep -q '/bin/mv -f --' "${package_script}"
  grep -q 'Contents/Resources' "${sign_script}"

  grep -q 'actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5' \
    "${workflow}"
  ! grep -q 'subosito/flutter-action' "${workflow}"
  grep -q 'flutter_macos_arm64_3[.]44[.]0-stable[.]zip' "${workflow}"
  grep -q '0d4d1d3f379d18aff392291be6871d63bf090a9e81078d4c4bc84e6208603dca' \
    "${workflow}"
  grep -q 'curl --fail' "${workflow}"
  grep -q -- "--proto '=https'" "${workflow}"
  grep -q -- '--retry 5' "${workflow}"
  grep -q 'shasum -a 256 -c -' "${workflow}"
  grep -q 'GITHUB_PATH' "${workflow}"
  grep -q 'GITHUB_ENV' "${workflow}"
  grep -q '559ffa3f75e7402d65a8def9c28389a9b2e6fe42' "${workflow}"
  grep -q 'flutter --version --machine' "${workflow}"
  grep -q 'contents: read' "${workflow}"
  grep -q 'flutter build macos --config-only --no-pub' "${workflow}"
  grep -q 'pod install --deployment --project-directory=macos' "${workflow}"
  grep -q 'tool/verify_rust_runtime[.]sh' "${workflow}"
  ! grep -q 'cache: true' "${workflow}"
  ! grep -q 'secrets[.]' "${workflow}"
  ! grep -Eq 'uses:.*@(main|master|v[0-9]+)([[:space:]]|$)' "${workflow}"
}

assert_package_rejects_missing_credentials
assert_failed_release_preserves_previous_archive
assert_sign_rejects_adhoc_identity
assert_nested_signing_order
assert_static_release_contract

printf '%s\n' 'release script contract tests passed'
