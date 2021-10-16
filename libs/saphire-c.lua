--[[
  C building toolkit for saphire, tries its best to parallelize builds without making it hard to use.
]]

local saphire = require "saphire"
local Future = require "saphire-future"
local c = {}

function c.src(src, recipe)
  if type(recipe) == "function" then
    local future = Future(src)
    future:wrap_function(recipe)
    return future
  elseif type(recipe) == "table" then  -- recipe is a task
    recipe[1] = src
    coroutine.yield(recipe)
    return recipe
  else
    error "Unknown recipe"
  end
end

local function build_c(src, obj, name, flags, cc)
  if saphire.targets.clean then
    return {
      command = "rm -f " .. obj,
      name = name
    }
  else
    name = name and ("cc." .. name) or "cc"

    return {
      command = string.format("%s -fdiagnostics-color=always -c -o %s %s %s", cc or "cc", obj, src, flags or ""),
      name = name,
      display = obj
    }
  end
end

function c.compile(srcs, flags, name, cc)
  flags = flags or ""

  local futures = saphire.map(srcs, function (src)
    src = Future.wait(src) -- wait src if src is a future

    if type(src) == "string" then
      src = { src .. ".o", { src } }
    end

    -- { obj, {src, [deps...], [flags = "someflags"] } }
    local obj, deps = unpack(src)
    local deps_flags = deps.flags or ""

    local task = build_c(deps[1], obj, name, flags .. " " .. deps_flags, cc)
    Future.into_future(task)
    task[1] = obj

    if saphire.targets.clean then
      -- Force task
      coroutine.yield(task)
    else
      -- Do task only if target is older than source.
      saphire.do_recipe(deps, obj, task)
    end
  
    return task
  end)

  return futures
end

function c.res(rc, deps, name, windres)
  local res = rc .. ".res"

  if type(deps) == "string" then
    deps = { deps }
  end

  local task
  if saphire.targets.clean then
    task = {
      command = string.format("rm -f %s", res),
      name = name,
    }
  else
    name = name and ("res." .. name) or "res"
    task = {
      command = string.format("%s %s -O coff %s", windres or "windres", rc, res),
      name = name,
      display = res
    }
  end
  task[1] = res

  if saphire.targets.clean then
    coroutine.yield(task)
  else
    saphire.do_recipe(rc, saphire.merge({ rc }, deps), task)
  end

  return task
end

function c.lib(lib, source, name, ar)
  local self = Future(lib)

  self:wrap_function(function ()
    local objs = saphire.map(source, function (s)
      return Future.wait(s) -- ok in case s is not a future
    end)

    -- All tasks are done, we can build the library
    local task = {}
    if saphire.targets.clean then
      task = {
        command = "rm -f " .. lib,
        name = name
      }
    else
      name = name and ("ar." .. name) or "ar"
      task = {
        command = string.format("%s rcs %s %s", ar or "ar", lib, table.concat(objs, " ")),
        name = name
      }
    end

    if saphire.targets.clean then
      saphire.do_single(task, true)
    else
      saphire.do_recipe(objs, lib, task, true)
    end
  end)

  return self
end

function c.link(exe, source, flags, shared, name, ld)
  local self = Future(exe)

  -- Defer library building to another coroutine
  self:wrap_function(function ()
    local objs = saphire.map(source, function (s)
      return Future.wait(s) -- ok in case s is not a future
    end)

    -- All tasks are done, we can now link
    local task = {}
    if saphire.targets.clean then
      task = {
        command = "rm -f " .. exe,
        name = name
      }
    else
      name = name and ("ld." .. name) or "ld"
      task = {
        command = string.format("%s -fdiagnostics-color=always %s -o %s %s %s",
          ld or "cc",
          shared and "-shared" or "",
          exe,
          table.concat(objs, " "),
          flags or ""
        ),
        name = name,
        display = exe
      }
    end

    if saphire.targets.clean then
      saphire.do_single(task, true)
    else
      saphire.do_recipe(objs, exe, task, true)
    end
  end)

  return self
end

return c