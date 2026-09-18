-- kmp-lsp — https://github.com/Hessesian/kmp-lsp
--
-- LSP server viết bằng Rust, dựa trên tree-sitter, không cần JVM.
-- Binary cài qua install.sh vào ~/.local/bin (kèm sidecar kmp-jar-indexer
-- để đọc type từ JAR: Compose, AndroidX, Kotlin stdlib).
--
-- Không đi qua Mason: package `kmp-lsp` trong mason registry không khai báo
-- `neovim.lspconfig` nên mason-lspconfig không map được tên server.
-- Vì vậy `mason = false` và LazyVim sẽ gọi thẳng vim.lsp.enable("kmp_lsp").
--
-- Lưu ý: kmp-lsp chỉ báo lỗi cú pháp từ tree-sitter, KHÔNG type-check.
return {
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        kmp_lsp = {
          mason = false,
          cmd = { "kmp-lsp" },
          filetypes = { "kotlin", "java", "swift" },
          root_markers = {
            "settings.gradle.kts",
            "settings.gradle",
            "build.gradle.kts",
            "build.gradle",
            "pom.xml",
            "Package.swift",
            ".git",
          },
        },
      },
    },
  },
}
