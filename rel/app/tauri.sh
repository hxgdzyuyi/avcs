#!/usr/bin/env bash
set -euo pipefail

main() {
  export MIX_TARGET="app"

  root_dir="$(cd "$(dirname "$0")" && pwd)"
  mix_project_dir="${root_dir}/../.."
  app="Avcs"
  target="aarch64-apple-darwin"
  command="${1:-build}"

  if [ $# -gt 0 ]; then
    shift
  fi

  if [ "$(uname -s)" != "Darwin" ]; then
    echo "Avcs desktop packaging currently supports only macOS Apple Silicon." >&2
    exit 1
  fi

  if [ "$(uname -m)" != "arm64" ]; then
    echo "Avcs desktop packaging currently supports only arm64 Apple Silicon hosts." >&2
    exit 1
  fi

  tauri_args=()

  while [ $# -gt 0 ]; do
    case "$1" in
      --target)
        if [ $# -lt 2 ]; then
          echo "--target requires a value." >&2
          exit 1
        fi

        target="${2:-}"
        shift 2
        ;;
      --target=*)
        target="${1#--target=}"
        shift
        ;;
      *)
        tauri_args+=("$1")
        shift
        ;;
    esac
  done

  if [ "$target" != "aarch64-apple-darwin" ]; then
    echo "Unsupported target: ${target}. Use aarch64-apple-darwin." >&2
    exit 1
  fi

  if [ "${#tauri_args[@]}" -gt 0 ]; then
    set -- "${tauri_args[@]}"
  else
    set --
  fi

  release_root="$root_dir/src-tauri/rel-darwin"
  config_json='{"bundle":{"resources":{"rel-darwin":"rel"}}}'

  if [ -z "${MIX_ENV:-}" ]; then
    export MIX_ENV="prod"
  fi

  case "$command" in
    build)
      build_release
      run_tauri_build "$config_json" "$@"
      ;;
    app)
      build_release
      run_tauri_build "$config_json" "$@"
      open_app
      ;;
    *)
      cargo tauri "$command" "$@"
      ;;
  esac
}

build_release() {
  (
    cd "${mix_project_dir}/web"
    npm ci
    npm run build
  )

  (
    cd "${mix_project_dir}"
    mix local.hex --force --if-missing
    mix local.rebar --force --if-missing
    mix deps.get
    mix release app --overwrite --path "$release_root"
  )
}

run_tauri_build() {
  local config_json="$1"
  shift

  (
    cd "${root_dir}/src-tauri"
    cargo tauri build --config "$config_json" --target aarch64-apple-darwin --bundles app "$@"
  )
}

open_app() {
  local app_path="${root_dir}/src-tauri/target/aarch64-apple-darwin/release/bundle/macos/${app}.app"
  open -W "$app_path"
}

main "$@"
