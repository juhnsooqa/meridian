# Psiphon-выход

Пункт меню **4** или `meridian psiphon` ставит Psiphon как SOCKS-выход для xray: чистый IP для сервисов, которые режут IP сервера.

Установщик — [psiphon/psiphon_install.sh](https://github.com/juhnsooqa/meridian/blob/main/psiphon/psiphon_install.sh), копия [Chara-Freedom/vps-psiphon](https://github.com/Chara-Freedom/vps-psiphon) (MIT).

!!! warning
    Ставить только на зарубежную ноду.

После установки в `/opt/remnanode/panel-profile.reference.json` добавляется аутбаунд `psiphon-out` и правило для `geosite:openai` / `geosite:google-gemini` (только TCP).

## Управление

Через меню или напрямую:

```bash
vps-psiphon status        # состояние
vps-psiphon rotate        # сменить выходной IP
vps-psiphon region DE     # регион выхода
vps-psiphon speed         # тест скорости
vps-psiphon logs          # логи
vps-psiphon uninstall     # удалить
```

Параметры лежат в `/etc/default/vps-psiphon`, оттуда же берётся адрес `psiphon-out`.
