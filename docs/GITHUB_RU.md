# Публикация на GitHub

Репозиторий подготовлен для адреса `https://github.com/Subnakich/whisper-mac` и использует ветку `main`.

## Первая публикация

1. Создайте на GitHub пустой репозиторий `whisper-mac` без автоматически добавленных README, `.gitignore` и лицензии.
2. Авторизуйте GitHub CLI:

```bash
gh auth login -h github.com
```

3. Отправьте подготовленную историю:

```bash
cd /Users/subnak/dev/whisper-mac
git push -u origin main
```

После push workflow `.github/workflows/ci.yml` запустит тесты, соберёт ad-hoc `.pkg` и сохранит его как artifact сборки.

## Публичный релиз

Для файла, который можно безопасно передавать пользователям, сначала настройте Developer ID и нотариализацию по [инструкции](SIGNING_RU.md). Не храните сертификаты, `.p12`, app-specific password или нотариальные credentials в репозитории.

Лицензия намеренно не добавлена. Перед открытой публикацией выберите подходящую лицензию или оставьте репозиторий приватным.

