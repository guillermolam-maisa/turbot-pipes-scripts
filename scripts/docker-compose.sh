#!/usr/bin/env bash

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  echo "Do not source this script. Run it with: bash ${BASH_SOURCE[0]} [compose args]" >&2
  return 1 2>/dev/null || exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker is not installed" >&2
  exit 1
fi

DOCKER_COMPOSE_USE_SUDO="${DOCKER_COMPOSE_USE_SUDO:-auto}"
subcommand=""
for arg in "$@"; do
  case "${arg}" in
    -f|--file|--env-file|--profile|--project-name)
      skip_next=1
      ;;
    *)
      if [[ "${skip_next:-0}" -eq 1 ]]; then
        skip_next=0
        continue
      fi
      if [[ "${arg}" != -* ]]; then
        subcommand="${arg}"
        break
      fi
      ;;
  esac
done

case "${subcommand}" in
  config|version)
    exec docker compose "$@"
    ;;
esac

if [[ "${DOCKER_COMPOSE_USE_SUDO}" == "never" ]]; then
  exec docker compose "$@"
fi

if docker ps >/dev/null 2>&1; then
  exec docker compose "$@"
fi

if [[ "${DOCKER_COMPOSE_USE_SUDO}" == "always" ]] && command -v sudo >/dev/null 2>&1; then
  exec sudo docker compose "$@"
fi

if [[ "${DOCKER_COMPOSE_USE_SUDO}" == "auto" ]] && command -v sudo >/dev/null 2>&1 && sudo -n docker ps >/dev/null 2>&1; then
  exec sudo docker compose "$@"
fi

if [[ "${DOCKER_COMPOSE_USE_SUDO}" == "auto" ]] && command -v sudo >/dev/null 2>&1 && [[ -t 0 && -t 1 ]]; then
  exec sudo docker compose "$@"
fi

echo "ERROR: docker daemon requires elevated privileges for this user." >&2
echo "Set DOCKER_COMPOSE_USE_SUDO=always to force sudo, or DOCKER_COMPOSE_USE_SUDO=never to disable it." >&2
exit 1
