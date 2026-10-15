# allinone

Скрипт для настройки Remnawave-ноды: firewall, ICMP, nginx, SSL, Docker, remnanode, fail2ban, roscom.dat.
Собран из [remnawave-guide](https://github.com/herbalsomml/remnawave-guide) и части скриптов этого репозитория.

## Запуск с сервера одной командой

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/juhnsooqa/allinone/main/remnawave-node-setup.sh)"
```

Откроется интерактивное меню. Либо сразу конкретный шаг:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/juhnsooqa/allinone/main/remnawave-node-setup.sh)" -- full
```

Доступные аргументы: `full`, `fail2ban`, `roscom`, `psiphon`, `panel`, `accelerator`, `reverse-proxy`.

После первого запуска на сервере появляется команда `allinone` — открывает то же меню (каждый раз с последней версией скрипта с GitHub):

```bash
allinone            # меню
allinone psiphon    # сразу меню Psiphon
```

## Добавление ноды в панель (одна кнопка)

`full` в начале спрашивает URL панели и API-токен (панель → Настройки → API токены) и дальше делает всё сам:

1. берёт `SECRET_KEY` ноды из панели (`GET /api/keygen`) — вручную его вводить не нужно;
2. ставит ноду (firewall, nginx, SSL, docker, remnanode);
3. копирует профиль-образец: выбираете любой существующий профиль, скрипт меняет в нём только **тег инбаунда** (`pl2` → `finl1`, `ITALY_MILAN_TCP` → `finl1_TCP`), **SNI Reality** (если он есть) и адрес **psiphon-out** на локальный; dns, sockopt, маршруты и всё остальное копируются как есть;
4. создаёт ноду в панели с этим профилем и всеми его инбаундами.

Отдельно то же самое: пункт меню 7 или `allinone panel`. Токен и URL хранятся в `/root/.remnawave-panel.env` (chmod 600).

Скрипт спрашивает два имени: **тег инбаунда** в конфиге (по умолчанию первая часть домена: `node.finland.fl` → `finl1`) и **имя профиля и ноды** в панели (по умолчанию — тот же тег, можно задать человеческое, например `Finland 1`).

Если образец ссылается на то, чего на новой ноде ещё нет, скрипт это замечает и предлагает доставить:
`psiphon-out` в outbounds → установка Psiphon, `ext:roscom.dat:*` в маршрутах → настройка roscom.dat (без него xray просто не стартует).
Образцом может быть и локальный `panel-profile.reference.json`, но Reality-ключи в нём — заглушки, их придётся вписать в панели.
Хосты скрипт не создаёт — см. ниже.

## Настройка хостов в панели

По мотивам [remnawave-guide](https://github.com/herbalsomml/remnawave-guide#настройки-tcp-хоста) (там же скриншоты).
Скрипт печатает эти же настройки с вашим доменом и сохраняет их в `/opt/remnanode/panel-hosts.txt`.
Профиль с инбаундами — `/opt/remnanode/panel-profile.reference.json`.

В панели: **Хосты → Создать**, для каждого хоста выбрать свой инбаунд и ноду, `<ДОМЕН>` — домен ноды.

**Основные**

| Хост | Инбаунд | Адрес | Порт |
|---|---|---|---|
| TCP | `NODE_TCP` | `<ДОМЕН>` | `44443` |
| XHTTP | `NODE_XHTTP` | `<ДОМЕН>` | `443` |
| gRPC | `NODE_GRPC` | `<ДОМЕН>` | `44444` |

**Расширенные**

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

## Связка нод и балансер

Скрипт кладёт в `/opt/remnanode/` готовые куски для вставки в панель. Автоматизации пока нет — всё руками в UI.

**Связка нод** ([server-routing](https://docs.rw/learn/server-routing)): вход RU → выход за границей через Shadowsocks-мост.
Ноды уже заведены в панели, связываются их существующие профили.

Автоматически — пункт меню **8** или `allinone link`. Выбираете входную и выходную ноду из списка панели, дальше скрипт сам:

1. дописывает инбаунд-мост `BRIDGE_<нода>` (shadowsocks, порт 9999) в профиль **выходной** ноды;
2. включает этот инбаунд на самой ноде;
3. создаёт internal squad только с этим инбаундом;
4. создаёт сервисного юзера (без лимита, до 2099, в этом скваде) со сгенерированным SS-паролем;
5. дописывает в профиль **входной** ноды outbound `SS_OUTBOUND_TO_EXIT` с этим паролем и правило `inboundTag: [её инбаунды] → мост`.

Правило ставится **в конец** `routing.rules`: сначала отрабатывают уже существующие правила профиля (roscom-списки, `psiphon-out` и прочее), а в мост уходит только то, что они не поймали. Повторный запуск на той же паре не плодит дубли — инбаунд, outbound и правило заменяются по тегу.
Порт на выходной ноде скрипт откроет сам, если запущен на ней; иначе напомнит `ufw allow 9999/tcp`.

Руками то же самое — готовые куски для вставки:

| Файл | Куда дописать |
|---|---|
| `panel-bridge-inbound.reference.json` | в `inbounds` профиля **выходной** ноды: SS-инбаунд `BRIDGE_IN` на порту 9999 |
| `panel-entry-routing.reference.json` | в профиль **входной** ноды: `outbound` → в её `outbounds`, `rules` → в начало её `routing.rules` |

Порядок тот же, что у пункта 8, только руками: инбаунд-мост → включить его на ноде → squad → юзер `bridge_user_001` → его **SS Password** (Users → More Actions → Detailed Info) в `password` у входной ноды → там же адрес выходной ноды и свой тег инбаунда в последнем правиле.

**Балансер** ([xray-json-advanced](https://docs.rw/learn/xray-json-advanced)) — это клиентский конфиг, а не нода: `panel-balancer-template.reference.json` вставляется в **Advanced → Xray JSON template** виртуального хоста. Балансируемые хосты надо скрыть (Hidden) и подставить их UUID в `injectHosts.selector.values`. Блок `remnawave` панель вырежет сама, подставив вместо него outbound'ы `proxy`, `proxy-2`, … — под них уже настроены `balancers.selector` и `burstObservatory.subjectSelector`. Нужна панель 2.6.3+.

## Psiphon

Пункт меню 6 ставит Psiphon как SOCKS-выход для xray ([psiphon/psiphon_install.sh](psiphon/psiphon_install.sh), копия [Chara-Freedom/vps-psiphon](https://github.com/Chara-Freedom/vps-psiphon), MIT).
Ставить только на зарубежную ноду. После установки в `/opt/remnanode/panel-profile.reference.json` добавляется аутбаунд `psiphon-out` и правило для `geosite:openai`/`geosite:google-gemini` (только TCP).
Управление — через меню или напрямую `vps-psiphon {status|rotate|region CC|speed|logs|uninstall}`.
