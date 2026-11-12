local BREW_PACKAGES = "jj luajit bats-core jq yq stow sd"

local BATS_SUITES = {
  "tests/dev/confirm.bats",
  "tests/dev/picker.bats",
  "tests/dev/term.bats",
}

local SCRIPT_SUITES = {
  "tests/bin/pinentry_auto_test.sh",
  "tests/dev/bootstrap_test.sh",
  "tests/dev/launcher_test.sh",
  "tests/zsh/homebrew_path_test.sh",
}

local LUA_SUITES = {
  "tests/lua/mac_test.lua",
  "tests/lua/os_test.lua",
  "tests/lua/steps_test.lua",
  "tests/lua/term_test.lua",
}

return {
  jobs = {
    test = {
      name = "test on ${target} (${arch})",
      matrix = { { target = "macos-vm-rust", arch = "aarch64" } },
      run = function()
        ci.sh("HOMEBREW_NO_AUTO_UPDATE=1 brew install --quiet " .. BREW_PACKAGES, { name = "install packages" })
        for _, file in ipairs(BATS_SUITES) do
          ci.sh("bats --tap " .. file .. " </dev/null", { name = "test " .. file })
        end
        for _, file in ipairs(SCRIPT_SUITES) do
          ci.sh("bash " .. file .. " </dev/null", { name = "test " .. file })
        end
        for _, file in ipairs(LUA_SUITES) do
          ci.sh("luajit tests/lua/run.lua " .. file .. " </dev/null", { name = "test " .. file })
        end
      end,
    },
  },
}
