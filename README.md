# Telegram Auto-Reply Bot

## 📝 Описание

Автоматический бот для Telegram, который отслеживает сообщения в указанных чатах и отвечает при обнаружении ключевых слов.

## ✨ Возможности

- 📨 Отслеживание нескольких чатов одновременно
- 🔑 Реакция на ключевые слова
- 🚫 Исключение нежелательных слов
- ⏱️ Настраиваемая задержка между ответами
- 🔔 Отправка уведомлений в канал
- 🔄 Автоматическое переподключение
- 📋 Логирование всех действий

## 🚀 Установка

### Быстрая установка

```bash
wget -O install.sh https://raw.githubusercontent.com/88Dand/InterceptorTGBot/main/install_TgBot.sh && chmod +x install.sh && ./install.sh

```
# Запуск сервиса
sudo systemctl start telegram_bot

# Остановка сервиса
sudo systemctl stop telegram_bot

# Перезапуск
sudo systemctl restart telegram_bot

# Автозагрузка
sudo systemctl enable telegram_bot

# Статус
sudo systemctl status telegram_bot

# Просмотр логов
journalctl -u telegram_bot -f

# Все логи
cat ~/telegram_bot/bot.log

# Только ошибки
grep ERROR ~/telegram_bot/bot.log

# Логи в реальном времени
tail -f ~/telegram_bot/bot.log

Удаление


sudo systemctl stop telegram_bot
sudo systemctl disable telegram_bot
sudo rm /etc/systemd/system/telegram_bot.service
sudo systemctl daemon-reload
rm -rf ~/telegram_bot
