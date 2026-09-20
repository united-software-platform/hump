#!/bin/sh
# Проверка шлюза LiteLLM: живость, готовность, подключение хранилища состояния, состояние
# настроенных маршрутов и сквозной запрос по каждому из них.
#
# Коды возврата: 0 — хранилище подключено и все настроенные маршруты ответили; 1 — хранилище
# не подключено или хотя бы один маршрут не ответил; 2 — ошибка вызова или окружения
# (нет HTTP-клиента, не задан ключ доступа).
#
# Запускается одинаково с хоста и из контейнера агента: адрес шлюза берётся из переменной
# окружения, умолчание указывает на хост со стороны контейнера.
set -u

GATEWAY_URL="${HUMP_GATEWAY_URL:-http://host.docker.internal:${LITELLM_PORT:-4000}}"
MASTER_KEY="${LITELLM_MASTER_KEY:-}"
LOCAL_MODEL="${HUMP_LOCAL_MODEL:-hump-local}"
CLOUD_MODEL="${HUMP_CLOUD_MODEL:-hump-cloud}"
TIMEOUT="${HUMP_HTTP_TIMEOUT:-30}"

if command -v curl >/dev/null 2>&1; then
	http_tool=curl
elif command -v wget >/dev/null 2>&1; then
	http_tool=wget
else
	echo "Ошибка: не найден ни curl, ни wget — проверку выполнить нечем" >&2
	exit 2
fi

body_file="$(mktemp)"
trap 'rm -f "$body_file"' EXIT INT TERM

# Выполняет запрос, кладёт тело ответа в $body_file. Возврат 0 — ответ 2xx, иначе ненулевой.
# Аргументы: URL, значение заголовка Authorization ("" — без него), тело POST ("" — GET).
#
# Аргументы клиента собираются позиционными параметрами, а не подстановкой в строку: строка
# распалась бы по пробелам внутри значения заголовка.
request() {
	req_url="$1"
	req_auth="$2"
	req_data="$3"

	if [ "$http_tool" = curl ]; then
		set -- -sS -m "$TIMEOUT" -o "$body_file" -w '%{http_code}'
		if [ -n "$req_auth" ]; then
			set -- "$@" -H "Authorization: $req_auth"
		fi
		if [ -n "$req_data" ]; then
			set -- "$@" -H "Content-Type: application/json" -d "$req_data"
		fi
		req_code="$(curl "$@" "$req_url" 2>>"$body_file")" || return 1
		case "$req_code" in
		2*) return 0 ;;
		*) return 1 ;;
		esac
	fi

	# wget: код возврата 0 соответствует ответу 2xx, --content-on-error сохраняет тело ошибки
	set -- -q -O "$body_file" --timeout="$TIMEOUT" --tries=1 --content-on-error
	if [ -n "$req_auth" ]; then
		set -- "$@" --header="Authorization: $req_auth"
	fi
	if [ -n "$req_data" ]; then
		set -- "$@" --header="Content-Type: application/json" --post-data="$req_data"
	fi
	wget "$@" "$req_url"
	req_status=$?
	# Ответ 401 wget обрабатывает как отказ авторизации (код 6) и тело не сохраняет даже
	# с --content-on-error: подставляем объяснение сами, иначе отказ выглядит беспричинным
	if [ "$req_status" -eq 6 ]; then
		echo '{"error": "HTTP 401 - шлюз отклонил ключ доступа (LITELLM_MASTER_KEY)"}' > "$body_file"
	fi
	return "$req_status"
}

# Печатает тело ответа с отступом: причина отказа должна быть видна из вывода проверки
print_body() {
	if [ -s "$body_file" ]; then
		sed 's/^/      /' "$body_file"
	fi
}

failed=0

echo "Шлюз: $GATEWAY_URL"
echo ""

echo "1. Живость (/health/liveliness)"
if request "$GATEWAY_URL/health/liveliness" "" ""; then
	echo "   OK: процесс отвечает"
else
	echo "   ОШИБКА: шлюз не отвечает — проверьте, что сервис запущен:"
	echo "   docker compose -f docker-compose.hump.yml up -d"
	print_body
	exit 1
fi

echo "2. Готовность (/health/readiness)"
if request "$GATEWAY_URL/health/readiness" "" ""; then
	echo "   OK: шлюз готов принимать трафик"
	# Состояние хранилища берётся из того же ответа: поле db различает «база подключена»
	# и «шлюз работает без неё». Без базы шлюз обслуживает запросы, но панель не пускает
	# ко входу, а ключи систем-потребителей выдавать негде — для окружения с базой это отказ.
	#
	# Сравнение точное: значение «Not connected» содержит слово connected как часть строки,
	# и поиск подстроки принял бы отказ за успех.
	if grep -qE '"db"[[:space:]]*:[[:space:]]*"connected"' "$body_file"; then
		echo "   OK: хранилище состояния подключено"
	else
		echo "   ОШИБКА: хранилище состояния не подключено — панель не пустит ко входу"
		echo "   проверьте сервис postgres и переменную DATABASE_URL в .env:"
		echo "   docker compose -f docker-compose.hump.yml ps postgres"
		print_body
		failed=1
	fi
else
	echo "   ОШИБКА: шлюз запущен, но не готов"
	print_body
	failed=1
fi

if [ -z "$MASTER_KEY" ]; then
	echo ""
	echo "Ошибка: не задан LITELLM_MASTER_KEY — проверить маршруты нечем." >&2
	echo "Возьмите значение из .env: export LITELLM_MASTER_KEY=sk-..." >&2
	exit 2
fi

echo "3. Состояние маршрутов (/health)"
if request "$GATEWAY_URL/health" "Bearer $MASTER_KEY" ""; then
	if grep -qE '"unhealthy_count"[[:space:]]*:[[:space:]]*0|"unhealthy_endpoints"[[:space:]]*:[[:space:]]*\[[[:space:]]*\]' "$body_file"; then
		echo "   OK: нездоровых маршрутов нет"
	else
		echo "   ОШИБКА: есть нездоровые маршруты"
		print_body
		failed=1
	fi
else
	echo "   ОШИБКА: запрос состояния маршрутов не прошёл"
	print_body
	failed=1
fi

# Сквозная проверка маршрута: реальный запрос на чат-дополнение через публичное имя модели
check_route() {
	route_model="$1"
	route_payload="{\"model\":\"$route_model\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":16}"
	echo "   маршрут $route_model"
	if request "$GATEWAY_URL/v1/chat/completions" "Bearer $MASTER_KEY" "$route_payload"; then
		if grep -q '"content"' "$body_file"; then
			echo "      OK: получен ответ модели"
		else
			echo "      ОШИБКА: ответ без содержимого"
			print_body
			failed=1
		fi
	else
		echo "      ОШИБКА: маршрут не ответил"
		print_body
		failed=1
	fi
}

echo "4. Сквозной запрос по маршрутам (/v1/chat/completions)"
check_route "$LOCAL_MODEL"
check_route "$CLOUD_MODEL"

echo ""
if [ "$failed" -eq 0 ]; then
	echo "Проверка пройдена: все настроенные маршруты отвечают"
else
	echo "Проверка не пройдена: см. ошибки выше"
fi
exit "$failed"
