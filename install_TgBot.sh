#!/usr/bin/env bash
set -euo pipefail

APP_DIR="$HOME/telegram_bot"
BOT_FILE="$APP_DIR/bot.py"
CONFIG_FILE="$APP_DIR/config.json"
VENV_DIR="$APP_DIR/venv"
SERVICE_NAME="telegram-bot"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

menu() {
  echo
  echo "Telegram Bot Manager"
  echo "1) Установить / переустановить"
  echo "2) Изменить настройки config.json"
  echo "3) Запустить сервис"
  echo "4) Остановить сервис"
  echo "5) Перезапустить сервис"
  echo "6) Статус сервиса"
  echo "7) Логи"
  echo "8) Диагностика"
  echo "9) Удалить бота и сервис"
  echo "0) Выход"
  echo
  read -rp "Выберите пункт: " choice
}

ask_config() {
  mkdir -p "$APP_DIR"

  echo
  echo "Введите параметры Telegram API и бота."
  read -rp "API_ID: " API_ID
  read -rp "API_HASH: " API_HASH
  read -rp "PHONE, например +79000000000: " PHONE
  read -rp "CHAT_LINK, например https://t.me/besplatnomp: " CHAT_LINK
  read -rp "ALARM_CHANNEL_LINK: " ALARM_CHANNEL_LINK
  read -rp "MIN_RESPONSE_INTERVAL секунд [60]: " MIN_RESPONSE_INTERVAL
  MIN_RESPONSE_INTERVAL="${MIN_RESPONSE_INTERVAL:-60}"

  echo
  echo "Ключевые слова через запятую:"
  read -rp "> " KEYWORDS_RAW

  echo
  echo "Слова-исключения через запятую:"
  read -rp "> " EXCLUSIONS_RAW

  python3 - <<PY
import json

def split_csv(s):
    return [x.strip() for x in s.split(",") if x.strip()]

config = {
    "api_id": int("$API_ID"),
    "api_hash": "$API_HASH",
    "phone": "$PHONE",
    "chat_link": "$CHAT_LINK",
    "alarm_channel_link": "$ALARM_CHANNEL_LINK",
    "keywords": split_csv("""$KEYWORDS_RAW"""),
    "exclusions": split_csv("""$EXCLUSIONS_RAW"""),
    "min_response_interval": int("$MIN_RESPONSE_INTERVAL"),
    "reply_text": "бронь, пожалуйста"
}

with open("$CONFIG_FILE", "w", encoding="utf-8") as f:
    json.dump(config, f, ensure_ascii=False, indent=2)
PY

  chmod 600 "$CONFIG_FILE"
  echo "Конфиг сохранён: $CONFIG_FILE"
}

write_bot() {
  mkdir -p "$APP_DIR"

  cat > "$BOT_FILE" <<'PY'
from telethon import TelegramClient, events
import asyncio
import random
from datetime import datetime
import logging
import json
import os
import sys

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(BASE_DIR, "config.json")
LOG_PATH = os.path.join(BASE_DIR, "bot.log")

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s",
    handlers=[
        logging.FileHandler(LOG_PATH),
        logging.StreamHandler(sys.stdout)
    ]
)

logger = logging.getLogger(__name__)
last_response_time = None


def load_config():
    if not os.path.exists(CONFIG_PATH):
        raise FileNotFoundError(f"Не найден config.json: {CONFIG_PATH}")

    with open(CONFIG_PATH, "r", encoding="utf-8") as f:
        config = json.load(f)

    required = [
        "api_id",
        "api_hash",
        "phone",
        "chat_link",
        "alarm_channel_link",
        "keywords",
        "exclusions",
        "min_response_interval"
    ]

    missing = [key for key in required if key not in config]
    if missing:
        raise ValueError(f"В config.json отсутствуют поля: {', '.join(missing)}")

    config["keywords"] = [x.lower() for x in config.get("keywords", [])]
    config["exclusions"] = [x.lower() for x in config.get("exclusions", [])]
    config.setdefault("reply_text", "бронь, пожалуйста")

    return config


async def run_bot():
    global last_response_time

    config = load_config()

    client = TelegramClient(
        os.path.join(BASE_DIR, "session_name"),
        config["api_id"],
        config["api_hash"],
        connection_retries=10,
        retry_delay=3,
        auto_reconnect=True,
        timeout=30
    )

    try:
        logger.info("Подключение к Telegram...")
        await client.start(config["phone"])
        logger.info("Успешная авторизация")

        me = await client.get_me()
        chat = await client.get_entity(config["chat_link"])
        alarm_channel = await client.get_entity(config["alarm_channel_link"])

        logger.info(f"Подключено к чату: {getattr(chat, 'title', chat.id)}")
        logger.info(f"Подключено к каналу: {getattr(alarm_channel, 'title', alarm_channel.id)}")

        @client.on(events.NewMessage(chats=chat))
        async def message_handler(event):
            global last_response_time

            if event.sender_id == me.id:
                return

            current_time = datetime.now()

            if last_response_time:
                elapsed = (current_time - last_response_time).total_seconds()
                if elapsed < config["min_response_interval"]:
                    logger.info(f"Пропуск: интервал менее {config['min_response_interval']} сек")
                    return

            message_text = (event.raw_text or "").lower()

            has_keyword = any(k in message_text for k in config["keywords"])
            has_exclusion = any(e in message_text for e in config["exclusions"])

            if has_keyword and not has_exclusion:
                last_response_time = current_time
                delay = random.uniform(3, 6)
                await asyncio.sleep(delay)

                try:
                    await event.reply(config["reply_text"])
                    logger.info(f"Отправлен ответ на сообщение: {message_text[:80]}")

                    alarm_msg = (
                        f"Аларм! Сработало ключевое слово в чате {getattr(chat, 'title', chat.id)}\n"
                        f"Сообщение: {message_text[:300]}{'...' if len(message_text) > 300 else ''}\n"
                        f"Время: {current_time.strftime('%Y-%m-%d %H:%M:%S')}"
                    )

                    await client.send_message(alarm_channel, alarm_msg)
                    logger.info("Отправлено аларм-сообщение")

                except Exception as e:
                    logger.exception(f"Ошибка при отправке: {e}")

        logger.info("Автоответчик запущен. Ожидание сообщений...")
        await client.run_until_disconnected()

    except Exception as e:
        logger.exception(f"Критическая ошибка: {e}")
        raise
    finally:
        await client.disconnect()


if __name__ == "__main__":
    try:
        asyncio.run(run_bot())
    except KeyboardInterrupt:
        logger.info("Бот остановлен пользователем")
PY

  chmod +x "$BOT_FILE"
}

install_dependencies() {
  sudo apt update
  sudo apt install -y python3 python3-venv python3-pip

  python3 -m venv "$VENV_DIR"
  "$VENV_DIR/bin/pip" install --upgrade pip
  "$VENV_DIR/bin/pip" install telethon
}

write_service() {
  sudo tee "$SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=Telegram Auto Reply Bot
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$APP_DIR
ExecStart=$VENV_DIR/bin/python $BOT_FILE
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

  sudo systemctl daemon-reload
  sudo systemctl enable "$SERVICE_NAME"
}

install_or_reinstall() {
  echo "Установка / переустановка..."

  sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true

  install_dependencies
  ask_config
  write_bot
  write_service

  echo
  echo "Первый запуск может запросить код Telegram."
  echo "Рекомендуется сначала запустить вручную:"
  echo "cd $APP_DIR && $VENV_DIR/bin/python $BOT_FILE"
  echo
  read -rp "Запустить сервис сейчас? [y/N]: " start_now

  if [[ "$start_now" =~ ^[YyДд]$ ]]; then
    sudo systemctl restart "$SERVICE_NAME"
    sudo systemctl status "$SERVICE_NAME" --no-pager
  fi
}

edit_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "config.json не найден. Создаю заново."
    ask_config
  else
    ${EDITOR:-nano} "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    echo "Конфиг изменён."
    read -rp "Перезапустить сервис? [y/N]: " restart_now
    if [[ "$restart_now" =~ ^[YyДд]$ ]]; then
      sudo systemctl restart "$SERVICE_NAME"
    fi
  fi
}

diagnostics() {
  echo
  echo "=== Диагностика ==="

  echo
  echo "1. Каталог:"
  ls -la "$APP_DIR" 2>/dev/null || echo "Каталог не найден: $APP_DIR"

  echo
  echo "2. Python:"
  python3 --version || true

  echo
  echo "3. Venv:"
  if [[ -x "$VENV_DIR/bin/python" ]]; then
    "$VENV_DIR/bin/python" --version
  else
    echo "venv не найден"
  fi

  echo
  echo "4. Telethon:"
  if [[ -x "$VENV_DIR/bin/python" ]]; then
    "$VENV_DIR/bin/python" - <<'PY' || true
try:
    import telethon
    print("Telethon OK:", telethon.__version__)
except Exception as e:
    print("Telethon ERROR:", e)
PY
  fi

  echo
  echo "5. config.json:"
  if [[ -f "$CONFIG_FILE" ]]; then
    python3 -m json.tool "$CONFIG_FILE" >/dev/null && echo "JSON корректный" || echo "JSON повреждён"
  else
    echo "config.json не найден"
  fi

  echo
  echo "6. systemd service:"
  systemctl status "$SERVICE_NAME" --no-pager || true

  echo
  echo "7. Последние логи:"
  journalctl -u "$SERVICE_NAME" -n 50 --no-pager || true
}

remove_bot() {
  echo "Удаление бота..."
  read -rp "Точно удалить сервис и каталог $APP_DIR? [y/N]: " confirm

  if [[ ! "$confirm" =~ ^[YyДд]$ ]]; then
    echo "Отменено."
    return
  fi

  sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  sudo systemctl disable "$SERVICE_NAME" 2>/dev/null || true
  sudo rm -f "$SERVICE_FILE"
  sudo systemctl daemon-reload
  rm -rf "$APP_DIR"

  echo "Удалено."
}

logs() {
  journalctl -u "$SERVICE_NAME" -f --no-pager
}

if [[ ! -f "$SERVICE_FILE" && ! -d "$APP_DIR" ]]; then
  install_or_reinstall
  exit 0
fi

while true; do
  menu
  case "$choice" in
    1) install_or_reinstall ;;
    2) edit_config ;;
    3) sudo systemctl start "$SERVICE_NAME" ;;
    4) sudo systemctl stop "$SERVICE_NAME" ;;
    5) sudo systemctl restart "$SERVICE_NAME" ;;
    6) sudo systemctl status "$SERVICE_NAME" --no-pager ;;
    7) logs ;;
    8) diagnostics ;;
    9) remove_bot ;;
    0) exit 0 ;;
    *) echo "Неверный пункт" ;;
  esac
done
