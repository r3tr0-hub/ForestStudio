# Как опубликовать Forest Studio на GitHub

Рекомендуемый репозиторий: `r3tr0-hub/ForestStudio`, public, описание:
`Forest Studio — WPF/MAXScript forest generator for 3ds Max 2024 and X-Ray SDK`.

1. Перейти на https://github.com/new и создать `ForestStudio` под `r3tr0-hub`.
   При создании **не** добавлять README/.gitignore/LICENSE — они уже подготовлены.
2. Загрузить **файлы содержимого этого каталога** в корень репозитория.
   Это можно сделать GitHub Web UI (Add file → Upload files) или git push.
3. Сделать первый коммит: `Initial public beta v0.4.6`.
4. В Releases выбрать `Draft a new release`, tag `v0.4.6-beta`, title
   `Forest Studio 2.0 — v0.4.6 Beta` и добавить готовый пользовательский ZIP
   `ForestStudio_v0.4.6-beta_COMPLETE_MIT.zip` как Release Asset.
5. В описание Release вставить `docs/GITHUB_RELEASE_NOTES_RU.md`.
6. Снять `Set as latest` для более старых релизов при необходимости и
   отметить этот выпуск как **Pre-release**. Опубликовать.
7. Сохранить ссылку вида `https://github.com/r3tr0-hub/ForestStudio/releases/tag/v0.4.6-beta`.
8. На AP-PRO разместить `docs/AP_PRO_TOPIC_RU.md`, ссылку на Release и
   скриншоты **реально работающей** WPF-сборки.

## Альтернативно через git

В папке с распакованными исходниками:

```powershell
git init
git branch -M main
git add .
git commit -m "Initial public beta v0.4.6"
git remote add origin https://github.com/r3tr0-hub/ForestStudio.git
git push -u origin main
```

Внимание: ZIP релиза не надо складывать внутрь репозитория — его прикрепляют
к Release, чтобы исходники не дублировались в истории git.
