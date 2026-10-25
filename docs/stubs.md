# Заглушки

Кто придёт на `https://домен` без нужного пути, увидит обычный сайт. Одна и та же страница на всех нодах — сама по себе примета, поэтому вариантов 20, лежат в [stubs/](https://github.com/juhnsooqa/meridian/tree/main/stubs):

| | | | |
|---|---|---|---|
| `nginx` — дефолт nginx | `apache` — It works! | `blank` — пустая | `404` — Not Found |
| `parked` — домен припаркован | `coming-soon` — тёмная | `maintenance` — техработы | `construction` — ретро |
| `status` — всё работает | `api` — описание API | `docs` — документация | `personal` — страница разработчика |
| `blog` — заметки | `portfolio` — тёмная сетка | `saas` — лендинг сервиса | `startup` — форма подписки |
| `agency` — дизайн-студия | `shop` — магазин | `cafe` — кафе с меню | `all-good` — как было раньше |

Выбор при установке, потом в любой момент — пункт меню **5** или:

```bash
meridian stub       # выбрать из списка
meridian stub 13    # сразу номером
meridian stub 0     # случайная
```

Все страницы автономные: inline-CSS, ни одного внешнего запроса, ни одного чужого бренда — иначе заглушка сама себя выдаёт.

<div class="grid" markdown>

<figure markdown>
![saas](assets/stubs/saas.jpg)
<figcaption>`saas` — лендинг сервиса</figcaption>
</figure>

<figure markdown>
![blog](assets/stubs/blog.jpg)
<figcaption>`blog` — личные заметки</figcaption>
</figure>

<figure markdown>
![portfolio](assets/stubs/portfolio.jpg)
<figcaption>`portfolio` — тёмная сетка работ</figcaption>
</figure>

<figure markdown>
![api](assets/stubs/api.jpg)
<figcaption>`api` — описание эндпоинтов</figcaption>
</figure>

</div>
