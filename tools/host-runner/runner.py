#!/usr/bin/env python3
"""Раннер целей сборки окружения на хосте.

Принимает по HTTP имя цели `make` из белого списка, выполняет её в корне репозитория
и возвращает вывод с кодом возврата. Ни shell, ни произвольные команды, ни доступ
к Docker-сокету из контейнера агента не задействованы: агент лишь просит выполнить
одну из заранее разрешённых целей.
"""

from __future__ import annotations

import hmac
import os
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import urlsplit

# Белый список: только эти цели могут быть запрошены. Список — подмножество целей Makefile
# репозитория, а не их зеркало: цель вне Makefile дала бы лишь ошибку make, но и не всякая
# цель Makefile сюда годится. Цель, ожидающая терминала, в список не попадает намеренно —
# раннер однопоточный, а такой процесс не завершился бы сам и удерживал бы раннер
# до AGENT_RUNNER_TIMEOUT, блокируя все последующие запросы. Расширять осознанно.
#
# Управления контейнером здесь нет: рабочая сессия агента живёт в эфемерном контейнере,
# запущенном пользователем на хосте, — целей up и down в Makefile больше нет, и перезапустить
# сессию из неё самой всё равно невозможно.
#
# Цели сборки образа здесь нет и быть не может: образ собирает пайплайн репозитория kit'а,
# а проект получает его из реестра — в Makefile такой цели нет.
ALLOWED_TARGETS = frozenset({"init", "openspec-init", "help"})

# Цели выполняются в корне репозитория: там лежит Makefile окружения
REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_WORKDIR = REPOSITORY_ROOT

BIND = os.environ.get("AGENT_RUNNER_BIND", "0.0.0.0")
PORT = int(os.environ.get("AGENT_RUNNER_PORT", "11900"))
TOKEN = os.environ.get("AGENT_RUNNER_TOKEN", "")
WORKDIR = Path(os.environ.get("AGENT_RUNNER_WORKDIR", str(DEFAULT_WORKDIR)))
TIMEOUT = int(os.environ.get("AGENT_RUNNER_TIMEOUT", "900"))


class RunnerHandler(BaseHTTPRequestHandler):
    """Обрабатывает запросы вида `GET /run/{target}` с токеном в заголовке."""

    server_version = "host-runner/1.4"

    def do_GET(self) -> None:  # noqa: N802 — имя задано BaseHTTPRequestHandler
        # Ответ обязателен при любом исходе: без него клиент виснет до своего таймаута
        try:
            self._dispatch()
        except Exception as error:  # noqa: BLE001 — раннер не должен падать молча
            self._reply(500, f"Внутренняя ошибка раннера: {error!r}\n")

    def _dispatch(self) -> None:
        parts = urlsplit(self.path)

        if parts.path == "/healthz":
            self._reply(200, "ok\n")
            return

        if not parts.path.startswith("/run/"):
            self._reply(404, "Доступен только путь /run/{цель} и /healthz\n")
            return

        # Сравнение в байтах: compare_digest на строках с не-ASCII бросает TypeError
        supplied = self.headers.get("X-Runner-Token", "").encode("utf-8", "surrogateescape")
        if not hmac.compare_digest(supplied, TOKEN.encode("utf-8")):
            self._reply(403, "Неверный токен\n")
            return

        target = parts.path[len("/run/") :].strip("/")
        if target not in ALLOWED_TARGETS:
            allowed = ", ".join(sorted(ALLOWED_TARGETS))
            self._reply(400, f"Цель {target!r} не в белом списке.\nРазрешены: {allowed}\n")
            return

        self._reply(200, self._run(target))

    def log_message(self, format: str, *args: object) -> None:
        """Каждый запрос виден в консоли раннера — что именно попросил агент."""
        sys.stderr.write(f"[host-runner] {self.address_string()} {format % args}\n")

    def _run(self, target: str) -> str:
        command = ["make", target]
        sys.stderr.write(f"[host-runner] выполняю: {' '.join(command)}\n")
        try:
            completed = subprocess.run(
                command,
                cwd=str(WORKDIR),
                capture_output=True,
                text=True,
                timeout=TIMEOUT,
                check=False,
            )
        except subprocess.TimeoutExpired:
            return f"exit: timeout\nЦель {target} не уложилась в {TIMEOUT} с\n"
        except OSError as error:
            return f"exit: error\nНе удалось запустить make: {error}\n"

        return (
            f"exit: {completed.returncode}\n"
            f"--- stdout ---\n{completed.stdout}"
            f"--- stderr ---\n{completed.stderr}"
        )

    def _reply(self, status: int, body: str) -> None:
        payload = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


def main() -> int:
    if not TOKEN:
        sys.stderr.write("Не задан AGENT_RUNNER_TOKEN — раннер без токена не запускается\n")
        return 1
    if not (WORKDIR / "Makefile").is_file():
        sys.stderr.write(f"В каталоге {WORKDIR} нет Makefile — проверьте AGENT_RUNNER_WORKDIR\n")
        return 1

    sys.stderr.write(
        f"[host-runner] каталог: {WORKDIR}\n"
        f"[host-runner] слушает: {BIND}:{PORT}\n"
        f"[host-runner] цели: {', '.join(sorted(ALLOWED_TARGETS))}\n"
    )
    # Однопоточный сервер: цели выполняются строго по одной, параллельных make не будет
    HTTPServer((BIND, PORT), RunnerHandler).serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
