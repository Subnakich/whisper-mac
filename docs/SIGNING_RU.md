# Подпись и нотариализация Whisper Mac

Для установки на свои компьютеры достаточно текущей ad-hoc сборки. Чтобы коллеги могли устанавливать приложение без обхода Gatekeeper, нужны членство в Apple Developer Program, подпись Developer ID и нотариализация Apple.

## 1. Получить сертификаты

В разделе **Certificates, Identifiers & Profiles** аккаунта Apple Developer создайте и установите в Keychain два сертификата:

- `Developer ID Application` — подписывает `Whisper Mac.app`;
- `Developer ID Installer` — подписывает установочный `.pkg`.

Проверьте, что сертификат приложения доступен вместе с закрытым ключом:

```bash
security find-identity -v -p codesigning
```

Имена обычно выглядят так:

```text
Developer ID Application: Имя или компания (TEAMID)
Developer ID Installer: Имя или компания (TEAMID)
```

## 2. Один раз сохранить данные для нотариализации

Создайте отдельный app-specific password в настройках Apple Account. Затем выполните:

```bash
xcrun notarytool store-credentials whisper-mac-notary \
  --apple-id "APPLE_ID_EMAIL" \
  --team-id "TEAMID" \
  --password "APP_SPECIFIC_PASSWORD"
```

Пароль сохранится в Keychain. Не добавляйте его в проект и не передавайте через переменные сборки.

## 3. Собрать подписанный и нотариализованный пакет

```bash
cd /Users/subnak/dev/whisper-mac

APP_SIGN_IDENTITY="Developer ID Application: Имя или компания (TEAMID)" \
PKG_SIGN_IDENTITY="Developer ID Installer: Имя или компания (TEAMID)" \
NOTARY_PROFILE="whisper-mac-notary" \
BUILD_DIR="$PWD/build-release" \
./scripts/build_pkg.sh
```

Скрипт выполнит четыре операции:

1. соберёт приложение и добавит hardened runtime;
2. подпишет `.app` сертификатом Developer ID Application;
3. подпишет `.pkg` сертификатом Developer ID Installer;
4. отправит пакет Apple, дождётся результата и прикрепит нотариальный билет.

## 4. Проверить пакет перед отправкой

```bash
codesign --verify --deep --strict --verbose=2 \
  "build-release/Whisper Mac.app"

pkgutil --check-signature \
  "build-release/WhisperMac-0.3.1.pkg"

xcrun stapler validate \
  "build-release/WhisperMac-0.3.1.pkg"

spctl --assess --type install --verbose=2 \
  "build-release/WhisperMac-0.3.1.pkg"
```

Ожидаемый результат `spctl`: `accepted`, источник — `Notarized Developer ID`.

## Локальная сборка без сертификатов

Обычная команда по-прежнему работает:

```bash
BUILD_DIR="$PWD/build-local" ./scripts/build_pkg.sh
```

Она создаёт ad-hoc подписанное приложение и неподписанный установщик. Это подходит для разработки, но на чужом Mac Gatekeeper может потребовать ручное подтверждение запуска.
