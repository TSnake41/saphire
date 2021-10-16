local c = require "saphire-c"

local objsac = c.compile({
  { "a.o", { "a.c" } },
  { "c.o", { "c.c" } }
})

local objsb = c.compile({
  { "b.o", { "b.c" } },
})

local archive1 = c.lib("libac.a", objsac)
local archive2 = c.lib("libb.a", objsb)
local archive3 = c.lib("libabc.a", { archive1, archive2 })
local lib = c.link("libabc.so", { archive1, archive2 }, nil, true)
