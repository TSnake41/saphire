return {
  name = "saphire",
  version = "0.1",
  luvi = { },
  files = {
    "*.lua",
    "LICENCE",
    "lib/**"
  },
  dependencies = {
    "luvit/process",
    "luvit/require",
    "luvit/los",
    "luvit/json",
    "luvit/https",
    "luvit/http",
    "creationix/coro-fs",
  }
}
