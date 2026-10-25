# Хосты в панели

По мотивам [remnawave-guide](https://github.com/herbalsomml/remnawave-guide#настройки-tcp-хоста) (там же скриншоты).
Скрипт печатает эти же настройки с вашим доменом и сохраняет их в `/opt/remnanode/panel-hosts.txt`.
Профиль с инбаундами — `/opt/remnanode/panel-profile.reference.json`.

В панели: **Хосты → Создать**, для каждого хоста выбрать свой инбаунд и ноду. `<ДОМЕН>` — домен ноды.

## Основные

| Хост | Инбаунд | Адрес | Порт |
|---|---|---|---|
| TCP | `NODE_TCP` | `<ДОМЕН>` | `44443` |
| XHTTP | `NODE_XHTTP` | `<ДОМЕН>` | `443` |
| gRPC | `NODE_GRPC` | `<ДОМЕН>` | `44444` |

## Расширенные

| Поле | TCP и gRPC | XHTTP |
|---|---|---|
| SNI | `<ДОМЕН>` | `<ДОМЕН>` |
| Переопределить SNI из адреса | вкл | **выкл** |
| Хост | — | `<ДОМЕН>` |
| Путь | — | `/xhttppath/` (со слешем на конце, как на ноде) |
| Security Layer | по умолчанию | TLS |
| ALPN | — | `h2,http/1.1` |
| Отпечаток | — | `chrome` |

Для XHTTP ещё: **Xray Json & Raw → xHTTP** — вставить `/opt/remnanode/panel-xhttp-host-extra.reference.json`.
