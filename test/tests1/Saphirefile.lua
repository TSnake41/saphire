local saphire = require "saphire"
local is_windows = require("los").type() == "Windows"
local routines = {}

for i=1,15 do
  routines[i] = function ()
    local tasks = {}
    local tasks_after = {}

    for j=1,16 do
      if saphire.targets["clean"] then
        tasks[j] = {
          command = string.format("%s src/%d.%d.o", is_windows and "del" or "rm", i, j),
          name = "deleting subgroup " .. i
        }
      else
        tasks[j] = {
          command = string.format("cc -O0 -c -o src/%d.%d.o src/empty.c", i, j),
          name = "subgroup " .. i
        }
        tasks_after[j] = {
          command = string.format("strip src/%d.%d.o", i, j),
          name = "subgroup " .. i .. " stripping"
        }
      end
    end

    saphire.do_multi(tasks, true)

    if not saphire.targets["clean"] then
      saphire.do_multi(tasks_after, true)
    end
  end
end

saphire.do_multi(routines, true)
