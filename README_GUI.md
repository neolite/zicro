# Zicro GUI Editor

Полнофункциональный GUI текстовый редактор на Zig + SDL2.

## Запуск

```bash
zig build run-gui-window
```

## Возможности

### Редактирование
- ✅ Ввод текста (все символы)
- ✅ Backspace (удаление назад)
- ✅ Delete (удаление вперед)
- ✅ Enter (новая строка)
- ✅ Line joining (backspace в начале строки)

### Навигация
- ✅ Стрелки (↑↓←→)
- ✅ Home/End (начало/конец строки)
- ✅ Page Up/Down (прокрутка страницами)
- ✅ Mouse wheel (скролл)
- ✅ Auto-scroll (курсор всегда виден)

### Undo/Redo
- ✅ Cmd+Z / Ctrl+Z (отменить)
- ✅ Cmd+Shift+Z / Ctrl+Shift+Z (вернуть)

### Визуал
- ✅ Monaco monospace font (14pt)
- ✅ Line numbers (серые)
- ✅ Blinking cursor (500ms)
- ✅ Dark theme (30/40/50 gray)
- ✅ 60 FPS rendering

## Архитектура

```
SDL2 GUI (375 lines)
    ↓
Zicro Core (4,883 lines)
    ↓
- Buffer (piece-table)
- LSP client  
- Syntax highlighter
- Undo/Redo stack
```

## Управление

```
Навигация:
  ↑↓←→        - Движение курсора
  Home/End    - Начало/конец строки
  Page Up/Down - Прокрутка страницами

Редактирование:
  Печать      - Ввод текста
  Backspace   - Удалить назад
  Delete      - Удалить вперед
  Enter       - Новая строка

Undo/Redo:
  Cmd+Z       - Отменить
  Cmd+Shift+Z - Вернуть

Прокрутка:
  Mouse Wheel - Скролл вверх/вниз

Выход:
  ESC или Q   - Закрыть
```

## Следующие фичи

- [ ] Selection (Shift+Arrows, mouse drag)
- [ ] Copy/Paste (Cmd+C/V/X)
- [ ] Status bar (line:col, file name)
- [ ] File operations (Open, Save, New)
- [ ] Syntax highlighting colors
- [ ] LSP integration UI

## Требования

- Zig 0.15.2+
- SDL2
- SDL2_ttf

### macOS

```bash
brew install sdl2 sdl2_ttf
zig build
```

### Linux

```bash
sudo apt install libsdl2-dev libsdl2-ttf-dev
zig build
```

## Размер

- Binary: 1.3MB
- Code: 375 lines
- Memory: <50MB

## Статус

**Functional editor** - готов к использованию для базового редактирования текста.
