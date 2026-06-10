local styles = data.raw["gui-style"].default
local icon_path = "__AutoModuleUpgrade__/graphics/icons/"

styles.amu_scan_window_frame = {
  type = "frame_style",
  parent = "frame",
  minimal_width = 430,
  maximal_width = 720,
  padding = 0
}

styles.amu_scan_title_label = {
  type = "label_style",
  parent = "frame_title",
  left_padding = 8,
  top_padding = 3,
  bottom_padding = 3
}

styles.amu_scan_content_frame = {
  type = "frame_style",
  parent = "inside_shallow_frame",
  padding = 0,
  top_margin = 0
}

styles.amu_scan_scroll_pane = {
  type = "scroll_pane_style",
  parent = "naked_scroll_pane",
  extra_padding_when_activated = 0,
  padding = 0,
  horizontally_stretchable = "on"
}

styles.amu_scan_table = {
  type = "table_style",
  parent = "table",
  horizontal_spacing = 8,
  vertical_spacing = 3,
  horizontally_stretchable = "on"
}

styles.amu_scan_row_flow = {
  type = "horizontal_flow_style",
  horizontal_spacing = 8,
  vertical_align = "center"
}

styles.amu_scan_planet_cell = {
  type = "horizontal_flow_style",
  width = 41,
  horizontal_align = "center",
  vertical_align = "center"
}

styles.amu_scan_header_row_frame = {
  type = "frame_style",
  parent = "frame",
  graphical_set = {base = {filename = icon_path .. "amu_header_row_bg.png", width = 452, height = 31}},
  horizontal_flow_style = styles.amu_scan_row_flow,
  width = 452,
  height = 31,
  padding = 0
}

styles.amu_scan_data_row_frame = {
  type = "frame_style",
  parent = "frame",
  graphical_set = {base = {filename = icon_path .. "amu_data_row_bg.png", width = 452, height = 31}},
  horizontal_flow_style = styles.amu_scan_row_flow,
  width = 452,
  height = 31,
  padding = 0
}

styles.amu_scan_header_label = {
  type = "label_style",
  parent = "bold_label",
  font_color = {0.9, 0.9, 0.9},
  horizontal_align = "center"
}

styles.amu_scan_cell_label = {
  type = "label_style",
  parent = "label",
  font = "default-small",
  font_color = {0.9, 0.9, 0.9},
  horizontal_align = "right"
}

styles.amu_scan_status_label = {
  type = "label_style",
  parent = "amu_scan_cell_label",
  horizontal_align = "left"
}

styles.amu_scan_time_label = {
  type = "label_style",
  parent = "amu_scan_cell_label",
  minimal_width = 40
}

styles.amu_scan_planet_sprite = {
  type = "image_style",
  parent = "image",
  width = 26,
  height = 26,
  stretch_image_to_widget_size = true,
  padding = 0
}

styles.amu_scan_row_button = {
  type = "button_style",
  parent = "button",
  default_graphical_set = {},
  hovered_graphical_set = {},
  clicked_graphical_set = {},
  disabled_graphical_set = {},
  width = 26,
  height = 26,
  padding = 0
}

styles.amu_scan_title_button = {
  type = "button_style",
  parent = "button",
  default_graphical_set = {},
  hovered_graphical_set = {},
  clicked_graphical_set = {},
  disabled_graphical_set = {},
  width = 32,
  height = 32,
  padding = 0
}
