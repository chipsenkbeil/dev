-- Loop the signal tests beside CPU burners on the Arch box

local PACMAN_PACKAGES = "git jujutsu luajit bats dash stow ripgrep fd sd man-db zsh unzip util-linux"

return {
  jobs = {
    soak = {
      matrix = { { target = "linux-x86-rust" } },
      run = function()
        ci.sh("missing=$(pacman -T " .. PACMAN_PACKAGES .. ") || sudo pacman -Syu --noconfirm --needed $missing")
        ci.sh({ "./dotfiles/bin/.local/bin/dev", "soak", table.unpack(ci.args) })
      end,
    },
  },
}
