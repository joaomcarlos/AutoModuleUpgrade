local icon_path = "__AutoModuleUpgrade__/graphics/icons/"

local function icon(name, size)
  size = size or 26
  return {
    type = "sprite",
    name = name,
    filename = icon_path .. name .. ".png",
    priority = "extra-high-no-scale",
    width = size,
    height = size
  }
end

data:extend({
  icon("amu_plus"),
  icon("amu_close"),
  icon("amu_close_disabled"),
  icon("amu_search"),
  icon("amu_search_disabled"),
  icon("amu_clock"),
  icon("amu_log_on"),
  icon("amu_log_off"),
  icon("amu_check"),
  icon("amu_camera_on"),
  icon("amu_camera_off"),
  icon("amu_title_plus_button", 32),
  icon("amu_title_log_button", 32),
  icon("amu_title_close_button", 32),
  icon("amu_row_search_button"),
  icon("amu_row_search_disabled_button"),
  icon("amu_row_close_button"),
  icon("amu_clock_header", 23),
  icon("amu_planet_header"),
  icon("amu_planet_nauvis"),
  icon("amu_planet_vulcanus"),
  icon("amu_planet_gleba"),
  icon("amu_planet_fulgora"),
  icon("amu_planet_aquilo")
})
