#!/usr/bin/env bash
# Клиент раннера для контейнера агента: запрашивает одну цель make и печатает её вывод.
# Параметры подключения берутся из окружения (заполняются из .env через env_file).
#
# Использование:
#   call.sh <цель>
#
# Пример:
#   call.sh up
set -euo pipefail

TARGET="${1:-}"
if [ -z "$TARGET" ]; then
  echo "Использование: $(basename "$0") <цель make>" >&2
  exit 2
fi

URL="${AGENT_RUNNER_URL:-}"
TOKEN="${AGENT_RUNNER_TOKEN:-}"
if [ -z "$URL" ] || [ -z "$TOKEN" ]; then
  echo "Не заданы AGENT_RUNNER_URL и/или AGENT_RUNNER_TOKEN" >&2
  exit 2
fi

# --content-on-error печатает тело и при статусе 4xx: отказ раннера — это не недоступность,
# поэтому код возврата wget сам по себе о доставке запроса не говорит
set +e
response=$(wget -q -O - --content-on-error \
  --header="X-Runner-Token: ${TOKEN}" \
  --tries=1 --connect-timeout=10 \
  --read-timeout="${AGENT_RUNNER_TIMEOUT:-900}" \
  "${URL}/run/${TARGET}")
wget_status=$?
set -e

if [ -z "$response" ]; then
  echo "Раннер недоступен по ${URL} (wget: ${wget_status})" >&2
  exit 1
fi

echo "$response"

# Ответ цели начинается со строки `exit: N`; иначе это отказ раннера (белый список, токен, путь)
case "$(printf '%s\n' "$response" | head -n 1)" in
  "exit: 0") exit 0 ;;
  *) exit 1 ;;
esac
