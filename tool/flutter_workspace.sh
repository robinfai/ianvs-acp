#!/bin/sh
# Run the same offline checks for the app, reusable package and example.
set -eu

workspace_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
action=${1:-help}
project=${2:-all}
if [ "$#" -ge 2 ]; then shift 2; elif [ "$#" -eq 1 ]; then shift; fi

run_project() (
  project_name=$1
  shift
  case "$project_name" in
    app) project_dir="$workspace_root" ;;
    chat) project_dir="$workspace_root/packages/ianvs_agent_chat" ;;
    example) project_dir="$workspace_root/packages/ianvs_agent_chat/example" ;;
    *) printf 'Unknown project: %s\n' "$project_name" >&2; exit 2 ;;
  esac
  cd "$project_dir"
  printf '\n[%s] %s\n' "$project_name" "$action"
  case "$action" in
    bootstrap) "${FLUTTER:-flutter}" pub get "$@" ;;
    analyze) "${FLUTTER:-flutter}" analyze --no-pub "$@" ;;
    format) "${DART:-dart}" format lib test "$@" ;;
    format-check) "${DART:-dart}" format --output=none --set-exit-if-changed lib test "$@" ;;
    test)
      # Live provider tests remain an explicit, separately invoked check.
      RUN_DEEPSEEK_TESTS=0 "$workspace_root/tool/flutter_test_isolated.sh" "$@"
      ;;
    *) printf 'Usage: %s {bootstrap|analyze|format|format-check|test} [all|app|chat|example] [arguments]\n' "$0" >&2; exit 2 ;;
  esac
)

if [ "$project" = all ]; then
  for workspace_project in app chat example; do
    run_project "$workspace_project" "$@"
  done
else
  run_project "$project" "$@"
fi
