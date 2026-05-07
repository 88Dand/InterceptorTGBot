#!/bin/bash

# Telegram Bot Auto-Reply Installer for Ubuntu
# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Telegram Bot Auto-Reply Installer${NC}"
echo -e "${BLUE}========================================${NC}"

# Проверка прав
#if [ "$EUID" -eq 0 ]; then 
#   echo -e "${RED}Пожалуйста, не запускайте скрипт от root${NC}"
#   exit 1
#fi

# Обновление системы
echo -e "${YELLOW}[1/8] Обновление системы...${NC}"
sudo apt update && sudo apt upgrade -y

# Установка зависимостей
echo -e "${YELLOW}[2/8] Установка зависимостей...${NC}"
sudo apt install -y python3 python3-pip python3-venv git curl wget nano htop

# Создание директории проекта
echo -e "${YELLOW}[3/8] Создание директории проекта...${NC}"
mkdir -p ~/telegram_bot
cd ~/telegram_bot

# Создание виртуального окружения
echo -e "${YELLOW}[4/8] Создание виртуального окружения...${NC}"
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install telethon

# Создание файла с кодом бота
echo -e "${YELLOW}[5/8] Создание файла бота...${NC}"
cat > bot.py << 'EOF'
from telethon import TelegramClient, events
from telethon.network.connection.tcpfull import ConnectionTcpFull
import asyncio
import random
import sys
from datetime import datetime, timedelta
import logging
import json
import os

# Настройка логирования
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('bot.log'),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger(__name__)

# Загрузка конфигурации
config_file = 'config.json'
if os.path.exists(config_file):
    with open(config_file, 'r') as f:
        config = json.load(f)
else:
    logger.error(f"Файл конфигурации {config_file} не найден!")
    logger.info("Скопируйте config.example.json в config.json и заполните данные")
    sys.exit(1)

# Конфигурация из файла
api_id = config['api_id']
api_hash = config['api_hash']
phone = config['phone']
chat_links = config['chat_links']
alarm_channel_link = config['alarm_channel_link']
KEYWORDS = config['keywords']
EXCLUSIONS = config['exclusions']
MIN_RESPONSE_INTERVAL = config['min_response_interval']

last_response_time = None

async def run_bot():
    global last_response_time
    
    while True:
        try:
            client = TelegramClient(
                'session_name', 
                api_id, 
                api_hash,
                connection=ConnectionTcpFull,
                connection_retries=10,
                retry_delay=1,
                auto_reconnect=True,
                timeout=15,
                flood_sleep_threshold=0,
                catch_up=True
            )
            
            logger.info("Подключение к Telegram...")
            await client.start(phone)
            logger.info("Успешная авторизация")
            
            await client.get_me()
            
            async def keep_alive():
                while True:
                    await asyncio.sleep(10)
                    try:
                        await client.get_me()
                        logger.debug("Keep-alive ping")
                    except Exception as e:
                        logger.warning(f"Keep-alive failed: {e}")
            
            asyncio.create_task(keep_alive())

            chats = []
            for link in chat_links:
                try:
                    chat = await client.get_entity(link)
                    chats.append(chat)
                    logger.info(f"Успешно подключено к чату: {chat.title}")
                except Exception as e:
                    logger.error(f"Ошибка подключения к чату {link}: {e}")
            
            if not chats:
                logger.error("Не удалось подключиться ни к одному чату")
                await client.disconnect()
                await asyncio.sleep(5)
                continue
            
            alarm_channel = await client.get_entity(alarm_channel_link)
            logger.info(f"Успешно подключено к каналу: {alarm_channel.title}")

            @client.on(events.NewMessage(chats=chats))
            async def message_handler(event):
                global last_response_time
                
                chat_name = event.chat.title if hasattr(event.chat, 'title') else "Unknown"
                
                if event.sender_id == (await client.get_me()).id:
                    return
                
                current_time = datetime.now()
                if last_response_time and (current_time - last_response_time).total_seconds() < MIN_RESPONSE_INTERVAL:
                    return
                
                message_text = event.raw_text.lower()
                if (any(keyword in message_text for keyword in KEYWORDS) and 
                    not any(exclusion in message_text for exclusion in EXCLUSIONS)):
                    
                    last_response_time = current_time
                    delay = random.uniform(2, 3)
                    await asyncio.sleep(delay)
                    
                    try:
                        await event.reply("бронь, пожалуйста")
                        logger.info(f"✅ Ответ в {chat_name}: {message_text[:30]}...")
                        
                        alarm_msg = f"Аларм! Чат: {chat_name}\nСообщение: {message_text[:100]}\nВремя: {current_time.strftime('%Y-%m-%d %H:%M:%S')}"
                        await client.send_message(alarm_channel, alarm_msg)
                        
                    except Exception as e:
                        logger.error(f"Ошибка при отправке: {e}")

            logger.info(f"✅ Бот запущен. Отслеживается {len(chats)} чатов")
            await client.run_until_disconnected()
            
        except Exception as e:
            logger.error(f"Критическая ошибка: {e}")
            logger.info("Переподключение через 5 секунд...")
            await asyncio.sleep(5)
        finally:
            try:
                await client.disconnect()
            except:
                pass

if __name__ == '__main__':
    try:
        asyncio.run(run_bot())
    except KeyboardInterrupt:
        logger.info("Бот остановлен пользователем")
    except Exception as e:
        logger.error(f"Ошибка при запуске: {e}")
EOF

# Создание файла конфигурации
echo -e "${YELLOW}[6/8] Создание файла конфигурации...${NC}"
cat > config.example.json << 'EOF'
{
  "api_id": 12345678,
  "api_hash": "your_api_hash_here",
  "phone": "+71234567890",
  "chat_links": [
    "https://t.me/chat1",
    "https://t.me/chat2"
  ],
  "alarm_channel_link": "https://t.me/alarm_channel",
  "keywords": [
    "ключевое слово 1",
    "ключевое слово 2"
  ],
  "exclusions": [
    "слово исключение 1"
  ],
  "min_response_interval": 120
}
EOF

# Создание systemd сервиса
echo -e "${YELLOW}[7/8] Создание systemd сервиса...${NC}"
cat > /tmp/telegram_bot.service << EOF
[Unit]
Description=Telegram Auto-Reply Bot
After=network.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$HOME/telegram_bot
ExecStart=$HOME/telegram_bot/venv/bin/python3 $HOME/telegram_bot/bot.py
Restart=always
RestartSec=10
Environment="PYTHONUNBUFFERED=1"

[Install]
WantedBy=multi-user.target
EOF

sudo mv /tmp/telegram_bot.service /etc/systemd/system/telegram_bot.service
sudo systemctl daemon-reload

# Настройка прав доступа
echo -e "${YELLOW}[8/8] Настройка прав доступа...${NC}"
chmod +x ~/telegram_bot/bot.py
chmod 600 ~/telegram_bot/config.json 2>/dev/null

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Установка завершена!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}Дальнейшие действия:${NC}"
echo -e "1. Перейдите в директорию: ${BLUE}cd ~/telegram_bot${NC}"
echo -e "2. Скопируйте и настройте конфиг: ${BLUE}cp config.example.json config.json${NC}"
echo -e "3. Отредактируйте config.json: ${BLUE}nano config.json${NC}"
echo -e "4. Запустите бота для первой авторизации: ${BLUE}source venv/bin/activate && python3 bot.py${NC}"
echo -e "5. Введите код подтверждения из Telegram"
echo -e "6. Остановите бота (Ctrl+C) и запустите сервис: ${BLUE}sudo systemctl start telegram_bot${NC}"
echo -e "7. Добавьте в автозагрузку: ${BLUE}sudo systemctl enable telegram_bot${NC}"
echo -e "8. Проверьте статус: ${BLUE}sudo systemctl status telegram_bot${NC}"
echo -e "9. Смотрите логи: ${BLUE}journalctl -u telegram_bot -f${NC}"
echo ""
echo -e "${YELLOW}Для получения API ID и Hash:${NC}"
echo -e "Перейдите на ${BLUE}https://my.telegram.org/apps${NC}"
