# Связка нод и балансер

## Связка нод

По [server-routing](https://docs.rw/learn/server-routing): вход в РФ → выход за границей через Shadowsocks-мост.
Ноды уже заведены в панели, связываются их существующие профили.

Пункт меню **9** или `meridian link`. Выбираете входную и выходную ноду из списка панели, дальше скрипт сам:

1. дописывает инбаунд-мост `BRIDGE_<нода>` (shadowsocks, порт 9999) в профиль **выходной** ноды;
2. включает этот инбаунд на самой ноде;
3. создаёт internal squad только с этим инбаундом;
4. создаёт сервисного юзера (без лимита, до 2099, в этом скваде) со сгенерированным SS-паролем;
5. дописывает в профиль **входной** ноды outbound `SS_OUTBOUND_TO_EXIT` с этим паролем и правило `inboundTag: [её инбаунды] → мост`.

![Связка нод: meridian link](assets/link.svg)

Правило ставится **в конец** `routing.rules`: сначала отрабатывают существующие правила профиля (категории из `roscom.dat`, `psiphon-out` и прочее), а в мост уходит только то, что они не поймали. Повторный запуск на той же паре не плодит дубли — инбаунд, outbound и правило заменяются по тегу.

!!! note
    Порт на выходной ноде скрипт откроет сам, если запущен на ней. Иначе напомнит `ufw allow 9999`.

### Вручную

Скрипт кладёт в `/opt/remnanode/` готовые куски для вставки:

| Файл | Куда дописать |
|---|---|
| `panel-bridge-inbound.reference.json` | в `inbounds` профиля **выходной** ноды: SS-инбаунд `BRIDGE_IN` на порту 9999 |
| `panel-entry-routing.reference.json` | в профиль **входной** ноды: `outbound` → в её `outbounds`, `rules` → в начало её `routing.rules` |

Порядок тот же: инбаунд-мост → включить его на ноде → squad → юзер `bridge_user_001` → его **SS Password** (Users → More Actions → Detailed Info) в `password` у входной ноды → там же адрес выходной ноды и свой тег инбаунда в последнем правиле.

## Балансер

По [xray-json-advanced](https://docs.rw/learn/xray-json-advanced). Это клиентский конфиг, а не нода: `panel-balancer-template.reference.json` вставляется в **Advanced → Xray JSON template** виртуального хоста.

- Балансируемые хосты скрыть (Hidden) и подставить их UUID в `injectHosts.selector.values`.
- Блок `remnawave` панель вырежет сама, подставив вместо него outbound'ы `proxy`, `proxy-2`, … — под них уже настроены `balancers.selector` и `burstObservatory.subjectSelector`.
- Нужна панель 2.6.3+.
