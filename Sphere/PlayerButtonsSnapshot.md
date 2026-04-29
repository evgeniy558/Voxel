# Снимок кода кнопок большого плеера (до оптимизации от лагов)

**Дата:** сохранить на случай отката. Кнопки НЕ используют .drawingGroup() и не оборачивают действия в DispatchQueue.main.async.

**Что откатить при необходимости:**
- В ContentView.swift в PlayerSheetView: ряд из 3 кнопок (назад, play/pause, вперёд) и нижний ряд из 5 кнопок — действия вызываются напрямую: `Button { onPrevious() }`, `Button { onTogglePlayPause() }`, `Button { isFavorite.toggle() }` и т.д.
- Не добавлять .drawingGroup() на эти ряды — ломало плеер.

**Текущая оптимизация (другая):** действия кнопок обёрнуты в `DispatchQueue.main.async { ... }`, чтобы отклик на тап был мгновенным, а тяжёлое обновление состояния — на следующем цикле run loop.

**Как откатить эту оптимизацию:** у всех кнопок с действием в большом плеере заменить `Button { DispatchQueue.main.async { onPrevious() } }` на `Button { onPrevious() }` (и аналогично для onTogglePlayPause, onNext, isFavorite.toggle(), onRepeatCycle) — в обоих ветках #available(iOS 26) и else.
