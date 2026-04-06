# mtproxy-zig installer

Автоустановщик [mtproto.zig](https://github.com/sleep3r/mtproto.zig) на чистый Ubuntu/Debian VPS.

## Установка

```bash
curl -sSfL https://raw.githubusercontent.com/arblark/mtproxy-zig/main/install-mtproxy.sh | sudo bash
```

### Опции (переменные окружения)

| Переменная | Описание | По умолчанию |
|---|---|---|
| `PROXY_PORT` | Порт прокси | `443` |
| `TLS_DOMAIN` | Домен для маскировки | `wb.ru` |
| `NUM_USERS` | Количество пользователей | `1` |
| `NFQWS_TTL` | TTL для TCP desync (nfqws) | `6` |
| `CF_TOKEN` + `CF_ZONE` | Cloudflare API для IPv6 ротации | — |
| `AWG_CONF` | Путь к AmneziaWG конфигу (для регионов с блокировкой) | — |

Примеры:

```bash
# Кастомный порт и домен
curl -sSfL ... | sudo PROXY_PORT=8443 TLS_DOMAIN=google.com bash

# С IPv6 ротацией через Cloudflare
curl -sSfL ... | sudo CF_TOKEN=xxx CF_ZONE=yyy bash

# С AmneziaWG туннелем (Telegram заблокирован на сервере)
curl -sSfL ... | sudo AWG_CONF=/root/awg.conf bash
```

## Управление

```
mtproxy status                — статус сервисов
mtproxy restart               — перезапуск
mtproxy logs                  — логи
mtproxy link                  — ссылки tg://proxy
mtproxy add-user <имя>        — добавить пользователя
mtproxy update [vX.Y.Z]       — обновить бинарник
mtproxy tunnel <awg.conf>     — настроить AWG туннель
mtproxy uninstall             — удаление
```

## Что устанавливается

- **mtproto.zig** — компиляция из исходников через Zig
- **Nginx** — Zero-RTT TLS маскировка (self-signed cert)
- **nfqws** (Zapret) — TCP desync для обхода DPI
- **TCPMSS=88** — фрагментация ClientHello
- **AmneziaWG** — туннель для заблокированных регионов (опционально)
- **IPv6 hopping** — ротация адресов через Cloudflare (опционально)
