local r = (function()
-- probe: runtime capabilities needed by the new kernel
local out = {}
local function add(k, v) out[#out+1] = k .. "=" .. tostring(v) end

add("_VERSION", _VERSION)
-- 1) dynamic chunk loading (capability-pack hot load)
local f, err = load("return 1+1")
add("load", f and type(f) or ("ERR:" .. tostring(err)))
if f then add("load_result", f()) end
-- 2) load with env
local g = load("return X", "pack", "t", { X = 42 })
add("load_env", g and g() or "ERR")
-- 3) io / os availability
add("io_open", type(io) == "table" and type(io.open) or "nil")
add("os_time", type(os) == "table" and type(os.time) or "nil")
add("os_clock", type(os) == "table" and type(os.clock) or "nil")
-- 4) json lib
add("json", type(json))
-- 5) canvas/gc drawing primitives present on a dialog? (checked elsewhere)
add("app_version", app.version)
add("isGui", tostring(app.isUIAvailable))
-- 6) string.pack, utf8, table libs
add("utf8", type(utf8))
add("string_pack", type(string.pack))
add("require", type(require))
return table.concat(out, "\n")

end)()
local fh = io.open("D:\\PraticleTool\\Aseprite-AI\\tests\\lua\\_kernel_probe.out", "w")
fh:write(r)
fh:close()
