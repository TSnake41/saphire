--[[
  C building toolkit for saphire, tries it best to parallelize builds without making it hard to use.
]]

local saphire = require "saphire"
local c = {}

function c.src(src, recipe)
  recipe()

  return src
end
c.obj = c.src -- same behavior

local function build_c(src, obj, name, flags, cc)
  if saphire.targets.clean then
    return {
      command = "rm -f " .. obj,
      name = name
    }
  end

  return {
    command = string.format("%s -fdiagnostics-color=always -c -o %s %s %s", cc or "cc", obj, src, flags or ""),
    name = name,
    display = obj
  }
end

function c.compile(srcs, flags, name, cc)
  flags = flags or ""

  local tasks = saphire.map(srcs, function (src)
    -- This function generates tasks that are then fed into do_multi.
    if type(src) == "string" then
      src = { src .. ".o", { src } }
    end

    -- { obj, {src, [deps...], [flags = "someflags"] } }
    local obj, srcs = unpack(src)

    local task = build_c(srcs[1], obj, name, flags .. " " .. srcs.flags, cc)
    local need_build = true

    if not saphire.targets.cleanup then
      -- Force task
      need_build = true
    else
      -- Do task only if target is older than source.
      saphire.do_recipe(srcs, obj, function ()
        need_build = true
      end)
    end

    return need_build and task or function () end
  end)

  saphire.do_multi(tasks)

  return saphire.map(srcs, function (src, i)
    local task = tasks[i] -- task corresponding to src
    if type(task) ~= "table" then
      -- This is "function" indicating that the target doesn't
      -- need to be built, use a table that represent a completed task
      task = { completed = true }
    end

    return { src[1], task }
  end)
end

function c.res(rc, deps, name, windres)
  local res = rc .. ".res"

  local task
  if saphire.targets.cleanup then
    task = {
      command = string.format("rm -f %s", res),
      name = name,
    }
  else
    task = {
      command = string.format("%s %s -O coff %s", windres or "windres", rc, res),
      name = name,
      display = res
    }
  end

  if saphire.targets.cleanup then
    saphire.do_single(task)
  else
    saphire.do_recipe(saphire.merge(rc, deps), res, task)
  end

  return { res, task }
end

function c.lib(lib, source, name, ar)
  local self = { lib, { completed = false } }

  -- Defer library building to another coroutine
  local co = coroutine.create(function ()
    -- Wait until all tasks of source are completed
    repeat
      local ready = true

      for i,v in ipairs(source) do
        if type(v) == "table" and not v.completed then
          ready = false
          break
        end
      end

      if not ready then
        coroutine.yield()
      end
    until ready

    -- source[i]: { obj, task } or string
    local objs = saphire.map(source, function (s)
      return type(s) == "table" and s[1] or s
    end)

    -- All tasks are done, we can build the library
    local task = {}
    if saphire.targets.clean then
      task = {
        command = "rm -f " .. lib,
        name = name
      }
    else
      task = {
        command = string.format("%s rcs %s %s", ar or "ar", lib, table.concat(objs, " ")),
        name = name
      }
    end

    if saphire.targets.cleanup then
      saphire.do_single(task, true)
    else
      saphire.do_recipe(objs, lib, task, true)
    end

    self[2].completed = true
  end)

  saphire.routines[#saphire.routines + 1] = co

  -- Inherit cwd from current routine.
  saphire.routines_cwd[co] = saphire.routines_cwd[coroutine.running()]

  return self
end

function c.link(exe, source, flags, shared, name, ld)
  local self = { exe, { completed = false } }

  -- Defer library building to another coroutine
  local co = coroutine.create(function ()
    -- Wait until all tasks of source are completed
    repeat
      local ready = true

      for i,v in ipairs(source) do
        if type(v) == "table" and not v.completed then
          ready = false
          break
        end
      end

      if not ready then
        coroutine.yield()
      end
    until ready

    -- source[i]: { obj, task } or string
    local objs = saphire.map(source, function (s)
      return type(s) == "table" and s[1] or s
    end)

    -- All tasks are done, we can now link
    local task = {}
    if saphire.targets.clean then
      task = {
        command = "rm -f " .. exe,
        name = name
      }
    else
      task = {
        command = string.format("%s -fdiagnostics-color=always %s -o %s %s %s",
          ld or "cc",
          shared and "-shared" or "",
          flags or "",
          table.concat(objs, " ")),
        name = name,
        display = exe
      }
    end

    if saphire.targets.cleanup then
      saphire.do_single(task, true)
    else
      saphire.do_recipe(objs, exe, task, true)
    end

    self[2].completed = true
  end)

  saphire.routines[#saphire.routines + 1] = co

  -- Inherit cwd from current routine.
  saphire.routines_cwd[co] = saphire.routines_cwd[coroutine.running()]

  return self
end

return c