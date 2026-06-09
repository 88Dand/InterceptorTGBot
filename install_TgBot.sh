#!/usr/bin/env bash
set -euo pipefail

APP_DIR="$HOME/telegram_bot"
BOT_FILE="$APP_DIR/bot.py"
CONFIG_FILE="$APP_DIR/config.json"
VENV_DIR="$APP_DIR/venv"
SERVICE_NAME="telegram-bot"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
SHORTCUT_FILE="$HOME/tg"
BIN_SHORTCUT="/usr/local/bin/tg"

pause() {
  echo
  read -rp "Нажмите Enter для возврата в меню..."
}

menu() {
  clear
  echo "Telegram Bot Manager"
  echo "===================="
  echo "1) Установить / переустановить"
  echo "2) Изменить настройки config.json"
  echo "3) Запустить сервис"
  echo "4) Остановить сервис"
  echo "5) Перезапустить сервис"
  echo "6) Статус сервиса"
  echo "7) Логи"
  echo "8) Диагностика"
  echo "9) Удалить бота и сервис"
  echo "10) Создать короткую команду tg"
  echo "11) Авторизация Telegram / ввод кода"
  echo "0) Выход"
  echo
  read -rp "Выберите пункт: " choice
}

service_status_short() {
  echo
  if systemctl is-active --quiet "$SERVICE_NAME"; then
    echo "[OK] Сервис запущен"
  else
    echo "[INFO] Сервис не запущен"
  fi

  if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
    echo "[OK] Автозапуск включён"
  else
    echo "[INFO] Автозапуск не включён"
  fi
}

start_service() {
  echo "[INFO] Запускаю сервис..."
  if sudo systemctl start "$SERVICE_NAME"; then
    echo "[OK] Команда запуска выполнена"
  else
    echo "[ERROR] Не удалось запустить сервис"
  fi

  service_status_short
  echo
  sudo systemctl status "$SERVICE_NAME" --no-pager -l || true
  pause
}

stop_service() {
  echo "[INFO] Останавливаю сервис..."
  if sudo systemctl stop "$SERVICE_NAME"; then
    echo "[OK] Команда остановки выполнена"
  else
    echo "[ERROR] Не удалось остановить сервис"
  fi

  service_status_short
  pause
}

restart_service() {
  echo "[INFO] Перезапускаю сервис..."
  if sudo systemctl restart "$SERVICE_NAME"; then
    echo "[OK] Команда перезапуска выполнена"
  else
    echo "[ERROR] Не удалось перезапустить сервис"
  fi

  service_status_short
  echo
  sudo systemctl status "$SERVICE_NAME" --no-pager -l || true
  pause
}

show_status() {
  sudo systemctl status "$SERVICE_NAME" --no-pager -l || true
  pause
}

ask_config() {
  mkdir -p "$APP_DIR"

  echo
  echo "Введите параметры Telegram API и бота."
  echo "API_ID — это число из https://my.telegram.org/apps, не username бота."
  echo

  while true; do
    read -rp "API_ID: " API_ID
    if [[ "$API_ID" =~ ^[0-9]+$ ]]; then
      break
    fi
    echo "Ошибка: API_ID должен быть числом, например 24929241"
  done

  read -rp "API_HASH: " API_HASH
  read -rp "PHONE, например +79000000000: " PHONE
  read -rp "CHAT_LINK, например https://t.me/besplatnomp: " CHAT_LINK
  read -rp "ALARM_CHANNEL_LINK: " ALARM_CHANNEL_LINK

  read -rp "MIN_RESPONSE_INTERVAL секунд [60]: " MIN_RESPONSE_INTERVAL
  MIN_RESPONSE_INTERVAL="${MIN_RESPONSE_INTERVAL:-60}"

  read -rp "LOG_LEVEL [WARNING] / DEBUG / INFO / ERROR: " LOG_LEVEL
  LOG_LEVEL="${LOG_LEVEL:-WARNING}"

  read -rp "REPLY_TEXT [бронь, пожалуйста]: " REPLY_TEXT
  REPLY_TEXT="${REPLY_TEXT:-бронь, пожалуйста}"

  echo
  echo "Ключевые слова через запятую:"
  read -rp "> " KEYWORDS_RAW

  echo
  echo "Слова-исключения через запятую:"
  read -rp "> " EXCLUSIONS_RAW

  API_ID="$API_ID" \
  API_HASH="$API_HASH" \
  PHONE="$PHONE" \
  CHAT_LINK="$CHAT_LINK" \
  ALARM_CHANNEL_LINK="$ALARM_CHANNEL_LINK" \
  MIN_RESPONSE_INTERVAL="$MIN_RESPONSE_INTERVAL" \
  LOG_LEVEL="$LOG_LEVEL" \
  REPLY_TEXT="$REPLY_TEXT" \
  KEYWORDS_RAW="$KEYWORDS_RAW" \
  EXCLUSIONS_RAW="$EXCLUSIONS_RAW" \
  CONFIG_FILE="$CONFIG_FILE" \
  python3 - <<'PY'
import json
import os

def split_csv(s):
    return [x.strip() for x in s.split(",") if x.strip()]

config = {
    "api_id": int(os.environ["API_ID"]),
    "api_hash": os.environ["API_HASH"],
    "phone": os.environ["PHONE"],
    "chat_link": os.environ["CHAT_LINK"],
    "alarm_channel_link": os.environ["ALARM_CHANNEL_LINK"],
    "keywords": split_csv(os.environ["KEYWORDS_RAW"]),
    "exclusions": split_csv(os.environ["EXCLUSIONS_RAW"]),
    "min_response_interval": int(os.environ["MIN_RESPONSE_INTERVAL"]),
    "log_level": os.environ["LOG_LEVEL"].upper(),
    "reply_text": os.environ["REPLY_TEXT"]
}

with open(os.environ["CONFIG_FILE"], "w", encoding="utf-8") as f:
    json.dump(config, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY

  chmod 600 "$CONFIG_FILE"
  echo "[OK] Конфиг сохранён: $CONFIG_FILE"
}

write_bot() {
  mkdir -p "$APP_DIR"

  cat > "$BOT_FILE" <<'PY'
from telethon import TelegramClient, events
from telethon.errors import ChatAdminRequiredError, UserBannedInChannelError, ChatWriteForbiddenError
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
    config.setdefault("log_level", "WARNING")

    return config


def setup_logging(config):
    log_level_name = str(config.get("log_level", "WARNING")).upper()
    log_level = getattr(logging, log_level_name, logging.WARNING)

    logging.basicConfig(
        level=log_level,
        format="%(asctime)s - %(levelname)s - %(message)s",
        handlers=[
            logging.FileHandler(LOG_PATH),
            logging.StreamHandler(sys.stdout)
        ],
        force=True
    )

    # По умолчанию скрываем шумные INFO-логи Telethon:
    # Got difference for account updates
    # Got difference for channel ... updates
    telethon_level = logging.WARNING

    if log_level <= logging.DEBUG:
        telethon_level = logging.INFO

    logging.getLogger("telethon").setLevel(telethon_level)

    return logging.getLogger(__name__)


async def safe_send_alarm(client, alarm_channel, chat, message_text, current_time, reason_text=None):
    try:
        alarm_msg = (
            f"Аларм! Сработало ключевое слово в чате {getattr(chat, 'title', chat.id)}\n"
            f"Сообщение: {message_text[:300]}{'...' if len(message_text) > 300 else ''}\n"
            f"Время: {current_time.strftime('%Y-%m-%d %H:%M:%S')}"
        )

        if reason_text:
            alarm_msg += f"\nОтвет в исходный чат не отправлен: {reason_text}"

        await client.send_message(alarm_channel, alarm_msg)
        logger.info("Отправлено аларм-сообщение")

    except Exception as e:
        logger.exception(f"Ошибка при отправке аларма: {e}")


async def run_bot():
    global last_response_time
    global logger

    config = load_config()
    logger = setup_logging(config)

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
        logger.warning("Подключение к Telegram...")
        await client.start(config["phone"])
        logger.warning("Успешная авторизация")

        me = await client.get_me()
        chat = await client.get_entity(config["chat_link"])
        alarm_channel = await client.get_entity(config["alarm_channel_link"])

        logger.warning(f"Подключено к чату: {getattr(chat, 'title', chat.id)}")
        logger.warning(f"Подключено к каналу: {getattr(alarm_channel, 'title', alarm_channel.id)}")

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

            if not has_keyword or has_exclusion:
                return

            last_response_time = current_time
            delay = random.uniform(3, 6)
            await asyncio.sleep(delay)

            reply_error = None

            try:
                await event.reply(config["reply_text"])
                logger.warning(f"Отправлен ответ на сообщение: {message_text[:80]}")

            except (ChatAdminRequiredError, UserBannedInChannelError, ChatWriteForbiddenError) as e:
                reply_error = "нет прав на отправку сообщения в исходный чат"
                logger.warning(f"Не удалось ответить в исходный чат: {e}")

            except Exception as e:
                reply_error = str(e)
                logger.exception(f"Ошибка при ответе в исходный чат: {e}")

            await safe_send_alarm(
                client=client,
                alarm_channel=alarm_channel,
                chat=chat,
                message_text=message_text,
                current_time=current_time,
                reason_text=reply_error
            )

        logger.warning("Автоответчик запущен. Ожидание сообщений...")
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
        logger.warning("Бот остановлен пользователем")
PY

  chmod +x "$BOT_FILE"
}

install_dependencies() {
  echo "[INFO] Установка зависимостей..."

  sudo apt update
  sudo apt install -y python3 python3-venv python3-pip

  python3 -m venv "$VENV_DIR"
  "$VENV_DIR/bin/pip" install --upgrade pip
  "$VENV_DIR/bin/pip" install telethon

  echo "[OK] Зависимости установлены"
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
  echo "[OK] systemd-сервис создан и добавлен в автозапуск"
}

install_or_reinstall() {
  echo "[INFO] Установка / переустановка..."

  sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true

install_dependencies

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "[INFO] config.json не найден — выполняется первичная настройка."
  ask_config
else
  echo "[OK] Найден существующий config.json — при переустановке он не будет перезаписан."
fi

write_bot
write_service

  echo
  echo "Первый запуск может запросить код Telegram."
  echo "Рекомендуется сначала запустить вручную:"
  echo
  echo "cd $APP_DIR && $VENV_DIR/bin/python $BOT_FILE"
  echo
read -rp "Выполнить авторизацию Telegram сейчас? [Y/n]: " do_login
do_login="${do_login:-Y}"

if [[ "$do_login" =~ ^[YyДд]$ ]]; then
  telegram_login
  return
fi

read -rp "Запустить сервис сейчас? [y/N]: " start_now

  if [[ "$start_now" =~ ^[YyДд]$ ]]; then
    sudo systemctl restart "$SERVICE_NAME"
    sudo systemctl status "$SERVICE_NAME" --no-pager -l || true
  fi

  pause
}
telegram_login() {
  if [[ ! -x "$VENV_DIR/bin/python" ]]; then
    echo "[ERROR] venv не найден. Сначала выполните установку."
    pause
    return
  fi

  if [[ ! -f "$BOT_FILE" ]]; then
    echo "[ERROR] bot.py не найден. Сначала выполните установку."
    pause
    return
  fi

  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "[ERROR] config.json не найден. Сначала создайте настройки."
    pause
    return
  fi

  echo "[INFO] Останавливаю сервис перед авторизацией..."
  sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true

  echo
  echo "Сейчас будет запущен интерактивный вход Telegram."
  echo "Если Telegram пришлёт код — введите его в консоль."
  echo "Если включён пароль 2FA — Telethon также запросит пароль."
  echo

  cd "$APP_DIR"
  "$VENV_DIR/bin/python" "$BOT_FILE"

  echo
  read -rp "Запустить сервис после авторизации? [Y/n]: " start_after_login
  start_after_login="${start_after_login:-Y}"

  if [[ "$start_after_login" =~ ^[YyДд]$ ]]; then
    sudo systemctl restart "$SERVICE_NAME"
    sudo systemctl status "$SERVICE_NAME" --no-pager -l || true
  fi

  pause
}
show_config_value() {
  local key="$1"

  CONFIG_FILE="$CONFIG_FILE" KEY="$key" python3 - <<'PY'
import json
import os

path = os.environ["CONFIG_FILE"]
key = os.environ["KEY"]

try:
    with open(path, "r", encoding="utf-8") as f:
        config = json.load(f)

    value = config.get(key)

    if isinstance(value, list):
        print(", ".join(value))
    else:
        print(value)

except Exception as e:
    print(f"Ошибка чтения config.json: {e}")
PY
}

set_config_value() {
  local key="$1"
  local value_type="$2"
  local value="$3"

  CONFIG_FILE="$CONFIG_FILE" KEY="$key" VALUE_TYPE="$value_type" VALUE="$value" python3 - <<'PY'
import json
import os

path = os.environ["CONFIG_FILE"]
key = os.environ["KEY"]
value = os.environ["VALUE"]
value_type = os.environ["VALUE_TYPE"]

with open(path, "r", encoding="utf-8") as f:
    config = json.load(f)

if value_type == "int":
    config[key] = int(value)
elif value_type == "list":
    config[key] = [x.strip() for x in value.split(",") if x.strip()]
else:
    config[key] = value

with open(path, "w", encoding="utf-8") as f:
    json.dump(config, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY

  chmod 600 "$CONFIG_FILE"
}

edit_one_config_param() {
  local key="$1"
  local value_type="$2"
  local title="$3"

  echo
  echo "Параметр: $title"
  echo "Текущее значение:"
  show_config_value "$key"
  echo

  read -rp "Новое значение: " new_value

  if [[ -z "$new_value" ]]; then
    echo "Пустое значение, изменение отменено."
    return
  fi

  if [[ "$value_type" == "int" && ! "$new_value" =~ ^[0-9]+$ ]]; then
    echo "Ошибка: значение должно быть числом."
    return
  fi

  set_config_value "$key" "$value_type" "$new_value"
  echo "[OK] Параметр изменён."
}

show_full_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "config.json не найден"
    return
  fi

  CONFIG_FILE="$CONFIG_FILE" python3 - <<'PY'
import json
import os

with open(os.environ["CONFIG_FILE"], "r", encoding="utf-8") as f:
    config = json.load(f)

print(json.dumps(config, ensure_ascii=False, indent=2))
PY
}

edit_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "config.json не найден. Создаю заново."
    ask_config
    pause
    return
  fi

  while true; do
    clear
    echo "Настройки config.json"
    echo "===================="
    echo "1) API_ID"
    echo "2) API_HASH"
    echo "3) PHONE"
    echo "4) CHAT_LINK"
    echo "5) ALARM_CHANNEL_LINK"
    echo "6) KEYWORDS"
    echo "7) EXCLUSIONS"
    echo "8) MIN_RESPONSE_INTERVAL"
    echo "9) REPLY_TEXT"
    echo "10) LOG_LEVEL"
    echo "11) Показать весь config.json"
    echo "12) Перезапустить сервис"
    echo "0) Назад"
    echo

    read -rp "Выберите параметр: " cfg_choice

    case "$cfg_choice" in
      1) edit_one_config_param "api_id" "int" "API_ID" ; pause ;;
      2) edit_one_config_param "api_hash" "str" "API_HASH" ; pause ;;
      3) edit_one_config_param "phone" "str" "PHONE" ; pause ;;
      4) edit_one_config_param "chat_link" "str" "CHAT_LINK" ; pause ;;
      5) edit_one_config_param "alarm_channel_link" "str" "ALARM_CHANNEL_LINK" ; pause ;;
      6) edit_one_config_param "keywords" "list" "KEYWORDS, через запятую" ; pause ;;
      7) edit_one_config_param "exclusions" "list" "EXCLUSIONS, через запятую" ; pause ;;
      8) edit_one_config_param "min_response_interval" "int" "MIN_RESPONSE_INTERVAL" ; pause ;;
      9) edit_one_config_param "reply_text" "str" "REPLY_TEXT" ; pause ;;
      10) edit_one_config_param "log_level" "str" "LOG_LEVEL: DEBUG / INFO / WARNING / ERROR" ; pause ;;
      11) show_full_config ; pause ;;
      12) restart_service ;;
      0) break ;;
      *) echo "Неверный пункт" ; pause ;;
    esac
  done
}

logs_menu() {
  while true; do
    clear
    echo "Логи"
    echo "===="
    echo "1) Показать последние 50 строк и вернуться в меню"
    echo "2) Показать последние 200 строк и вернуться в меню"
    echo "3) Смотреть логи в реальном времени"
    echo "0) Назад"
    echo

    read -rp "Выберите пункт: " log_choice

    case "$log_choice" in
      1)
        journalctl -u "$SERVICE_NAME" -n 50 --no-pager || true
        pause
        ;;
      2)
        journalctl -u "$SERVICE_NAME" -n 200 --no-pager || true
        pause
        ;;
      3)
        echo
        echo "Режим реального времени. Для выхода нажмите Ctrl+C."
        echo "После выхода запустите скрипт снова командой: sh tg или tg"
        echo
        journalctl -u "$SERVICE_NAME" -f --no-pager || true
        ;;
      0)
        break
        ;;
      *)
        echo "Неверный пункт"
        pause
        ;;
    esac
  done
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
    python3 - <<PY
import json
path = "$CONFIG_FILE"
try:
    with open(path, "r", encoding="utf-8") as f:
        json.load(f)
    print("JSON корректный")
except Exception as e:
    print(f"JSON повреждён: {e}")
PY
  else
    echo "config.json не найден"
  fi

  echo
  echo "6. systemd service:"
  systemctl status "$SERVICE_NAME" --no-pager -l || true

  echo
  echo "7. Последние логи:"
  journalctl -u "$SERVICE_NAME" -n 50 --no-pager || true

  pause
}

remove_bot() {
  echo "Удаление бота..."
  read -rp "Точно удалить сервис и каталог $APP_DIR? [y/N]: " confirm

  if [[ ! "$confirm" =~ ^[YyДд]$ ]]; then
    echo "Отменено."
    pause
    return
  fi

  sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  sudo systemctl disable "$SERVICE_NAME" 2>/dev/null || true
  sudo rm -f "$SERVICE_FILE"
  sudo systemctl daemon-reload
  rm -rf "$APP_DIR"

  read -rp "Удалить системные зависимости python3-venv python3-pip? [y/N]: " remove_deps

  if [[ "$remove_deps" =~ ^[YyДд]$ ]]; then
    sudo apt remove -y python3-venv python3-pip
    sudo apt autoremove -y
  fi

  echo "[OK] Удалено."
  pause
}

create_shortcut() {
  local current_script
  current_script="$(readlink -f "$0" 2>/dev/null || echo "$0")"

  cp "$current_script" "$SHORTCUT_FILE"
  chmod +x "$SHORTCUT_FILE"

  echo "[OK] Создан файл: $SHORTCUT_FILE"
  echo "Теперь можно запускать так:"
  echo
  echo "sh ~/tg"
  echo

  if [[ $EUID -eq 0 ]]; then
    cp "$current_script" "$BIN_SHORTCUT"
    chmod +x "$BIN_SHORTCUT"
    echo "[OK] Также создана команда: $BIN_SHORTCUT"
    echo "Можно запускать так:"
    echo
    echo "tg"
  else
    read -rp "Создать системную команду tg через sudo? [y/N]: " make_bin
    if [[ "$make_bin" =~ ^[YyДд]$ ]]; then
      sudo cp "$current_script" "$BIN_SHORTCUT"
      sudo chmod +x "$BIN_SHORTCUT"
      echo "[OK] Создана команда: $BIN_SHORTCUT"
      echo "Можно запускать так:"
      echo
      echo "tg"
    fi
  fi

  pause
}

while true; do
  menu

  case "$choice" in
    1) install_or_reinstall ;;
    2) edit_config ;;
    3) start_service ;;
    4) stop_service ;;
    5) restart_service ;;
    6) show_status ;;
    7) logs_menu ;;
    8) diagnostics ;;
    9) remove_bot ;;
    10) create_shortcut ;;
	11) telegram_login ;;
    0) exit 0 ;;
    *) echo "Неверный пункт" ; pause ;;
  esac
done
