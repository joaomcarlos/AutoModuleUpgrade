require("data/style")
require("data/sprites")

data:extend({
  {
    type = "shortcut",
    name = "amu_toggle_scan_window",
    action = "lua",
    order = "a[uto]-m[odule]",
    icon = "__AutoModuleUpgrade__/graphics/icons/amu_shortcut.png",
    icon_size = 64,
    small_icon = "__AutoModuleUpgrade__/graphics/icons/amu_shortcut.png",
    small_icon_size = 64,
    toggleable = true,
    associated_control_input = "amu_toggle_scan_window",
  },
  {
    type = "custom-input",
    name = "amu_toggle_scan_window",
    key_sequence = "SHIFT + U",
    consuming = "none",
  }
})
