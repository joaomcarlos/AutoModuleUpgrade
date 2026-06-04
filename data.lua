data:extend({
  {
    type = "shortcut",
    name = "amu_toggle_scan_window",
    action = "lua",
    order = "a[uto]-m[odule]",
    icon = "__base__/graphics/icons/inserter.png",
    icon_size = 64,
    small_icon = "__base__/graphics/icons/inserter.png",
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
