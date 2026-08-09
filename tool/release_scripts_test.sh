#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
package_script="${root}/tool/package_macos_release.sh"
sign_script="${root}/tool/sign_macos_bundle.sh"
rust_build_script="${root}/macos/scripts/build_ianvs_acp_rust.sh"
bundle_verify_script="${root}/tool/verify_macos_bundle.sh"
signing_verify_script="${root}/tool/verify_macos_signing_closure.sh"
runner_project="${root}/macos/Runner.xcodeproj/project.pbxproj"
release_entitlements="${root}/macos/Runner/Release.entitlements"
workflow="${root}/.github/workflows/macos.yml"
dependabot="${root}/.github/dependabot.yml"

test -x "${package_script}"
test -x "${sign_script}"
test -x "${rust_build_script}"
test -x "${bundle_verify_script}"
test -x "${signing_verify_script}"
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

assert_package_starts_with_absent_app_bundle() {
  fixture_root="${sandbox}/clean-build-fixture"
  fixture_script="${fixture_root}/tool/package_macos_release.sh"
  fixture_app="${fixture_root}/build/macos/Build/Products/Release/ACP Client.app"
  mkdir -p "${fixture_root}/tool" "${fixture_app}/Contents" \
    "${sandbox}/clean-build-tmp"
  cp "${package_script}" "${fixture_script}"
  chmod +x "${fixture_script}"
  printf '%s\n' 'stale-build-product' >"${fixture_app}/Contents/stale-marker"
  : >"${trace}"

  set +e
  PATH="${fake_bin}:/usr/bin:/bin" \
    TMPDIR="${sandbox}/clean-build-tmp" RELEASE_TRACE="${trace}" \
    IANVS_DEVELOPER_ID='contract-test-identity' \
    IANVS_NOTARY_PROFILE='contract-test-profile' \
    "${fixture_script}" >/dev/null 2>&1
  status=$?
  set -e

  test "${status}" -eq 99
  test ! -e "${fixture_app}"
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

assert_rust_build_sets_install_name_and_signs_library() {
  fixture_root="${sandbox}/rust-build-fixture"
  fixture_rust="${fixture_root}/rust"
  fixture_products="${fixture_root}/products"
  fixture_app="${fixture_products}/Fixture.app"
  fixture_frameworks="${fixture_app}/Contents/Frameworks"
  fixture_bin="${fixture_root}/bin"
  fixture_trace="${fixture_root}/trace"
  mkdir -p "${fixture_root}/macos" "${fixture_rust}/target/debug" \
    "${fixture_frameworks}" "${fixture_bin}"
  cp /bin/echo "${fixture_rust}/target/debug/libianvs_acp_ffi.dylib"

  cat >"${fixture_bin}/cargo" <<'FAKE_CARGO'
#!/bin/sh
exit 0
FAKE_CARGO
  cat >"${fixture_bin}/install_name_tool" <<'FAKE_INSTALL_NAME_TOOL'
#!/bin/sh
printf 'install-name:%s\n' "$*" >>"${RUST_BUILD_TRACE}"
FAKE_INSTALL_NAME_TOOL
  cat >"${fixture_bin}/codesign" <<'FAKE_RUST_CODESIGN'
#!/bin/sh
printf 'codesign:%s\n' "$*" >>"${RUST_BUILD_TRACE}"
FAKE_RUST_CODESIGN
  chmod +x "${fixture_bin}/cargo" "${fixture_bin}/install_name_tool" \
    "${fixture_bin}/codesign"

  PATH="${fixture_bin}:/usr/bin:/bin" \
    RUST_BUILD_TRACE="${fixture_trace}" \
    SRCROOT="${fixture_root}/macos" \
    CONFIGURATION=Debug \
    TARGET_BUILD_DIR="${fixture_products}" \
    FRAMEWORKS_FOLDER_PATH='Fixture.app/Contents/Frameworks' \
    CODE_SIGN_IDENTITY=- \
    IANVS_CODESIGN_BIN="${fixture_bin}/codesign" \
    "${rust_build_script}"

  test -f "${fixture_frameworks}/libianvs_acp_ffi.dylib"
  grep -q '^install-name:-id @rpath/libianvs_acp_ffi.dylib ' "${fixture_trace}"
  grep -q '^codesign:--force --sign - --timestamp=none ' "${fixture_trace}"

  : >"${fixture_trace}"
  PATH="${fixture_bin}:/usr/bin:/bin" \
    RUST_BUILD_TRACE="${fixture_trace}" \
    SRCROOT="${fixture_root}/macos" \
    CONFIGURATION=Debug \
    TARGET_BUILD_DIR="${fixture_products}" \
    FRAMEWORKS_FOLDER_PATH='Fixture.app/Contents/Frameworks' \
    EXPANDED_CODE_SIGN_IDENTITY='Developer ID Application: Contract Test' \
    IANVS_CODESIGN_BIN="${fixture_bin}/codesign" \
    "${rust_build_script}"
  grep -q \
    '^codesign:--force --sign Developer ID Application: Contract Test --options runtime --timestamp ' \
    "${fixture_trace}"
}

assert_signing_closure_contract() {
  fixture_root="${sandbox}/signing-closure-fixture"
  fixture_app="${fixture_root}/Fixture.app"
  fixture_main="${fixture_app}/Contents/MacOS/Fixture"
  fixture_library="${fixture_app}/Contents/Frameworks/libfixture.dylib"
  fixture_codesign="${fixture_root}/codesign"
  mkdir -p "$(dirname -- "${fixture_main}")" \
    "$(dirname -- "${fixture_library}")"
  cp /bin/echo "${fixture_main}"
  cp /bin/echo "${fixture_library}"

  cat >"${fixture_codesign}" <<'FAKE_CLOSURE_CODESIGN'
#!/bin/sh
set -eu

display=0
last_argument=
for argument in "$@"; do
  [ "${argument}" = '--display' ] && display=1
  last_argument=${argument}
done
[ "${display}" -eq 1 ] || exit 0

case "${SIGNING_FIXTURE_MODE}" in
  adhoc | adhoc_runtime | adhoc_nested_signed)
    if [ "${SIGNING_FIXTURE_MODE}" = adhoc_nested_signed ] \
      && [ "${last_argument##*/}" = libfixture.dylib ]; then
      printf '%s\n' \
        'CodeDirectory v=20500 flags=0x10000(runtime)' \
        'Authority=Developer ID Application: Contract Test' \
        'TeamIdentifier=TESTTEAM' \
        'Timestamp=Aug 9, 2026 at 12:00:00' >&2
      exit 0
    fi
    flags='0x2(adhoc)'
    if [ "${SIGNING_FIXTURE_MODE}" = adhoc_runtime ] \
      && [ -d "${last_argument}" ]; then
      flags='0x10002(adhoc,runtime)'
    fi
    printf '%s\n' \
      "CodeDirectory v=20500 flags=${flags}" \
      'Signature=adhoc' \
      'TeamIdentifier=not set' >&2
    ;;
  distribution | team_mismatch)
    team=TESTTEAM
    if [ "${SIGNING_FIXTURE_MODE}" = team_mismatch ] \
      && [ "${last_argument##*/}" = libfixture.dylib ]; then
      team=OTHERTEAM
    fi
    printf '%s\n' \
      'CodeDirectory v=20500 flags=0x10000(runtime)' \
      'Authority=Developer ID Application: Contract Test' \
      "TeamIdentifier=${team}" \
      'Timestamp=Aug 9, 2026 at 12:00:00' >&2
    ;;
  *)
    exit 96
    ;;
esac
FAKE_CLOSURE_CODESIGN
  chmod +x "${fixture_codesign}"

  SIGNING_FIXTURE_MODE=adhoc IANVS_CODESIGN_BIN="${fixture_codesign}" \
    "${signing_verify_script}" "${fixture_app}" >/dev/null
  SIGNING_FIXTURE_MODE=distribution IANVS_CODESIGN_BIN="${fixture_codesign}" \
    "${signing_verify_script}" --distribution "${fixture_app}" >/dev/null

  set +e
  SIGNING_FIXTURE_MODE=adhoc_runtime IANVS_CODESIGN_BIN="${fixture_codesign}" \
    "${signing_verify_script}" "${fixture_app}" >/dev/null 2>&1
  runtime_status=$?
  SIGNING_FIXTURE_MODE=team_mismatch IANVS_CODESIGN_BIN="${fixture_codesign}" \
    "${signing_verify_script}" "${fixture_app}" >/dev/null 2>&1
  team_status=$?
  SIGNING_FIXTURE_MODE=adhoc_nested_signed \
    IANVS_CODESIGN_BIN="${fixture_codesign}" \
    "${signing_verify_script}" "${fixture_app}" >/dev/null 2>&1
  nested_semantics_status=$?
  set -e
  test "${runtime_status}" -ne 0
  test "${team_status}" -ne 0
  test "${nested_semantics_status}" -ne 0
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
  grep -q 'unexpected ianvs ACP runtime install name' "${bundle_verify_script}"
  grep -q 'ianvs ACP runtime exports do not match the current host ABI' \
    "${bundle_verify_script}"
  grep -q 'verify_macos_signing_closure[.]sh' "${bundle_verify_script}"
  grep -q 'app and nested Mach-O have different signing teams' \
    "${signing_verify_script}"
  grep -q 'ad-hoc app must not enable Hardened Runtime' \
    "${signing_verify_script}"
  grep -q '_ianvs_acp_poll_events' "${bundle_verify_script}"
  grep -q 'ENABLE_HARDENED_RUNTIME = NO;' "${runner_project}"
  ! grep -q 'com[.]apple[.]security[.]cs[.]disable-library-validation' \
    "${release_entitlements}"

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
assert_package_starts_with_absent_app_bundle
assert_sign_rejects_adhoc_identity
assert_nested_signing_order
assert_rust_build_sets_install_name_and_signs_library
assert_signing_closure_contract
assert_static_release_contract

printf '%s\n' 'release script contract tests passed'
