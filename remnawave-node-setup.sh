#!/usr/bin/env bash
#
# Скрипт переименован в meridian.sh.
#
# Этот файл оставлен только ради совместимости: на уже установленных нодах команда
# /usr/local/bin/allinone качает старое имя, и без этой заглушки она бы просто перестала
# работать. Заглушка скачивает новый скрипт и передаёт ему те же аргументы.
#
# После того как ноды хотя бы раз обновятся (allinone перезапишет себя новой версией),
# этот файл можно удалить.

s="$(curl -fsSL https://raw.githubusercontent.com/juhnsooqa/meridian/main/meridian.sh)" \
    || { echo "meridian: не удалось скачать meridian.sh" >&2; exit 1; }
exec bash -c "$s" meridian "$@"
