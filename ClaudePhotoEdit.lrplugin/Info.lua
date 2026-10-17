--[[
  Claude AI Photo Edit for Lightroom Classic
  Info.lua — Plugin manifest
--]]

return {

    LrSdkVersion        = 6.0,
    LrSdkMinimumVersion = 6.0,

    LrToolkitIdentifier = 'net.advertize.claudephotoedit',
    LrPluginName        = LOC '$$$/ClaudePhotoEdit/PluginName=Claude AI Photo Edit',
    LrPluginInfoUrl     = 'https://advertize.net',

    LrExportMenuItems = {
        {
            title       = LOC '$$$/ClaudePhotoEdit/Menu/Edit=Edit with Claude AI',
            file        = 'ClaudeEdit.lua',
            enabledWhen = 'photosSelected',
        },
        {
            title = LOC '$$$/ClaudePhotoEdit/Menu/Settings=Claude Edit Settings\226\128\166',
            file  = 'SettingsDialog.lua',
        },
    },

    VERSION = { major = 1, minor = 1, revision = 0, build = 1 },
}
