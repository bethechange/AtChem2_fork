-- -*- lua -*-
whatis("Name: atchem2/v#.lua")
whatis("Version: 1.0")
whatis("Description: Environment for AtChem2; installation handled by env/setup_system.sh")

-- Resolve repo root from this file path: .../env/modules/atchem2/1.1.lua
local hasMyFileName = (type(myFileName) == "function")
local modfile = hasMyFileName and myFileName() or pathJoin(myModulePath(), myModuleVersion() or "")
local moddir  = pathJoin(modfile, "..")                       -- .../env/modules/atchem2
local src_dir = pathJoin(moddir, "..","..","..")              -- repo root
local proj_root = src_dir

-- Prefixes
local atchem_lib = pathJoin(proj_root, "atchem-lib")
local gem_home   = pathJoin(proj_root, ".gem")
local shims_dir  = pathJoin(proj_root, "env", "shims")

-- Only change env on real load (not during spider/avail)
if (mode() == "load") then
  setenv("ATCHEM_LIB",   atchem_lib)
  setenv("GEM_HOME",     gem_home)
  setenv("CVODELIBDIR",  pathJoin(atchem_lib, "cvode/lib"))
  setenv("OPENLIBMDIR",  pathJoin(atchem_lib, "openlibm"))
  setenv("FRUITDIR",     pathJoin(atchem_lib, "fruit_3.4.3"))

  prepend_path("PATH", pathJoin(gem_home,   "bin"))
  prepend_path("PATH", pathJoin(atchem_lib, "numdiff/bin"))
  prepend_path("PATH", shims_dir)

  -- Light hints if something is missing (non-fatal)
  local function exists_dir(p)
    local rc = os.execute('[ -d "'..p..'" ] > /dev/null 2>&1')
    if type(rc) == "number" then return rc == 0 else return rc == true end
  end
  if not exists_dir(pathJoin(atchem_lib, "cvode", "lib")) then
    LmodMessage("[atchem2] CVODE not found under "..pathJoin(atchem_lib, "cvode", "lib")..". Run: env/setup_system.sh")
  end
  if not exists_dir(pathJoin(atchem_lib, "openlibm")) then
    LmodMessage("[atchem2] OpenLibm not found under "..pathJoin(atchem_lib, "openlibm")..". Run: env/setup_system.sh")
  end
  if not exists_dir(pathJoin(atchem_lib, "fruit_3.4.3")) then
    LmodMessage("[atchem2] FRUIT not found under "..pathJoin(atchem_lib, "fruit_3.4.3")..". Run: env/setup_system.sh")
  end
end
