# Как устроена нода

## Как ходит трафик

![Как ходит трафик](assets/flow.svg)

Снаружи нода выглядит обычным сайтом: кто придёт на `https://домен` без нужного пути, увидит [страницу-заглушку](stubs.md).

## Что где лежит на сервере

| Путь | Что это |
|---|---|
| `/opt/remnanode/` | нода: `docker-compose.yml`, `.env` (chmod 600), geo-файлы, справочные JSON для панели |
| `/root/.remnanode-setup.env` | домен, email, `SECRET_KEY`, порт ноды (chmod 600) |
| `/root/.remnawave-panel.env` | URL панели и API-токен (chmod 600) |
| `/etc/nginx/conf.d/xray.conf` | 443 и 9443 с SSL, `/xhttppath/` в сокет xray |
| `/etc/letsencrypt/live/<домен>/` | сертификаты, обновляет `certbot.timer` |
| `/etc/sysctl.d/99-zz-meridian-net.conf` | [тюнинг сети](tune.md) |
| `/etc/default/vps-psiphon` | параметры Psiphon, оттуда берётся адрес `psiphon-out` |
| `/usr/local/bin/meridian` | команда-обёртка, тянет свежий скрипт с GitHub |
| `/var/log/roscom_update.log` | лог ночного обновления roscom.dat |
