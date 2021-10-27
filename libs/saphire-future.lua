--[[
  Basic future implementation for saphire.
]]

local saphire = require "saphire"

---@class Future
---@field [1] any #Initial value
---@field completed boolean
---@field failed boolean
local Future = {}
setmetatable(Future, Future)

-- Create a new future.
---@param val any
---@return Future
function Future:__call(val)
  return setmetatable({ val, completed = false, failed = false }, Future)
end

function Future:__index(k)
  return rawget(Future, k)
end

function Future:__tostring()
  return "Future"
end

-- Wrap a function into a thread, and resolve the future at the thread.
-- Function f may yield.
local function future_wrapper(future, f)
  coroutine.yield() -- don't start routine yet

  -- NOTE: this requires pcall to be able to yield accross coroutines,
  -- which is not yet possible with PUC-Rio Lua, even if it is supported
  -- by LuaJIT.
  local status, obj = pcall(f)

  if status then
    future:resolve(obj)
  else
    saphire.messages[#saphire.messages + 1] = string.format("\x1B[31merr: Future wrapper failure : %s\x1B[0m", obj)
    future:reject(obj)
  end
end

-- Wrap a function into the future, function completion will resolve the future.
---@param f function
---@return Future
function Future:wrap_function(f)
  local co = coroutine.create(future_wrapper)
  coroutine.resume(co, self, f)

  saphire.routines[#saphire.routines + 1] = co

  -- Inherit cwd from current routine.
  saphire.routines_cwd[co] = saphire.routines_cwd[coroutine.running()]

  return self
end

-- Cast `self` into a future, needs self to have the same shape
-- as a future (e.g unstarted task), does nothing if self is already
-- a future.
---@return Future
function Future:into_future()
  setmetatable(self, Future)

  if rawget(self, "completed") == nil then
    self.completed = false
  end
  if rawget(self, "failed") == nil then
    self.failed = false
  end

  return self
end

-- Resolve a future, making it completed with `value`.
function Future:resolve(value)
  if value then
    self[1] = value
  end

  self.completed = true
  self.failed = false
end

function Future:reject(message)
  self.completed = true
  self.failed = true
  self.message = message
end

-- Wait for future completion, returns completion value.
---@return any
function Future:wait()
  if getmetatable(self) ~= Future then
    -- self is not a future, nothing to do
    return self
  end

  repeat
    coroutine.yield()
  until self.completed

  return self[1]
end

function Future:is_future()
  return getmetatable(self) == Future
end

-- Wait for multiple futures
---@param list Future[]
function Future.wait_all(list)
  repeat
    local ready = true

    for i,v in ipairs(list) do
      if type(v) == "table" and not v.completed then
        ready = false
        break
      end
    end

    if not ready then
      coroutine.yield()
    end
  until ready
end

return Future