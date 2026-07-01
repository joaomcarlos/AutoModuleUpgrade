require("data/style")
require("data/sprites")

data:extend({
  {
    type = "tips-and-tricks-item-category",
    name = "amu",
    order = "z[amu]"
  },
  {
    type = "tips-and-tricks-item",
    name = "amu-overview",
    category = "amu",
    order = "a",
    starting_status = "unlocked",
    is_title = true,
    icon = "__AutoModuleUpgrade__/graphics/icons/amu_shortcut.png",
    icon_size = 64
  },
  {
    type = "selection-tool",
    name = "amu-selection-tool",
    icon = "__AutoModuleUpgrade__/graphics/icons/amu_shortcut.png",
    icon_size = 64,
    flags = {"only-in-cursor", "not-stackable", "spawnable"},
    subgroup = "tool",
    order = "c[automated-construction]-z[amu-selection-tool]",
    stack_size = 1,
    select = {
      border_color = {0.2, 1, 0.2},
      mode = {"buildable-type", "same-force"},
      cursor_box_type = "copy"
    },
    alt_select = {
      border_color = {1, 0.25, 0.25},
      mode = {"buildable-type", "same-force"},
      cursor_box_type = "not-allowed"
    },
    reverse_select = {
      border_color = {0.3, 0.7, 1},
      mode = {"buildable-type", "same-force"},
      cursor_box_type = "entity"
    },
    alt_reverse_select = {
      border_color = {1, 0.85, 0.2},
      mode = {"buildable-type", "same-force"},
      cursor_box_type = "pair"
    }
  },
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
    type = "shortcut",
    name = "amu_get_selection_tool",
    action = "spawn-item",
    item_to_spawn = "amu-selection-tool",
    order = "a[uto]-m[odule]-b[selection]",
    icon = "__AutoModuleUpgrade__/graphics/icons/amu_shortcut.png",
    icon_size = 64,
    small_icon = "__AutoModuleUpgrade__/graphics/icons/amu_shortcut.png",
    small_icon_size = 64,
    associated_control_input = "amu_get_selection_tool"
  },
  {
    type = "custom-input",
    name = "amu_toggle_scan_window",
    key_sequence = "SHIFT + U",
    consuming = "none",
  },
  {
    type = "custom-input",
    name = "amu_get_selection_tool",
    key_sequence = "ALT + U",
    consuming = "none",
  }
})
