return {
  {
    "iamironz/android-nvim-plugin",
    lazy = false,
    config = function()
      require("android").setup()

      require("config.android_custom").setup()

      vim.keymap.set("n", "<leader>ab", "<cmd>AndroidInstallRun<cr>", {
        silent = true,
        desc = "Android install & run",
      })

      vim.keymap.set("n", "<leader>ai", "<cmd>AndroidIOSDeploy<cr>", {
        silent = true,
        desc = "iOS install & run",
      })
    end,
  },
}
