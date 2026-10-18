/** 在真 Aseprite 里跑 lib/ops.lua 的 ops.manifest()，把结果编成 JSON 文本。
 *  被 test/gen-manifest.mjs（生成）和 test/smoke.mjs（校验清单是否过期）共用。 */
import { runLua } from '../lib/runner.js';

export const MANIFEST_LUA = `
local ops = require("lib.ops")
local function esc(s)
  s = tostring(s)
  s = s:gsub("\\\\", "\\\\\\\\"):gsub('"', '\\\\"'):gsub("\\n", "\\\\n")
  s = s:gsub("\\r", "\\\\r"):gsub("\\t", "\\\\t")
  return s
end
local enc
enc = function(v)
  local t = type(v)
  if t == "string" then return '"' .. esc(v) .. '"' end
  if t == "number" or t == "boolean" then return tostring(v) end
  if t == "table" then
    local n, isArray = 0, true
    for k in pairs(v) do n = n + 1; if type(k) ~= "number" then isArray = false end end
    if isArray and n == #v then
      local parts = {}
      for i = 1, #v do parts[#parts + 1] = enc(v[i]) end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}
    for k in pairs(v) do if type(k) == "string" then keys[#keys + 1] = k end end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = '"' .. esc(k) .. '":' .. enc(v[k]) end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return "null"
end
OUT = enc(ops.manifest())
`;

export async function computeManifest(cfg) {
  const r = await runLua(cfg, MANIFEST_LUA);
  if (!r.ok) throw new Error('ops.manifest() failed: ' + r.text);
  return JSON.parse(r.text);
}
