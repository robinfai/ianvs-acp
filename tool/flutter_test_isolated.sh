#!/bin/sh
set -eu

umask 077

TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/ianvs-acp-test-home.XXXXXX")
child_pid=

cleanup() {
  if [ -n "${TEST_HOME}" ] && [ -d "${TEST_HOME}" ]; then
    rm -rf -- "${TEST_HOME}"
  fi
}

forward_signal() {
  signal=$1
  exit_code=$2
  trap - "${signal}"
  if [ -n "${child_pid}" ]; then
    kill -"${signal}" "${child_pid}" 2>/dev/null || :
    wait "${child_pid}" 2>/dev/null || :
    child_pid=
  fi
  exit "${exit_code}"
}

trap cleanup EXIT
trap 'forward_signal INT 130' INT
trap 'forward_signal TERM 143' TERM

export HOME="${TEST_HOME}"
export XDG_CONFIG_HOME="${TEST_HOME}/.config"
export FLUTTER_SUPPRESS_ANALYTICS=true

flutter test --no-pub "$@" &
child_pid=$!
set +e
wait "${child_pid}"
exit_code=$?
set -e
child_pid=
exit "${exit_code}"
