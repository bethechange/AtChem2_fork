-- -*- lua -*-
whatis("Name: atchem2")
whatis("Version: 1.0")
whatis("Description: AtChem2 runtime stack (installed via env/install/install_atchem2.sh)")

help([[
AtChem2 runtime.
Installed prefix: /home/s/IPTL/Ubuntu/AtChem2_fork/atchem-lib

This module does NOT set per-user input/output roots.
Set ATCHEM_INPUT_ROOT / ATCHEM_OUTPUT_ROOT yourself
(e.g., in ~/.config/atchem2/config, a project .envrc, or a small overlay module).
]])

family("atchem2")  -- avoid mixing multiple atchem2 stacks

local prefix   = "/home/s/IPTL/Ubuntu/AtChem2_fork/atchem-lib"
local gem_home = "/home/s/IPTL/Ubuntu/AtChem2_fork/.gem"
local shims    = "/home/s/IPTL/Ubuntu/AtChem2_fork/env/shims"

setenv("ATCHEM_LIB",   prefix)
setenv("CVODELIBDIR",  pathJoin(prefix, "cvode/lib"))
setenv("OPENLIBMDIR",  pathJoin(prefix, "openlibm"))
setenv("FRUITDIR",     pathJoin(prefix, "fruit_3.4.3"))

prepend_path("PATH", pathJoin(prefix,   "numdiff/bin"))
prepend_path("PATH", pathJoin(gem_home, "bin"))
prepend_path("PATH", shims)

-- gentle warnings if something is missing (non-fatal)
local function exists_dir(p)
  local rc = os.execute('[ -d "'..p..'" ] > /dev/null 2>&1')
  if type(rc) == "number" then return rc == 0 else return rc == true end
end

if (mode() == "load") then
  if not exists_dir(pathJoin(prefix, "cvode", "lib")) then
    LmodMessage("[atchem2/1.0] Warning: CVODE not found under "..pathJoin(prefix, "cvode", "lib"))
  end
  if not exists_dir(pathJoin(prefix, "openlibm")) then
    LmodMessage("[atchem2/1.0] Warning: OpenLibm not found under "..pathJoin(prefix, "openlibm"))
  end
  if not exists_dir(pathJoin(prefix, "fruit_3.4.3")) then
    LmodMessage("[atchem2/1.0] Warning: FRUIT not found under "..pathJoin(prefix, "fruit_3.4.3"))
  end
end
