local PACMAN_PACKAGES = "git jujutsu luajit bats shellcheck shfmt stylua selene ast-grep jq go-yq dash stow ripgrep fd sd man-db zsh unzip"
local ROOT_CLONE = "/root/dotfiles"

local function prepare()
  ci.sh("missing=$(pacman -T " .. PACMAN_PACKAGES .. ") || sudo pacman -Syu --noconfirm --needed $missing")
end

return {
  jobs = {
    lint = {
      matrix = { { target = "linux-x86-dev", shape = "small" } },
      run = function()
        prepare()
        ci.sh("./dotfiles/bin/.local/bin/dev lint </dev/null")
      end,
    },
    test = {
      matrix = { { target = "linux-x86-rust" } },
      run = function()
        prepare()
        ci.sh("./dotfiles/bin/.local/bin/dev test </dev/null")
        ci.group("real root", function()
          ci.sh("sudo rm -rf " .. ROOT_CLONE .. " && sudo cp -a \"$PWD\" " .. ROOT_CLONE)
          ci.sh("sudo chown -R root:root " .. ROOT_CLONE .. " && sudo chmod -R go-w " .. ROOT_CLONE)
          ci.sh("sudo bash -c 'cd " .. ROOT_CLONE .. " && bash tests/dev/root_test.sh </dev/null'")
          ci.sh("sudo bash -c 'cd " .. ROOT_CLONE .. " && bash tests/dev/tools_test.sh </dev/null'")
        end)
      end,
    },
  },
}
