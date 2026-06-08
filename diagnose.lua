local component = require("component")
local term = require("term")

if not component.isAvailable("me_controller") then
  print("Ошибка: me_controller не найден!")
  return
end

local me = component.me_controller
term.clear()

local cpus = me.getCpus()
print("Всего процессоров: " .. tostring(#cpus))

for i, cpu in ipairs(cpus) do
  print(string.format("\n=== CPU %d ===", i))
  for k, v in pairs(cpu) do
    if k ~= "cpu" then
      print(string.format("  %s: %s (%s)", k, tostring(v), type(v)))
    else
      print(string.format("  cpu: %s (%s)", tostring(v), type(v)))
      local cpuVal = v
      if type(cpuVal) == "table" or type(cpuVal) == "userdata" then
        -- Попытка прочесть методы
        print("  Попытка вызвать методы на cpu:")
        local ok_act, act = pcall(cpuVal.activeItems, cpuVal)
        print("    activeItems:", ok_act, type(act), tostring(act))
        if ok_act and type(act) == "table" then
          print("      Кол-во элементов в activeItems: " .. #act)
          if #act > 0 then
            for idx, item in ipairs(act) do
              print(string.format("        [%d]: %s x%d", idx, tostring(item.label or item.name), item.size or 0))
            end
          end
        end

        local ok_pend, pend = pcall(cpuVal.pendingItems, cpuVal)
        print("    pendingItems:", ok_pend, type(pend), tostring(pend))
        if ok_pend and type(pend) == "table" then
          print("      Кол-во элементов в pendingItems: " .. #pend)
        end

        local ok_store, store = pcall(cpuVal.storedItems, cpuVal)
        print("    storedItems:", ok_store, type(store), tostring(store))
        
        local ok_final, final = pcall(cpuVal.finalOutput, cpuVal)
        print("    finalOutput:", ok_final, type(final), tostring(final))
        if ok_final and type(final) == "table" then
          for k2, v2 in pairs(final) do
            print(string.format("      final.%s = %s", k2, tostring(v2)))
          end
        end
      end
    end
  end
end
