-- Bổ sung cho iamironz/android-nvim-plugin.
--
-- Plugin đoán applicationId bằng cách fallback về `namespace` trong
-- build.gradle.kts, sai với project khai applicationId ở chỗ khác (convention
-- plugin, flavor). Hậu quả: `am start` / `pm clear` / filter logcat trỏ vào
-- package không tồn tại, và `:AndroidBuild` bỏ qua luôn bước launch
-- ("launch skipped: app id required") mà vẫn báo deploy thành công.
--
-- File này lấy applicationId từ chính artifact build ra (output-metadata.json
-- của AGP, fallback aapt2) rồi vá vào các đường dùng nó, đồng thời thay item
-- "ADB install" trong menu bằng "ADB install & run".
--
-- Plugin cũng nhận diện module Android bằng cách tìm chuỗi
-- `com.android.application` trong build.gradle.kts, nên module dùng convention
-- plugin (`alias(libs.plugins.<...>.android.app)`) bị bỏ sót: danh sách run
-- config mất hết entry Android và menu tự nhảy sang iOS.
--
-- Ghim cứng package thì khai trong `.android.nvim.json`:
--   { "app": { "package": "com.example.app" } }
--
-- Lưu ý: dùng module nội bộ `android.*` nên có thể phải chỉnh khi update plugin.

local android_provider = require("android.run.providers.android")
local apk_build = require("android.build.apk")
local build_actions = require("android.actions.build")
local context = require("android.actions.context")
local defaults = require("android.actions.defaults")
local deploy = require("android.build.deploy")
local devices_adb = require("android.devices.adb")
local discovery = require("android.sdk.discovery")
local gradle_workspace = require("android.gradle.workspace")
local logcat_package = require("android.logcat.package")
local logcat_session = require("android.logcat.session")
local menu_items = require("android.ui.menu_items")
local project_config = require("android.project.config")
local registry = require("android.actions.registry")
local run_registry = require("android.run.registry")
local runner_module = require("android.command.runner")
local selection = require("android.state.selection_defaults")

local M = {}

local ACTION = {
  id = "adb_install_run",
  label = "ADB install & run",
  desc = "Install the APK and launch the app on the device",
}

local function blank(value)
  return value == nil or value == ""
end

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "Android" })
end

--- Thay `module[name]` bằng wrapper nhận hàm gốc, tối đa một lần.
local function patch(module, name, wrapper)
  local flag = "_android_custom_" .. name
  if module[flag] then
    return
  end
  module[name] = wrapper(module[name])
  module[flag] = true
end

--- applicationId trong output-metadata.json mà AGP ghi cạnh APK:
--- nguồn chuẩn nhất vì đã tính cả productFlavor lẫn applicationIdSuffix.
local function app_id_from_metadata(apk_path)
  local file = vim.fn.fnamemodify(apk_path, ":h") .. "/output-metadata.json"
  if vim.fn.filereadable(file) ~= 1 then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(file), "\n"))
  if not ok or type(decoded) ~= "table" or blank(decoded.applicationId) then
    return nil
  end
  return decoded.applicationId
end

--- `sdk.aapt2()` chỉ thấy build-tools do `sdkmanager --list` khai báo nên hay
--- trả nil; quét thẳng thư mục và lấy version cao nhất làm fallback.
local function find_aapt2(sdk)
  local path = sdk.aapt2()
  if not blank(path) then
    return path
  end
  local root = sdk.root and sdk.root()
  if blank(root) then
    return nil
  end
  local function version_key(candidate)
    local parts = {}
    for number in vim.fn.fnamemodify(candidate, ":h:t"):gmatch("%d+") do
      parts[#parts + 1] = string.format("%05d", tonumber(number))
    end
    return table.concat(parts, ".")
  end
  local candidates = vim.fn.glob(root .. "/build-tools/*/aapt2", false, true)
  table.sort(candidates, function(left, right)
    return version_key(left) < version_key(right)
  end)
  return candidates[#candidates]
end

--- applicationId thật của module/variant đang chọn; nil khi chưa build APK.
function M.resolve_app_id(workspace, opts)
  local options = opts or {}
  local root = type(workspace) == "table" and workspace.root or workspace
  if type(root) ~= "string" or blank(root) then
    return nil
  end

  local pinned = (project_config.load(root, {}).app or {}).package
  if not blank(pinned) then
    return pinned
  end

  local build = selection.build_defaults(options.state or context.load_state(root))
  if blank(build.module) or blank(build.variant) then
    return nil
  end

  local apk = apk_build.resolve_apk_path(root, build.module, build.variant)
  if not apk.ok then
    return nil
  end

  local app_id = app_id_from_metadata(apk.path)
  if app_id then
    return app_id
  end

  local aapt2 = find_aapt2(options.sdk or discovery.new({ root = root }))
  if not aapt2 then
    return nil
  end
  local resolved = deploy.resolve_app_id(apk.path, aapt2, options.runner)
  return resolved.ok and resolved.app_id or nil
end

local function deploy_error(result)
  local output = result.result or {}
  local detail = vim.trim(output.stderr or "")
  if detail == "" then
    detail = vim.trim(output.stdout or "")
  end
  local message = result.error or "Install & run failed"
  if detail ~= "" then
    message = message .. "\n" .. detail
  end
  return message
end

--- Install APK của module/variant đang chọn rồi launch app trên device đang chọn.
function M.install_and_run()
  local workspace = context.workspace()
  if not workspace then
    return notify("No Android/Gradle workspace found", vim.log.levels.WARN)
  end

  local sdk = discovery.new({ root = workspace.root })
  local adb_path = sdk.tools().adb
  if not adb_path then
    return notify("adb not found in Android SDK", vim.log.levels.WARN)
  end

  local runner = runner_module.new()
  local state = context.load_state(workspace.root)
  local serial = defaults.select_device_serial(
    devices_adb.list(runner, adb_path),
    selection.device_defaults(state).serial
  )
  if not serial then
    return notify("No adb devices found", vim.log.levels.WARN)
  end

  local build = selection.build_defaults(state)
  if blank(build.module) or blank(build.variant) then
    return notify("No default module/variant, pick one in :AndroidTargets", vim.log.levels.WARN)
  end

  local apk = apk_build.resolve_apk_path(workspace.root, build.module, build.variant)
  if not apk.ok then
    return notify(apk.error or "APK not found, build it first (:AndroidBuild)", vim.log.levels.WARN)
  end

  notify("Installing " .. vim.fn.fnamemodify(apk.path, ":t") .. " -> " .. serial)

  -- deploy đã được vá để tự resolve app id, ở đây chỉ cần đưa APK
  local result = deploy.deploy({
    adb_path = adb_path,
    device = serial,
    apk_path = apk.path,
    runner = runner,
  })
  if not result.ok then
    return notify(deploy_error(result), vim.log.levels.ERROR)
  end
  if result.warning then
    return notify("Installed, but " .. result.warning, vim.log.levels.WARN)
  end
  notify("Installed & launched " .. (result.app_id or build.module) .. " on " .. serial)
end

local function patch_registry()
  patch(registry, "run", function(original)
    return function(action_id, opts)
      if action_id == ACTION.id then
        return M.install_and_run()
      end
      return original(action_id, opts)
    end
  end)
end

-- Menu: "ADB install" -> "ADB install & run", và đặt lại tên "Build default"
-- cho khớp việc nó làm (build + install + launch).
local function patch_menu_items()
  local function relabel(blocks)
    for _, block in ipairs(blocks or {}) do
      for index, item in ipairs(block.items or {}) do
        if item.id == "adb_install" then
          block.items[index] = { id = ACTION.id, label = ACTION.label, desc = ACTION.desc }
        elseif item.id == "build_default" then
          item.label = "Build, install & run"
          item.desc = "Build, install and launch the app on the device"
        end
      end
    end
    return blocks
  end

  for _, name in ipairs({ "top_level_blocks", "top_level_blocks_fast" }) do
    patch(menu_items, name, function(original)
      return function(...)
        return relabel(original(...))
      end
    end)
  end
end

-- Logcat filter theo package. Vá cả resolver lẫn session.configure vì package
-- đã persist trong state được ưu tiên hơn giá trị resolver trả về.
local function patch_logcat()
  local plugin_guess = logcat_package.resolve_default_package

  patch(logcat_package, "resolve_default_package", function(original)
    return function(opts)
      local options = opts or {}
      local app_id = M.resolve_app_id(options.workspace or options.root, {
        runner = options.runner,
      })
      return app_id or original(opts)
    end
  end)

  patch(logcat_session, "configure", function(original)
    return function(session, opts)
      local options = opts or {}
      local app_id = M.resolve_app_id(options.workspace or options.root, {
        state = options.state,
        runner = options.runner,
      })
      local current = options.package
      if app_id and current ~= app_id then
        -- chỉ đè giá trị plugin tự đoán, giữ package bạn chọn tay bằng `gp`
        local auto = blank(current)
          or current == plugin_guess({
            workspace = options.workspace,
            root = options.root,
            runner = options.runner,
          })
        if auto then
          options = vim.tbl_extend("force", options, { package = app_id })
        end
      end
      return original(session, options)
    end
  end)
end

-- `actions/build.lua` gọi deploy với aapt2 nil và không có app_id nên launch bị
-- bỏ qua; điền sẵn hai giá trị đó cho mọi lời gọi deploy.
local function patch_deploy()
  patch(deploy, "deploy", function(original)
    return function(opts)
      local options = opts or {}
      if not blank(options.aapt2_path) and not blank(options.app_id) then
        return original(options)
      end

      local workspace = context.workspace()
      options = vim.tbl_extend("force", {}, options)
      if blank(options.aapt2_path) and workspace then
        options.aapt2_path = find_aapt2(discovery.new({ root = workspace.root }))
      end
      if blank(options.app_id) then
        options.app_id = app_id_from_metadata(options.apk_path or "")
          or M.resolve_app_id(workspace, { runner = options.runner })
      end
      return original(options)
    end
  end)
end

-- Quét lại module Android theo tên plugin dạng `...android.app...`, bù cho
-- marker `com.android.application` của plugin. Chỉ chạy khi provider gốc không
-- tìm thấy gì, nên cũng vượt qua được kết quả rỗng đã cache trong state.
local function applies_android_app_plugin(lines)
  local inside = false
  for _, line in ipairs(lines) do
    if inside then
      if line:find("^}") then
        return false
      end
      local text = line:lower()
      if not text:find("^%s*//") and text:find("android[%.%-_]?app") then
        return true
      end
    elseif line:find("^plugins%s*{") then
      inside = true
    end
  end
  return false
end

local function is_android_app_module(root, module)
  local dir = module:gsub("^:", ""):gsub(":", "/")
  for _, name in ipairs({ "build.gradle.kts", "build.gradle" }) do
    local path = root .. "/" .. dir .. "/" .. name
    if vim.fn.filereadable(path) == 1 then
      -- chỉ đọc block `plugins { ... }` ngoài cùng, tránh dính tên plugin khai
      -- trong gradlePlugin/dependencies của module build-logic
      return applies_android_app_plugin(vim.fn.readfile(path))
    end
  end
  return false
end

local function android_app_modules(root)
  local found = {}
  for _, module in ipairs(gradle_workspace.load_modules(root) or {}) do
    if is_android_app_module(root, module) then
      found[#found + 1] = module
    end
  end
  table.sort(found)
  return found
end

local function patch_android_provider()
  patch(android_provider, "detect", function(original)
    return function(workspace, state, opts)
      local configs = original(workspace, state, opts) or {}
      if #configs > 0 or not workspace or not workspace.android or blank(workspace.root) then
        return configs
      end
      local variant = selection.build_defaults(state).variant
      for _, module in ipairs(android_app_modules(workspace.root)) do
        configs[#configs + 1] = {
          id = "android" .. module,
          label = "Android " .. module,
          target = "android",
          type = "android",
          meta = { module = module, variant = variant },
        }
      end
      return configs
    end
  end)
end

-- Run config đang chọn mà không có trong danh sách thì registry ghi đè nó bằng
-- entry đầu tiên (iOS). Giữ lại lựa chọn đã lưu, chỉ ghi khi state chưa có gì.
local function patch_run_registry()
  local function keep_selection(workspace, opts)
    local options = opts or {}
    local root = workspace and workspace.root
    if options.persist ~= nil or blank(root) then
      return options
    end
    if blank((context.load_state(root).run or {}).config_id) then
      return options
    end
    return vim.tbl_extend("force", options, { persist = false })
  end

  for _, name in ipairs({ "snapshot", "resolve" }) do
    patch(run_registry, name, function(original)
      return function(workspace, opts)
        return original(workspace, keep_selection(workspace, opts))
      end
    end)
  end
end

function M.setup()
  patch_registry()
  patch_menu_items()
  patch_logcat()
  patch_deploy()
  patch_android_provider()
  patch_run_registry()

  vim.api.nvim_create_user_command("AndroidInstallRun", function()
    M.install_and_run()
  end, { desc = ACTION.desc })

  vim.api.nvim_create_user_command("AndroidBuildRun", function()
    build_actions.build_default()
  end, { desc = "Build, install and launch the app on the device" })
end

return M
