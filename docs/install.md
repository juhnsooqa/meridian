# Установка

## Запуск одной командой

Под root на свежем сервере:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/juhnsooqa/meridian/main/meridian.sh)"
```

Откроется интерактивное меню. Либо сразу конкретный шаг:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/juhnsooqa/meridian/main/meridian.sh)" -- full
```

![Полная установка ноды](assets/install.svg)

## Что делает `full`

1. Спрашивает URL панели и API-токен — [ноду добавит в панель сам](panel.md).
2. Предлагает сменить пароль root и [отключить IPv6](ipv6.md).
3. Настраивает firewall: SSH-порт из sshd, порт ноды открыт только для IP панели, ping режется.
4. Ставит nginx, [заглушку](stubs.md) и сертификат Let's Encrypt.
5. Ставит Docker и remnanode.
6. Применяет [тюнинг сети](tune.md).
7. Предлагает настроить `roscom.dat`.

Каждый шаг опирается на предыдущий: на первой ошибке установка останавливается, а не идёт дальше вслепую.

## Аргументы

| Аргумент | Пункт меню | Что делает |
|---|---|---|
| `full` | 1 | полная установка ноды |
| `fail2ban` | 2 | бан перебора SSH |
| `roscom` | 3 | geosite от roscomvpn + автообновление |
| `psiphon` | 4 | [Psiphon-выход](psiphon.md) |
| `stub [N]` | 5 | [сменить заглушку](stubs.md) |
| `ipv6` | 6 | [отключить IPv6](ipv6.md) |
| `tune` | 7 | [тюнинг сети](tune.md) |
| `panel` | 8 | [добавить ноду в панель](panel.md) |
| `link` | 9 | [связать две ноды](bridge.md) |
| `accelerator` | 10 | сторонний node-accelerator |
| `reverse-proxy` | 11 | сторонний reverse-proxy-pro |

## Команда `meridian`

После первого запуска на сервере появляется команда `meridian`. Она каждый раз скачивает свежую версию скрипта с GitHub, поэтому обновлять ничего не нужно:

```bash
meridian            # меню
meridian tune       # сразу конкретный шаг
```

!!! tip "apt занят"
    На свежем VPS apt часто занят unattended-upgrades. Скрипт ждёт освобождения lock до 10 минут, а не падает.
