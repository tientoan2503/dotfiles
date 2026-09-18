return {
  {
    "iamironz/android-nvim-plugin",
    lazy = false,
    config = function()
      require("android").setup()

      require("config.android_custom").setup()

      vim.keymap.set("n", "<leader>ai", "<cmd>AndroidInstallRun<cr>", {
        silent = true,
        desc = "Android install & run",
      })
    end,
  },
}
