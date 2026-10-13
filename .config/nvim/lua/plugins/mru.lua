return {
  "aikawa9376/mru.nivm",
  event = { "BufReadPre", "BufNewFile" },
  cmd = {
    "Mru", "Mrw", "MruSave", "MruReload", "MruMigrate", "MruRename",
    "MruImportFile", "MruImportWrite", "MruImportDirectory",
    "NeoMRUSave", "NeoMRUReload",
  },
}
