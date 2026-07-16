#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SUBJECT="${ROOT}/tool/flutter_test_isolated.sh"
CALLER_HOME=${HOME:-}
SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/ianvs-acp-isolation-test.XXXXXX")

cleanup() {
  rm -rf -- "${SANDBOX}"
}
handle_interrupt() {
  exit 130
}
handle_termination() {
  exit 143
}
trap cleanup EXIT
trap handle_interrupt INT
trap handle_termination TERM

FAKE_BIN="${SANDBOX}/bin"
mkdir -p "${FAKE_BIN}"

cat >"${FAKE_BIN}/flutter" <<'FAKE_FLUTTER'
#!/bin/sh
set -eu

: "${HOME_LOG:?HOME_LOG is required}"
: "${CALLER_HOME:=}"

if [ "${HOME}" = "${CALLER_HOME}" ]; then
  exit 91
fi
if [ "${XDG_CONFIG_HOME}" != "${HOME}/.config" ]; then
  exit 92
fi

printf '%s\n' "${HOME}" >>"${HOME_LOG}"
touch "${HOME}/fake-flutter-probe"

if [ -n "${FAKE_FLUTTER_STARTED_FILE:-}" ]; then
  touch "${FAKE_FLUTTER_STARTED_FILE}"
  trap 'exit 143' TERM
  while :; do
    sleep 1
  done
fi

exit "${FAKE_FLUTTER_EXIT:-0}"
FAKE_FLUTTER
chmod +x "${FAKE_BIN}/flutter"

run_subject() {
  PATH="${FAKE_BIN}:${PATH}" \
    CALLER_HOME="${CALLER_HOME}" \
    HOME_LOG="$1" \
    FAKE_FLUTTER_EXIT="$2" \
    "${SUBJECT}" sample_test.dart
}

success_log="${SANDBOX}/success.log"
run_subject "${success_log}" 0
success_home=$(cat "${success_log}")
test ! -e "${success_home}"

failure_log="${SANDBOX}/failure.log"
set +e
run_subject "${failure_log}" 23
failure_status=$?
set -e
test "${failure_status}" -eq 23
failure_home=$(cat "${failure_log}")
test ! -e "${failure_home}"

signal_log="${SANDBOX}/signal.log"
signal_started="${SANDBOX}/signal.started"
PATH="${FAKE_BIN}:${PATH}" \
  CALLER_HOME="${CALLER_HOME}" \
  HOME_LOG="${signal_log}" \
  FAKE_FLUTTER_STARTED_FILE="${signal_started}" \
  "${SUBJECT}" sample_test.dart &
signal_pid=$!
signal_wait_attempts=0
while [ ! -e "${signal_started}" ]; do
  signal_wait_attempts=$((signal_wait_attempts + 1))
  if [ "${signal_wait_attempts}" -ge 500 ]; then
    kill -TERM "${signal_pid}" 2>/dev/null || :
    wait "${signal_pid}" 2>/dev/null || :
    printf '%s\n' 'timed out waiting for fake flutter to start' >&2
    exit 1
  fi
  sleep 0.01
done
kill -TERM "${signal_pid}"
set +e
wait "${signal_pid}"
signal_status=$?
set -e
test "${signal_status}" -eq 143
signal_home=$(cat "${signal_log}")
test ! -e "${signal_home}"

parallel_log="${SANDBOX}/parallel.log"
run_subject "${parallel_log}" 0 &
first_pid=$!
run_subject "${parallel_log}" 0 &
second_pid=$!
wait "${first_pid}"
wait "${second_pid}"
test "$(sort -u "${parallel_log}" | wc -l | tr -d ' ')" -eq 2
while IFS= read -r test_home; do
  test ! -e "${test_home}"
done <"${parallel_log}"

printf '%s\n' 'flutter_test_isolated.sh contract tests passed'
