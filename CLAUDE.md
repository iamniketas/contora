# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

# Agentic Behavior Rules

## Mindset
- You are not an assistant; you are an **Autonomous Software Engineer**.
- DO NOT suggest code changes in text. **ALWAYS apply them directly** using tools.
- Do not ask for permission to edit files or run tests. **Just do it.**
- If you see a bug or a task, your goal is to reach the "Done" state without user intervention.

## Tool Usage
- If the task requires changing code, the only acceptable output is the successful execution of `edit_file`.
- Use `shell_execute` to run compilers, linters, and tests immediately after editing.
- After fixing a bug, verify it by running the code before reporting back to me.

## Communication Style
- Be concise. Don't say "I will now fix the bug..." — just fix it and show the result.
- Stop using phrases like "You can try..." or "I suggest...". Use "I have fixed...", "I have deployed...".
- ALWAYS respond to the user in Russian (на русском языке).
- Keep technical terms and code snippets in their original form (English).
- Internal thoughts/reasoning can be in Russian too.

## Project Overview

Contora — нативное приложение для записи и расшифровки любого аудио: звонки, игры, подкасты, голосовые заметки. Локальная STT с диаризацией и интеллектуальное резюмирование.

**Текущий статус:** Windows MVP уже реализован. Сейчас активно разрабатывается **macOS-версия** — работаем в папке `apps/macos/` на Swift + SwiftUI.

## Активная разработка: macOS

Мы (пользователь + Claude) разрабатываем macOS-версию Contora. Среда выполнения — macOS-машина с Apple Silicon.

### Ключевые особенности macOS-версии

1. **Apple Silicon**: рантаймы и модели для STT должны максимально эффективно работать на M-чипах (Metal/ANE). Безопасный фолбек для Intel.
2. **Apple HIG**: внешний вид, UX и поведение должны на 100% соответствовать лучшим практикам macOS-приложений на Swift/SwiftUI.

### macOS Stack

- **UI Framework:** SwiftUI + AppKit (macOS 14+, Sonoma)
- **Audio Capture:** AVFoundation + Core Audio (loopback через ScreenCaptureKit, микрофон через AVAudioEngine)
- **STT Engine:** MLX Whisper через `mlx_audio` — OpenAI-совместимый HTTP-сервер на localhost
- **ML Runtime:** MLX (Apple framework для Apple Silicon)
- **Storage:** `~/Library/Application Support/NiketasAI/` — записи, транскрипты, сессии
- **Languages:** Russian/English

### Transcription Infrastructure

Расшифровка выполняется через локальный HTTP-сервер:

- **Backend:** `mlx_openai_http` — вызывает `http://127.0.0.1:8010/v1/audio/transcriptions`
- **Сервер:** Python venv в `~/Documents/projects/test-dmg/shared-mlx/`
- **Запуск:** `~/Documents/projects/test-dmg/shared-mlx/bin/start-mlx-server.sh`
- **Порт:** 8010
- **Модель по умолчанию:** `mlx-community/whisper-large-v3-turbo-asr-fp16`
- **Конфиг:** `~/Library/Application Support/NiketasAI/runtime/transcription-server.json`

**Запуск сервера перед тестированием транскрипции:**
```bash
~/Documents/projects/test-dmg/shared-mlx/bin/start-mlx-server.sh
```

**Проверка статуса:**
```bash
~/Documents/projects/test-dmg/shared-mlx/bin/check-mlx.sh
```

### macOS Project Structure

```
apps/macos/
├── Package.swift
└── Sources/ContoraMac/
    ├── main.swift                              # Всё приложение: SwiftUI App, Views, ViewModel
    ├── FasterWhisperProcessTranscriptionService.swift  # (legacy) subprocess-подход
    ├── SystemAudioCaptureService.swift         # System audio via ScreenCaptureKit
    ├── SharedRuntimePaths.swift                # Пути к рантаймам и моделям
    ├── SharedModelCatalog.swift                # Каталог установленных моделей
    ├── SharedTranscriptionServerConfig.swift   # Конфиг HTTP-бэкенда транскрипции
    ├── SharedMLXServerToolkit.swift            # Управление MLX-сервером (start/stop)
    └── PCMFloatScratchFileBuffer.swift         # Буфер для PCM-аудио
```

### macOS Development Commands

```bash
# Сборка
cd apps/macos && swift build

# Запуск (debug)
cd apps/macos && swift run

# Запуск MLX-сервера (нужен для транскрипции)
~/Documents/projects/test-dmg/shared-mlx/bin/start-mlx-server.sh

# Проверка MLX
~/Documents/projects/test-dmg/shared-mlx/bin/check-mlx.sh
```

## Windows Reference Implementation

Оригинальная Windows-версия (референсная реализация) находится в `src/`:

```
src/
├── AudioRecorder.App/      # WinUI 3 (UI слой)
├── AudioRecorder.Core/     # Core модели и интерфейсы
└── AudioRecorder.Services/ # Сервисы (Audio, STT, Storage)
```

**Windows Stack:**
- WinUI 3 + .NET 8 (C#) — нативный Fluent Design для Windows 11
- NAudio + WASAPI (loopback для системного звука, capture для микрофона)
- Faster-Whisper + pyannote через Python interop
- SQLite + sqlite-vec, Markdown export

**Windows Development Commands:**
```bash
dotnet build Contora.sln
dotnet add src/AudioRecorder.Services/AudioRecorder.Services.csproj package <PackageName>
```

## Audio Sources

Приложение обрабатывает аудио из трёх источников:

1. **System Output (Loopback)** — всё, что пользователь слышит: звонки, игры, видео, музыка
2. **Microphone Input** — голос пользователя (для полной записи диалогов)
3. **File Import** — загрузка готовых аудио/видеофайлов (голосовые заметки, подкасты, записи)

Поддерживаемые форматы: WAV, MP3, FLAC, OGG, M4A, OPUS.

## Pipeline

1. **Capture/Import** → Core Audio loopback + mic, или импорт файла
2. **Preprocessing** → VAD (отсечение тишины), нормализация громкости
3. **STT** → Whisper (MLX на Apple Silicon) — расшифровка с таймстампами
4. **Diarization** → разделение по спикерам (S1, S2...)
5. **Post-processing** → LLM: очистка текста, структурирование, извлечение решений/рисков/задач
6. **Storage** → сессии в `~/Library/Application Support/NiketasAI/`
7. **Export** → Markdown, позже интеграции (Slack, Telegram, Jira)

Audio is temporary (deleted after transcription). Only text and metadata are stored locally.

## Quality Profiles

- **Quality (Large)** — максимальная точность
- **Balance (Medium/Turbo)** — компромисс ← **текущий дефолт**
- **Speed (Small/Distil)** — быстрый черновик

## Roadmap

- **macOS MVP (текущий):** импорт файлов + захват аудио, локальная STT через MLX, базовый SwiftUI UI
- **v0.2:** семантический поиск по всем записям, LLM post-processing (конспект, задачи)
- **v0.3:** автопротокол → задачи, дайджесты, экспорт в Telegram/Slack/Jira
- **v1.0:** стабильные сборки, профили качества, опциональные платные функции

## Notes

- Записи сохраняются в `~/Library/Application Support/NiketasAI/recordings/`
- Формат файлов: `recording_YYYYMMDD_HHmmss.wav` → `.m4a`
- Логи Whisper: рядом с результатом как `{имя}_whisper.log`
- Конфиг транскрипции: `~/Library/Application Support/NiketasAI/runtime/transcription-server.json`
- Каталог моделей: `~/Library/Application Support/NiketasAI/runtime/model-catalog.json`
