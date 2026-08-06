# Как установить Contora из GitHub Releases

## Что отправить

Отправь ссылку на последний релиз:

```text
https://github.com/iamniketas/contora/releases/latest
```

## macOS

Для Mac с Apple Silicon нужно скачать файл вида:

```text
Contora-macOS-<version>-arm64-signed.dmg
```

Если это пилотная неподписанная сборка, файл будет называться:

```text
Contora-macOS-<version>-arm64-unsigned.dmg
```

После скачивания:

1. Открыть `.dmg`.
2. Перетащить `Contora.app` в `Applications`.
3. Запустить Contora из `Applications`.
4. Если macOS заблокирует неподписанную сборку, открыть `System Settings -> Privacy & Security`, нажать `Open Anyway` для Contora и подтвердить запуск.
5. Разрешить `Microphone` и `Screen Recording`.
6. В Contora нажать `Set Up Local Whisper`.

Обновление потом делается из самого приложения:

1. Открыть `Settings`.
2. В блоке `Updates` нажать `Check for Updates`.
3. Если версия найдена, нажать `Download Update`.
4. В открывшемся DMG перетащить новую `Contora.app` в `Applications` с заменой старой.

## Windows

Для Windows нужно скачать файл вида:

```text
*-Setup.exe
```

Не нужно скачивать `*.nupkg`, `RELEASES` или `Source code`.
