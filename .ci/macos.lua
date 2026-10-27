local BREW_PACKAGES = "jj luajit bats-core shellcheck shfmt stylua selene ast-grep jq yq stow ripgrep fd sd"

return {
  jobs = {
    test = {
      matrix = { { target = "macos-rust" } },
      run = function()
        ci.sh("HOMEBREW_NO_AUTO_UPDATE=1 brew install --quiet " .. BREW_PACKAGES)
        ci.sh("./dotfiles/bin/.local/bin/dev test </dev/null")
      end,
    },
  },
}
