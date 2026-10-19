# Что перенесено из Spicy Lyrics — 19 октября 2026

Референс: `C:\Users\vsevo\Desktop\ios\_ref\spicy-lyrics`, обновлён с `e1d49d8` (5 окт.) до `f4e471e` (19 окт., версия **6.4.50**).
Это 107 изменённых файлов, +11.9k / −2.9k строк. Почти всё новое касается веба: вёрстка Spotify, плеер в Popup Lyrics, NPV-карточка, ограничение FPS, circuit breaker.

## Сделано в этой сессии: новые титры (Refined Credits)

В 6.4 титры переделали, эксперимент `refinedCredits` теперь включён по умолчанию. Перенёс так:

- Убрана рамка, текст тихий и стоит ближе к последней строке. В первой строке `Written by` и авторы: подпись на 55% белого, имена на 70%.
- Вторая строка мельче (0.86×): `Provided by Apple Music via lrc.red`. Ссылка `via` кликабельная и подчёркнута.
- Для текстов от сообщества `Provided by` не показывается. Вместо него одна строка: `Community lyrics · Made by (аватар) @maker · Uploaded by (аватар) @uploader`. Каждый человек при переносе остаётся целиком на своей строке, тап открывает профиль.
- В синхронизированных текстах титры приглушены до 55%, пока не спета последняя строка, потом плавно проявляются.
- Ширина блока ограничена 46em, как в CSS.
- Новая настройка **«Титры за последним исполнителем»** (`creditsFollowLastLine`, по умолчанию выкл.). Если песня заканчивается дуэтной строкой справа, титры тоже встают справа.
- Настройка **«Новый вид титров»** (`refinedCredits`, по умолчанию вкл.) возвращает старый вид, если её выключить. Лежит в Настройки → Эксперименты; «Титры за последним исполнителем» — в Настройки → Текст → «Титры».
- Парсер понимает `source_via` (`lrc-red` → lrc.red со ссылкой `utm_source=spicylyrics`). В `ProviderMap` добавлен `uns` → Unison.
- В PiP тот же текст в новом виде, но один тон на строку и без затемнения до конца.

Файлы: `Rendering/LyricsView.swift` (`LyricsCreditsView`, `RefinedCreditsView`), `PiP/LyricsPictureInPicture.swift`, `Lyrics/LyricsModels.swift`, `Lyrics/LyricsParsers.swift`, `Support/AppSettings.swift`, `UI/SettingsView.swift`, `en.lproj/Localizable.strings`.

Проверка: рабочее дерево собрано в симуляторе, **BUILD SUCCEEDED**. Скрины лежат в `.claude/shots/credits/`: новый вид, затемнение до конца песни и старый вид. В симуляторе нет токена Spotify, поэтому тексты пришли из LRCLIB/локального TTML. Строку авторов, community-строку с аватарами и ссылку `via` вживую **не видел**. Это надо проверить на iPhone на песне с community-TTML.

## Сравнение настроек и функций

✅ есть у нас · 🟡 частично или иначе · ❌ нет · ➖ к iOS не относится

### Текст
| Расширение | У нас | Комментарий |
|---|---|---|
| Simple Lyrics Mode | ✅ | `simpleMode` |
| Refreshed Simple Lyrics Mode (эксп., выкл.) | ✅ | Эксперименты → «Обновлённый Simple Lyrics». Одна заливка по строке (fade 0.55em), всплывание слов без обгона, буквы слов из 2–7 букв раздуваются/расходятся/светятся, точки заполняются по одной и «дышат», шире расстояние (0.62em). Ширина слов считается приблизительно (0.55em на символ). Не перенесено: прокрутка «волной» (у нас своя) |
| Minimal Lyrics Mode | ✅ | Текст → Строки → «Скрывать спетые строки». Спетые гаснут (0.4 с), будущие 0.965× и тусклее, строка держится до следующей при паузе < 5 с, интерлюдии от 5 с, в конце песни все строки возвращаются. Работает везде, не только в полноэкранном |
| Keep Overlapping Lines (эксп.) | ✅ | Подпункт под Minimal, по умолчанию вкл. |
| Join Split Words | ✅ | Текст → Строки → «Склеивать слова из слогов». Те же правила: пауза ≤ 100 мс, темп частей не отличается больше чем втрое, без дефиса на конце, без пробелов, не для CJK/тайского и т. п. |
| Highlight on Hover | ➖ | |
| Duet Line Padding | 🟡 | Отступ дуэтов к своей стороне у нас есть всегда (`insets(opposite:)`, 15cqw), выключить нельзя |
| Credits Follow the Last Singer | ✅ | Текст → Титры |
| Refined Credits (эксп., вкл.) | ✅ | Эксперименты → «Новый вид титров» |
| Background Vocal Pop-Out (эксп., выкл.) | ✅ | Эксперименты → «Выезжающий бэк-вокал». Выезжает за 0.5 с, прячется за 0.3 с, после обеих строк держится, пока фокус на своей строке. При «Уменьшении движения» не включается. **Вживую не проверен** — в симуляторе не нашлось трека с бэк-вокалом |
| Use System Font | ✅ | Выбор шрифта шире, чем в расширении |
| Lyrics Loading Skeleton (эксп.) | ✅ | `LyricsSkeleton` в NowPlayingView |
| Romanization, interlude-точки, буквенная анимация, RTL | ✅ | Мелкие веб-фиксы (призрак точек, RTL-обрезка) у нас не воспроизводятся |

### Воспроизведение и прокрутка
| Расширение | У нас | Комментарий |
|---|---|---|
| Playback Offset | ✅ | `offset` / `timingOffsetMs` |
| Seek Fade-in Compensation | ✅ | Перенесено 19.10: `seekFadeCompensation`, по умолчанию вкл., тумблер «Перемотка чуть раньше строки» в разделе «Прокрутка» |
| Smooth Scrolling | 🟡 | Прокрутка всегда плавная, есть «Скорость прокрутки», выключателя нет |
| Early Scroll + Early Scroll Time | ✅ | Последний коммит `1d8a4f0` |
| «Allow scrolling up» | 🟡 | Ручной скролл и автовозврат у нас свои |

### Фон
| Расширение | У нас | Комментарий |
|---|---|---|
| Dynamic (Kawarp) | ✅ | |
| Artist Image (фото артиста из шапки) | 🟡 | Фон → «Фото артиста». Берётся фото артиста из Web API (`/tracks` → `/artists`), а не широкая шапка: шапку отдаёт только внутренний GraphQL Spotify. Только для источника Spotify. **Не проверено** с входом в Spotify |
| Cover Art (статичная обложка с блюром) | ✅ | Фон → «Обложка»: та же размытая обложка, но неподвижная |
| Color (Cover Colors) | 🟡 | Есть градиент из цветов обложки (`nebulaColors` и темы), но не в той же модели |
| None (Transparent) | ➖ | |
| Image Blur | ✅ | `backgroundBlur` |
| Refined Background (эксп.) | 🟡 | Кроссфейд при смене стиля и «глубокие» тона Cover Colors не сверялись |
| Canvas Stage / Canvas NPV Background (эксп., вкл.) | 🟡 | Фон → «Canvas». Запрос в `spclient.wg.spotify.com/canvaz-cache` (protobuf) с нашим OAuth-токеном, mp4 крутится без звука через AVPlayerLooper, фон темнее на 15 %. Если Spotify не примет токен или Canvas нет — остаётся живая обложка. **Не проверено**: примет ли spclient токен приложения-разработчика, узнаем только на iPhone (в журнале строка `canvas`). По умолчанию не выбран |
| Animated Background в NPV | ➖ | |

### Интерфейс
| Расширение | У нас | Комментарий |
|---|---|---|
| No Lyrics Notice | ✅ | `LyricsNotice.swift` + `LyricsNoticeView.swift`. Причины: not-found, local-track (с кнопкой «Свой текст (TTML)»), episode, ad, unknown-track, offline, service-unavailable, rate-limited, unauthorized, signed-out (наша), status-not-200, unknown-error. Кнопки «Повторить», «Скопировать детали», «Сообщить» (наша форма отчёта, не Discord). DJ и видео у нас не определяются |
| Volume Slider | ✅ | |
| Popup Lyrics / Popup Player Dock | 🟡 | Аналог — PiP. Док с плеером внизу в PiP ➖ |
| Scrub Preview (эксп.) | 🟡 | Не проверял, показывает ли наш таймлайн время под пальцем во время перетаскивания |
| New SliderBar Styling | 🟡 | Стили слайдеров свои |
| Lyrics Card (NPV), View Controls Position, Timeline Outside Media Box, Lock Media Box, Hide Spotify's Lyrics Button | ➖ | Устроены вокруг Spotify desktop |

### Производительность и сеть
| Расширение | У нас | Комментарий |
|---|---|---|
| Limit Frame Rate | ✅ | `lyricsFrameRate`, `pipFrameRate`, режим экономии |
| Виртуализация строк | ✅ | Своя отрисовка только видимых строк (`culling`) |
| Remote config (`remoteConfig.ts`) | ✅ | `Support/RemoteConfig.swift` + `GET /v1/config` в Worker. Значения: таймаут текстов, глубина и задержка заглядывания в очередь, сроки кэша (найдено / нет текста / LRCLIB), нижняя граница опроса Web API, выключатели авто-отчётов и Canvas. Меняются переменной `CLIENT_CONFIG` (JSON) в Cloudflare. **Worker не выкачен** — до `wrangler deploy` приложение работает на встроенных значениях |
| 15 с дедлайн на запрос, circuit breaker, повтор 401 на свежем токене, ограниченные источники токена | 🟡 | Своя логика есть, но с новой версией не сверял. Стоит хотя бы проверить повтор 401 и таймаут на каждый источник токена |
| Clear This Song's Cache / Clear Stored Lyrics / Reset This Song's Lyrics | 🟡 | Общая очистка кэша и «Повторить» есть, раздельных действий для текущей песни нет |
| Developer Mode | 🟡 | Есть FPS, sync log, индикатор синка |

## Что предлагаю доперенести, по порядку

1. **Проверить новые титры на iPhone** на песне с community-TTML (аватары, переносы, тап по профилю) и на песне с `source_via`.
2. ~~Seek Fade-in Compensation~~: сделано.
3. ~~Причины «нет текста»~~: сделано. На устройстве не проверены offline, rate-limited, local-track и настоящий not-found.
4. ~~Join Split Words, Minimal Lyrics Mode, Keep Overlapping Lines, Background Vocal Pop-Out, Refreshed Simple Lyrics, фоны «Обложка» / «Фото артиста» / «Canvas», remote config~~: сделано 19.10.
5. **Проверить на iPhone**: Pop-Out на песне с бэк-вокалом, «Фото артиста» и «Canvas» со входом в Spotify (если в журнале `canvas: HTTP 401/403` — spclient не берёт токен приложения, тогда Canvas можно получать только через наш Worker).
6. **Выкатить Worker** (`wrangler deploy` в `cloudflare/`), чтобы заработал `/v1/config`.
7. Не перенесено из Refreshed Simple Lyrics: прокрутка «волной» (каждая строка догоняет чуть позже предыдущей).

Мелочи: выключатель Smooth Scrolling и Duet Line Padding, раздельная очистка кэша для текущей песни.
