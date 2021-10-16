local saphire = require "saphire"

local Chain = {}
setmetatable(Chain, Chain)

function Chain.__call()
  return setmetatable({ stack = {} }, Chain)
end

function Chain:next(task)
  self.stack[#self.stack + 1] = task

  return self
end

function Chain:done(wait)
  if wait then
    local co = coroutine.create(function ()
      self:end_chain(false)
    end)

    saphire.routines[#saphire.routines+1] = co
    saphire.routines_cwd[co] = saphire.routines_cwd[coroutine.running()]
  else
    for _,t in ipairs(self.stack) do
      saphire.do_single(t, true)
    end
  end
end

return Chain