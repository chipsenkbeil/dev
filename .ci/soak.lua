-- Loop the signal tests beside CPU burners on the Arch box

local PACMAN_PACKAGES = "git jujutsu luajit bats dash stow ripgrep fd sd man-db zsh unzip util-linux"

return {
  jobs = {
    soak = {
      name = "soak on ${target}",
      matrix = { { target = "linux-x86-rust" } },
      run = function()
        ci.sh("missing=$(pacman -T " .. PACMAN_PACKAGES .. ") || sudo pacman -Syu --noconfirm --needed $missing", { name = "install packages" })
        ci.sh({ "./dotfiles/bin/.local/bin/dev", "soak", table.unpack(ci.args) }, { name = "soak" })
      end,
    },
  },
}
