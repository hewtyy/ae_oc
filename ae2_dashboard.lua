-- ======================================================================
-- Скрипт: Единый информационный дашборд «всё в одном» для сети AE2
-- Версия игры: Minecraft 1.12.2
-- ОС: OpenOS (OpenComputers)
-- Требования: Компьютер Tier 3, Видеокарта Tier 3, Монитор Tier 3 (4х3)
-- Подключение: Адаптер вплотную к ME Контроллеру (me_controller)
-- ======================================================================

local component = require("component")
local term = require("term")
local computer = require("computer")
local event = require("event")
local unicode = require("unicode")

-- Проверка доступности ME контроллера при запуске
if not component.isAvailable("me_controller") then
  io.stderr:write("Ошибка: Компонент 'me_controller' не найден.\n")
  io.stderr:write("Убедитесь, что Адаптер установлен вплотную к ME Контроллеру и подключен к компьютеру.\n")
  os.exit(1)
end

-- ======================================================================
--                           НАСТРОЙКИ
-- ======================================================================

-- Интервал обновления экрана (в секундах)
local UPDATE_INTERVAL = 2.0

-- Максимальное разрешение экрана для вывода дашборда
local WIDTH = 100
local HEIGHT = 30

-- Настройки ячеек хранения AE2 (для точной оценки заполненности)
-- Заполните эту таблицу в соответствии с тем, какие ячейки вставлены в ваши МЭ Накопители.
local CELLS_SETUP = {
  { size_kb = 1,     count = 0 },
  { size_kb = 4,     count = 0 },
  { size_kb = 16,    count = 0 },
  { size_kb = 64,    count = 0 },
  { size_kb = 256,   count = 57 }, -- Настройки по умолчанию пользователя: 57 ячеек по 256кб
  { size_kb = 1024,  count = 0 },  -- 1М ячейка
  { size_kb = 4096,  count = 0 },  -- 4М ячейка
  { size_kb = 16384, count = 0 },  -- 16М ячейка
  { size_kb = 65536, count = 0 }   -- 65М ячейка
}

-- Лимит пакета автокрафта (сколько предметов за раз запрашивать при дефиците)
local CRAFT_BATCH_SIZE = 100

-- Список 5 критических ресурсов для мониторинга (Stock)
-- Вы можете изменить названия, ID и нормы под ваши нужды (включая предметы из модов)
local stock_resources = {
  { name = "Железо",   id = "minecraft:iron_ingot", damage = 0, norm = 1000 },
  { name = "Золото",   id = "minecraft:gold_ingot", damage = 0, norm = 500 },
  { name = "Редстоун", id = "minecraft:redstone",   damage = 0, norm = 2000 },
  { name = "Алмазы",   id = "minecraft:diamond",    damage = 0, norm = 200 },
  { name = "Уголь",    id = "minecraft:coal",       damage = 0, norm = 1000 },
}

-- ======================================================================
--                       ЦВЕТОВАЯ ПАЛИТРА (RGB)
-- ======================================================================
local COLOR_BG = 0x0F0F13          -- Темный фон (темно-фиолетовый оттенок)
local COLOR_BORDER = 0x3F3F4F      -- Цвет рамок (приглушенный серый)
local COLOR_TEXT_DEFAULT = 0x9E9EAE-- Обычный текст (светло-серый)
local COLOR_TEXT_WHITE = 0xE0E0E0  -- Выделенный текст (почти белый)
local COLOR_OK = 0x00FF66          -- Неоново-зеленый (все в норме)
local COLOR_WARN = 0xFFB300        -- Желтый/Оранжевый (предупреждение)
local COLOR_CRIT = 0xFF3333        -- Ярко-красный (критическая ошибка / разряд)
local COLOR_CRAFTING = 0x33B3FF    -- Голубой (активный крафт)
local COLOR_PROGRESS_BG = 0x22222D -- Темный фон для полосы прогресса

-- ======================================================================
--                     СИСТЕМНЫЕ ПЕРЕМЕННЫЕ И СОСТОЯНИЯ
-- ======================================================================
local gpu = component.gpu
local running = true
local flash_state = false
local screen_initialized = false
local last_offline_draw = 0

-- Таблица для отслеживания времени запуска задач на CPU (для зависаний)
-- Ключ: имя CPU или индекс, значение: { jobName = "...", startTime = timestamp }
local last_jobs = {}

-- Таблица для отслеживания прогресса крафта по процессорам
local cpu_jobs = {}

-- Таблица для отслеживания текущих запросов крафта, чтобы не спамить ими
-- Ключ: ID ресурса, значение: объект запроса крафта от AE2
local active_craft_requests = {}

-- Сохранение старых настроек терминала для восстановления при выходе
local prev_w, prev_h = gpu.getResolution()
local prev_fore = gpu.getForeground()
local prev_back = gpu.getBackground()

-- ======================================================================
--                     ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
-- ======================================================================

-- Функция корректного форматирования чисел энергии
local function formatEnergy(val)
  if not val then return "0.0 AE" end
  if val >= 1000000000 then
    return string.format("%.2f GAE", val / 1000000000)
  elseif val >= 1000000 then
    return string.format("%.2f MAE", val / 1000000)
  elseif val >= 1000 then
    return string.format("%.2f kAE", val / 1000)
  else
    return string.format("%.0f AE", val)
  end
end

-- Функция форматирования потребления энергии
local function formatUsage(val)
  if not val then return "0.0" end
  if val >= 1000 then
    return string.format("%.1f k", val / 1000)
  else
    return string.format("%.1f", val)
  end
end

-- Функция форматирования количества предметов в сети (К, М)
local function formatCount(val)
  if not val then return "0" end
  if val >= 1000000000 then
    return string.format("%.2f G", val / 1000000000)
  elseif val >= 1000000 then
    return string.format("%.2f M", val / 1000000)
  elseif val >= 1000 then
    return string.format("%.1f k", val / 1000)
  else
    return tostring(val)
  end
end

-- Функция форматирования байтов памяти
local function formatBytes(val)
  if not val then return "0 B" end
  if val >= 1024 * 1024 then
    return string.format("%.1f MB", val / (1024 * 1024))
  elseif val >= 1024 then
    return string.format("%.1f kB", val / 1024)
  else
    return string.format("%d B", val)
  end
end

-- Получить прокси к контроллеру с проверкой ошибок
local function getController()
  local address = component.list("me_controller")()
  if not address then return nil end
  local ok, proxy = pcall(component.proxy, address)
  if ok then return proxy else return nil end
end

-- Безопасная инициализация экрана
local function initScreen()
  gpu.setResolution(WIDTH, HEIGHT)
  gpu.setBackground(COLOR_BG)
  gpu.setForeground(COLOR_TEXT_DEFAULT)
  term.clear()
end

-- Отрисовка статических рамок (избегает мерцания, рисуется один раз)
local function drawBorders()
  gpu.setForeground(COLOR_BORDER)
  
  -- Углы рамок
  gpu.set(1, 1, "┌")
  gpu.set(WIDTH, 1, "┐")
  gpu.set(1, HEIGHT, "└")
  gpu.set(WIDTH, HEIGHT, "┘")
  
  -- Горизонтальные разделители
  for x = 2, WIDTH - 1 do
    gpu.set(x, 1, "─")
    gpu.set(x, HEIGHT, "─")
    gpu.set(x, 15, "─") -- Разделитель верх/низ
  end
  
  -- Вертикальные разделители
  for y = 2, HEIGHT - 1 do
    gpu.set(1, y, "│")
    gpu.set(WIDTH, y, "│")
    gpu.set(50, y, "│") -- Разделитель лево/право
  end
  
  -- Пересечения линий рамок
  gpu.set(50, 1, "┬")
  gpu.set(50, HEIGHT, "┴")
  gpu.set(1, 15, "├")
  gpu.set(WIDTH, 15, "┤")
  gpu.set(50, 15, "┼")
end

-- Вывод заголовков поверх рамок
local function drawTitles()
  gpu.setBackground(COLOR_BG)
  
  gpu.setForeground(COLOR_TEXT_WHITE)
  gpu.set(4, 1, " ЭНЕРГОСИСТЕМА (AE) ")
  gpu.set(54, 1, " АВТОКРАФТ И CPU ")
  gpu.set(4, 15, " КОНТРОЛЬ ХРАНИЛИЩА ")
  gpu.set(54, 15, " КРИТИЧЕСКИЕ РЕСУРСЫ (STOCK) ")
end

-- Безопасное стирание и вывод текста без мерцания (дополнение пробелами)
local function writeText(x, y, text, foreColor, limitWidth)
  if foreColor then
    gpu.setForeground(foreColor)
  else
    gpu.setForeground(COLOR_TEXT_DEFAULT)
  end
  
  local cleanText = tostring(text)
  if limitWidth then
    local len = unicode.len(cleanText)
    if len > limitWidth then
      cleanText = unicode.sub(cleanText, 1, limitWidth - 3) .. "..."
    else
      cleanText = cleanText .. string.rep(" ", limitWidth - len)
    end
  end
  
  gpu.set(x, y, cleanText)
end

-- Отрисовка полосы прогресса (Progress Bar)
local function drawProgressBar(x, y, percent, width, activeColor, inactiveColor)
  local barWidth = width - 2
  local filledChars = math.floor((percent / 100) * barWidth)
  if filledChars < 0 then filledChars = 0 end
  if filledChars > barWidth then filledChars = barWidth end
  
  local emptyChars = barWidth - filledChars
  
  gpu.setForeground(COLOR_BORDER)
  gpu.set(x, y, "[")
  
  gpu.setForeground(activeColor or COLOR_OK)
  gpu.set(x + 1, y, string.rep("■", filledChars))
  
  gpu.setForeground(inactiveColor or COLOR_PROGRESS_BG)
  gpu.set(x + 1 + filledChars, y, string.rep("·", emptyChars))
  
  gpu.setForeground(COLOR_BORDER)
  gpu.set(x + width - 1, y, "]")
end

-- Восстановление исходного состояния терминала при выходе
local function cleanup()
  gpu.setBackground(prev_back)
  gpu.setForeground(prev_fore)
  gpu.setResolution(prev_w, prev_h)
  term.clear()
  print("Скрипт дашборда закрыт. Параметры экрана успешно восстановлены.")
end

-- Отрисовка экрана оффлайн при сбое связи с сетью AE2
local function drawOfflineScreen(err)
  local now = computer.uptime()
  -- Рисуем экран оффлайн не чаще чем раз в 1.8 секунды, чтобы избежать мигания
  if now - last_offline_draw < 1.8 then return end
  last_offline_draw = now
  
  gpu.setResolution(80, 25)
  gpu.setBackground(COLOR_BG)
  gpu.setForeground(COLOR_CRIT)
  term.clear()
  
  local msg1 = "┌──────────────────────────────────────────────┐"
  local msg2 = "│         ВНИМАНИЕ: СЕТЬ AE2 ОФФЛАЙН           │"
  local msg3 = "│    ME Контроллер не найден или обесточен     │"
  local msg4 = "│       Попытка восстановления связи...        │"
  local msg5 = "└──────────────────────────────────────────────┘"
  
  local startX = 17
  gpu.set(startX, 9, msg1)
  gpu.set(startX, 10, msg2)
  gpu.set(startX, 11, msg3)
  gpu.set(startX, 12, msg4)
  gpu.set(startX, 13, msg5)
  
  if err then
    gpu.setForeground(COLOR_TEXT_DEFAULT)
    -- Безопасный вывод деталей ошибки
    local errStr = tostring(err)
    if unicode.len(errStr) > 70 then
      errStr = unicode.sub(errStr, 1, 67) .. "..."
    end
    gpu.set(5, 16, "Сведения об ошибке: " .. errStr)
  end
end

-- Поиск рецепта крафта в сети (с защитой от кривых фильтров API)
local function findCraftable(controller, itemId, damage)
  -- 1. Попытка быстрого поиска через фильтр в getCraftables
  local ok, craftables = pcall(controller.getCraftables, { name = itemId, damage = damage })
  if ok and craftables and craftables[1] then
    return craftables[1]
  end
  
  -- 2. Запасной вариант: полный обход рецептов, если фильтр не сработал или вернул nil
  local ok2, allCraftables = pcall(controller.getCraftables)
  if ok2 and allCraftables then
    for _, craftable in ipairs(allCraftables) do
      local ok3, stack = pcall(craftable.getItemStack, craftable)
      if ok3 and stack then
        if stack.name == itemId and (not damage or stack.damage == damage) then
          return craftable
        end
      end
    end
  end
  
  return nil
end

-- ======================================================================
--                 ОБНОВЛЕНИЕ ДАННЫХ ДАШБОРДА (ОСНОВНОЙ ЦИКЛ)
-- ======================================================================
local function updateDashboard(controller)
  flash_state = not flash_state
  
  -- ==========================================
  -- 1. КВАДРАНТ: ЭНЕРГОСИСТЕМА (AE)
  -- ==========================================
  local stored = controller.getStoredPower()
  local max = controller.getMaxStoredPower()
  local usage = controller.getAvgPowerUsage()
  
  local energyPercent = 0
  if max > 0 then
    energyPercent = (stored / max) * 100
    if energyPercent > 100 then energyPercent = 100 end
  end
  
  -- Вывод информации
  writeText(3, 3, "Заряд сети:  " .. string.format("%.1f%%", energyPercent), COLOR_TEXT_WHITE, 46)
  writeText(3, 4, "Накоплено:   " .. formatEnergy(stored), COLOR_TEXT_DEFAULT, 46)
  writeText(3, 5, "Максимум:    " .. formatEnergy(max), COLOR_TEXT_DEFAULT, 46)
  
  -- Цветовая индикация полосы энергии
  local energyBarColor = COLOR_OK
  if energyPercent < 20 then
    energyBarColor = COLOR_CRIT
  elseif energyPercent < 50 then
    energyBarColor = COLOR_WARN
  end
  
  drawProgressBar(3, 7, energyPercent, 45, energyBarColor, COLOR_PROGRESS_BG)
  writeText(3, 9, "Потребление: " .. formatUsage(usage) .. " AE/t", COLOR_TEXT_WHITE, 46)
  
  -- Флашинг критического разряда при заряде < 20%
  if energyPercent < 20 then
    if flash_state then
      writeText(3, 11, "[КРИТИЧЕСКИЙ ЗАРЯД]", COLOR_CRIT, 46)
    else
      writeText(3, 11, "", nil, 46) -- Моргание
    end
  else
    writeText(3, 11, "Статус питания: OK", COLOR_OK, 46)
  end
  
  -- ==========================================
  -- 2. КВАДРАНТ: АВТОКРАФТ И CPU
  -- ==========================================
  local cpus = controller.getCpus()
  local total_cpus = #cpus
  local free_cpus = 0
  local busy_cpus = 0
  
  for _, cpu in ipairs(cpus) do
    -- Пытаемся определить занятость несколькими способами
    local isBusy = false
    if cpu.busy or cpu.isActive then
      isBusy = true
    elseif cpu.cpu then
      local ok, out = pcall(cpu.cpu.finalOutput)
      if ok and out and out.name then
        isBusy = true
      end
    end
    
    if isBusy then
      busy_cpus = busy_cpus + 1
    else
      free_cpus = free_cpus + 1
    end
    -- Сохраняем флаг занятости для дальнейшего использования
    cpu._isBusy = isBusy
  end
  
  writeText(53, 3, "Всего процессоров: " .. total_cpus, COLOR_TEXT_WHITE, 46)
  writeText(53, 4, "Свободно: " .. free_cpus .. " | Занято: " .. busy_cpus, COLOR_TEXT_DEFAULT, 46)
  
  -- Чистим записи о неактивных процессорах для таймера зависания
  local currentCpuIds = {}
  for i, cpu in ipairs(cpus) do
    local cpuId = cpu.name or ("CPU_" .. i)
    currentCpuIds[cpuId] = true
    if not cpu._isBusy then
      last_jobs[cpuId] = nil
    end
  end
  for cpuId, _ in pairs(last_jobs) do
    if not currentCpuIds[cpuId] then
      last_jobs[cpuId] = nil
    end
  end
  
  -- Отображение занятых CPU
  local row = 6
  for i, cpu in ipairs(cpus) do
    if cpu._isBusy and row <= 14 then
      local jobName = "Загрузка..."
      local progressPercent = nil
      
      -- Идентификация процессора и вычисление времени выполнения
      local cpuId = cpu.name or ("CPU_" .. i)
      local now = computer.uptime()
      
      local main_item_label = nil
      local remaining = 0
      local stored = 0

      -- 1. Сначала пробуем стандартный finalOutput
      if cpu.cpu and cpu.cpu.finalOutput then
        local ok, out = pcall(cpu.cpu.finalOutput, cpu.cpu)
        if ok and out and type(out) == "table" then
          main_item_label = out.label or out.displayName or out.name
        end
      end

      -- 2. Если finalOutput не дал результата, опрашиваем списки
      if not main_item_label and cpu.cpu then
        local ok_act, act = pcall(cpu.cpu.activeItems, cpu.cpu)
        local ok_pend, pend = pcall(cpu.cpu.pendingItems, cpu.cpu)
        local ok_store, store = pcall(cpu.cpu.storedItems, cpu.cpu)

        -- Главный предмет - первый в списке active, pending или stored
        if ok_act and act and #act > 0 then
          main_item_label = act[1].label or act[1].displayName or act[1].name
        elseif ok_pend and pend and #pend > 0 then
          main_item_label = pend[1].label or pend[1].displayName or pend[1].name
        elseif ok_store and store and #store > 0 then
          main_item_label = store[1].label or store[1].displayName or store[1].name
        end

        if main_item_label then
          -- Считаем оставшееся количество главного предмета
          if ok_act and act then
            for _, item in ipairs(act) do
              local name = item.label or item.displayName or item.name
              if name == main_item_label then
                remaining = remaining + item.size
              end
            end
          end
          if ok_pend and pend then
            for _, item in ipairs(pend) do
              local name = item.label or item.displayName or item.name
              if name == main_item_label then
                remaining = remaining + item.size
              end
            end
          end
          -- Считаем сколько уже скрафчено и лежит на CPU
          if ok_store and store then
            for _, item in ipairs(store) do
              local name = item.label or item.displayName or item.name
              if name == main_item_label then
                stored = stored + item.size
              end
            end
          end
        end
      end

      if main_item_label then
        -- Управление состоянием работы для вычисления прогресса
        local job = cpu_jobs[cpuId]
        if not job or job.label ~= main_item_label then
          job = {
            label = main_item_label,
            total = remaining + stored,
            last_remaining = remaining,
            start_time = now
          }
          cpu_jobs[cpuId] = job
        else
          local current_total = remaining + stored
          if current_total > job.total then
            job.total = current_total
          end
          job.last_remaining = remaining
        end

        local crafted = job.total - remaining
        if crafted < 0 then crafted = 0 end

        if job.total > 0 then
          progressPercent = (crafted / job.total) * 100
        else
          progressPercent = 0
        end

        -- Оценка оставшегося времени
        local time_left_str = ""
        if remaining > 0 and crafted > 0 then
          local elapsed = now - job.start_time
          if elapsed > 5 then
            local speed = crafted / elapsed -- предметов в секунду
            if speed > 0 then
              local seconds_left = remaining / speed
              if seconds_left < 60 then
                time_left_str = string.format(" ~%.0fs", seconds_left)
              elseif seconds_left < 3600 then
                time_left_str = string.format(" ~%dm", math.ceil(seconds_left / 60))
              else
                time_left_str = string.format(" ~%.1fh", seconds_left / 3600)
              end
            end
          end
        end

        jobName = string.format("%s (%d/%d)%s", main_item_label, crafted, job.total, time_left_str)
      else
        jobName = "Подготовка..."
      end

      if not last_jobs[cpuId] or last_jobs[cpuId].jobName ~= jobName then
        last_jobs[cpuId] = {
          jobName = jobName,
          startTime = now,
          lastActive = now
        }
      else
        last_jobs[cpuId].lastActive = now
      end
      
      local elapsed = now - last_jobs[cpuId].startTime
      local isStuck = elapsed > 180 -- Задача зависла на одном предмете более 3 минут
      
      local statusText = ""
      local color = COLOR_TEXT_DEFAULT
      if isStuck then
        statusText = "[ЗАВИС?]"
        color = COLOR_WARN
      else
        statusText = "[ЗАГРУЖЕН]"
        color = COLOR_OK
      end
      
      if progressPercent then
        statusText = string.format("%.0f%% %s", progressPercent, statusText)
      end
      
      writeText(53, row, string.format("#%d %s: %s", i, cpuId, jobName), color, 30)
      writeText(83, row, statusText, color, 15)
      
      row = row + 1
    end
  end
  
  -- Очистка пустых строк в списке процессоров
  for r = row, 14 do
    writeText(53, r, "", nil, 45)
  end
  
  -- ==========================================
  -- 3. КВАДРАНТ: КОНТРОЛЬ ХРАНИЛИЩА
  -- ==========================================
  local items = controller.getItemsInNetwork()
  local types_used = #items
  local total_items_count = 0
  
  -- Считаем общее число вещей
  for _, item in ipairs(items) do
    total_items_count = total_items_count + item.size
  end
  
  -- Математический расчет байтов
  local max_bytes = 0
  local max_types = 0
  for _, cell in ipairs(CELLS_SETUP) do
    max_bytes = max_bytes + (cell.count * cell.size_kb * 1024)
    max_types = max_types + (cell.count * 63)
  end
  
  -- Базовая стоимость типа в AE2 составляет 1/128 от емкости ячейки.
  -- Вычисляем среднюю стоимость регистрации типа на основе CELLS_SETUP.
  local total_cells_count = 0
  for _, cell in ipairs(CELLS_SETUP) do
    if cell.count > 0 then
      total_cells_count = total_cells_count + cell.count
    end
  end

  local average_bytes_per_type = 0
  if total_cells_count > 0 then
    average_bytes_per_type = max_bytes / (total_cells_count * 128)
  else
    -- Fallback на ячейки 64k, если не настроено
    average_bytes_per_type = 512
  end

  local used_bytes_types = types_used * average_bytes_per_type
  local used_bytes_items = 0
  for _, item in ipairs(items) do
    used_bytes_items = used_bytes_items + math.ceil(item.size / 8)
  end
  
  local used_bytes = used_bytes_types + used_bytes_items
  
  local percent_bytes = 0
  if max_bytes > 0 then
    percent_bytes = (used_bytes / max_bytes) * 100
  end
  
  local percent_types = 0
  if max_types > 0 then
    percent_types = (types_used / max_types) * 100
  end
  
  -- Вывод информации хранилища
  writeText(3, 17, "Всего предметов: " .. formatCount(total_items_count), COLOR_TEXT_WHITE, 46)
  
  writeText(3, 19, "Память (байты): " .. string.format("%.1f%%", percent_bytes), COLOR_TEXT_DEFAULT, 46)
  local bytesBarColor = COLOR_OK
  if percent_bytes > 90 then bytesBarColor = COLOR_CRIT elseif percent_bytes > 75 then bytesBarColor = COLOR_WARN end
  drawProgressBar(3, 20, percent_bytes, 45, bytesBarColor, COLOR_PROGRESS_BG)
  if max_bytes > 0 and used_bytes > max_bytes then
    writeText(3, 19, "Память (ячейки): Внешнее (>100%)", COLOR_CRAFTING, 46)
    drawProgressBar(3, 20, 100, 45, COLOR_CRAFTING, COLOR_PROGRESS_BG)
    writeText(3, 21, "Использовано: " .. formatBytes(used_bytes) .. " / " .. formatBytes(max_bytes), COLOR_TEXT_DEFAULT, 46)
  else
    writeText(3, 19, "Память (ячейки): " .. string.format("%.1f%%", percent_bytes), COLOR_TEXT_DEFAULT, 46)
    local bytesBarColor = COLOR_OK
    if percent_bytes > 90 then bytesBarColor = COLOR_CRIT elseif percent_bytes > 75 then bytesBarColor = COLOR_WARN end
    drawProgressBar(3, 20, percent_bytes, 45, bytesBarColor, COLOR_PROGRESS_BG)
    if max_bytes == 0 then
      writeText(3, 21, "Использовано: " .. formatBytes(used_bytes) .. " (настройте CELLS_SETUP)", COLOR_WARN, 46)
    else
      writeText(3, 21, "Использовано: " .. formatBytes(used_bytes) .. " / " .. formatBytes(max_bytes), COLOR_TEXT_DEFAULT, 46)
    end
  end
  
  -- Текстовые уведомления о перегрузке типов / памяти
  if percent_types > 90 then
    writeText(3, 27, "[ПРЕДУПРЕЖДЕНИЕ: ТИПЫ ЗАБИТЫ (>90%)]", COLOR_CRIT, 46)
  elseif percent_bytes > 90 then
    writeText(3, 27, "[ПРЕДУПРЕЖДЕНИЕ: МАЛО ПАМЯТИ (>90%)]", COLOR_WARN, 46)
  else
    writeText(3, 27, "Ячейки памяти стабильны", COLOR_OK, 46)
  end
  
  -- ==========================================
  -- 4. КВАДРАНТ: КРИТИЧЕСКИЕ РЕСУРСЫ (STOCK)
  -- ==========================================
  -- Сброс временных счетчиков
  for _, res in ipairs(stock_resources) do
    res.current = 0
  end
  
  -- Заполнение актуальных количеств из сети
  for _, item in ipairs(items) do
    for _, res in ipairs(stock_resources) do
      if item.name == res.id and (not res.damage or item.damage == res.damage) then
        res.current = res.current + item.size
      end
    end
  end
  
  -- Шапка таблицы критических ресурсов
  writeText(53, 17, "Ресурс          В сети     Норма     Статус", COLOR_TEXT_WHITE, 46)
  
  -- Вывод ресурсов и запуск крафта
  local stock_row = 19
  for _, res in ipairs(stock_resources) do
    local statusText = "[OK]"
    local statusColor = COLOR_OK
    
    if res.current < res.norm then
      statusText = "[МАЛО]"
      statusColor = COLOR_WARN
      
      -- Логика управления запросом крафта
      local req = active_craft_requests[res.id]
      if req then
        local isDone = true
        local isCanceled = false
        
        -- Безопасная проверка статуса
        local ok1, res1 = pcall(req.isDone, req)
        if ok1 then isDone = res1 end
        local ok2, res2 = pcall(req.isCanceled, req)
        if ok2 then isCanceled = res2 end
        
        if isDone or isCanceled then
          active_craft_requests[res.id] = nil
          req = nil
        end
      end
      
      if not req then
        -- Попытка найти шаблон для автокрафта
        local template = findCraftable(controller, res.id, res.damage)
        if template then
          local missing = res.norm - res.current
          local craftAmount = math.min(missing, CRAFT_BATCH_SIZE)
          
          -- Запускаем крафт одного пакета
          local ok, reqObj = pcall(template.request, template, craftAmount)
          if ok and reqObj then
            active_craft_requests[res.id] = reqObj
            statusText = "[КРАФТ]"
            statusColor = COLOR_CRAFTING
          end
        end
      else
        statusText = "[КРАФТ]"
        statusColor = COLOR_CRAFTING
      end
    end
    
    -- Выводим строку ресурса на экран
    writeText(53, stock_row, res.name, COLOR_TEXT_WHITE, 15)
    writeText(69, stock_row, formatCount(res.current), COLOR_TEXT_DEFAULT, 10)
    writeText(80, stock_row, formatCount(res.norm), COLOR_TEXT_DEFAULT, 10)
    writeText(91, stock_row, statusText, statusColor, 8)
    
    stock_row = stock_row + 2
  end
end

-- ======================================================================
--                             ОСНОВНОЙ ВХОД
-- ======================================================================
local function main()
  initScreen()
  drawBorders()
  drawTitles()
  
  local controller = nil
  
  while running do
    controller = getController()
    
    if not controller then
      screen_initialized = false
      drawOfflineScreen("Не удается обнаружить прокси 'me_controller'")
      os.sleep(2)
    else
      -- Восстановление рамок после оффлайн режима
      if not screen_initialized then
        initScreen()
        drawBorders()
        drawTitles()
        screen_initialized = true
      end
      
      -- Запуск обновления с проверкой ошибок связи
      local ok, err = pcall(updateDashboard, controller)
      if not ok then
        -- Если выброшено прерывание Ctrl+C, выходим из цикла
        if tostring(err):find("interrupted") then
          error("interrupted")
        end
        
        screen_initialized = false
        drawOfflineScreen(err)
        os.sleep(2)
      else
        os.sleep(UPDATE_INTERVAL)
      end
    end
  end
end

-- ======================================================================
--                    ЗАПУСК И ОБРАБОТКА Ctrl+C
-- ======================================================================
local ok, err = pcall(main)
cleanup() -- Сброс цветов и разрешения

if not ok then
  if err and tostring(err):find("interrupted") then
    print("Программа завершена пользователем (Ctrl+C).")
  else
    io.stderr:write("Критическая ошибка выполнения дашборда:\n" .. tostring(err) .. "\n")
  end
end
