#!/usr/bin/env bash

env_app_dir() {
  local env_name="$1"
  case "$env_name" in
    production) printf '%s' "${BASE_DIR}/storeconsole.com" ;;
    staging)    printf '%s' "${BASE_DIR}/staging.storeconsole.com" ;;
    dev)        printf '%s' "${BASE_DIR}/dev.storeconsole.com" ;;
    *)          printf '%s' "${BASE_DIR}/${env_name}" ;;
  esac
}

runtime_web_running() {
  local env_name="$1"
  local color="$2"

  docker ps --format '{{.Names}}' | grep -Fxq "storeconsole-${env_name}-web-${color}"
}

runtime_color_from_upstream() {
  local env_name="$1"
  local upstream_file="${BASE_DIR}/_proxy/nginx/upstreams/storeconsole-${env_name}-active.conf"

  if [[ -f "$upstream_file" ]]; then
    sed -n "s/.*storeconsole-${env_name}-web-\\(blue\\|green\\):9000.*/\\1/p" "$upstream_file" | head -n 1
  fi
}

resolve_active_color() {
  local env_name="$1"
  local app_dir="$(env_app_dir "$env_name")"
  local marker_color
  local upstream_color
  local candidate
  local seen=" "

  marker_color="$(cat "${app_dir}/active_color" 2>/dev/null || true)"
  upstream_color="$(runtime_color_from_upstream "$env_name")"

  for candidate in "$marker_color" "$upstream_color" green blue; do
    if [[ "$candidate" != "blue" && "$candidate" != "green" ]]; then
      continue
    fi

    if [[ "$seen" == *" ${candidate} "* ]]; then
      continue
    fi
    seen="${seen}${candidate} "

    if runtime_web_running "$env_name" "$candidate"; then
      printf '%s' "$candidate"
      return 0
    fi
  done

  if [[ "$upstream_color" == "blue" || "$upstream_color" == "green" ]]; then
    printf '%s' "$upstream_color"
    return 0
  fi

  if [[ "$marker_color" == "blue" || "$marker_color" == "green" ]]; then
    printf '%s' "$marker_color"
    return 0
  fi

  printf 'blue'
}

sync_active_runtime_marker() {
  local env_name="$1"
  local color="$2"
  local app_dir="$(env_app_dir "$env_name")"

  echo "$color" > "${app_dir}/active_color"
  ln -sfn "$color" "${app_dir}/active"
}
