data:extend({
  {
    type = "bool-setting",
    name = "amu-scan-planets",
    setting_type = "runtime-global",
    default_value = true,
    order = "a[scan]-a[planets]",
  },
  {
    type = "bool-setting",
    name = "amu-scan-space-platforms",
    setting_type = "runtime-global",
    default_value = true,
    order = "a[scan]-b[space-platforms]",
  },
})
