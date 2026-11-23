-- Loop the signal tests beside CPU burners. No job names a target, so it runs
-- on the default_target of the ci config that starts the run.
local PACMAN_PACKAGES = "git jujutsu luajit bats dash stow ripgrep fd sd man-db zsh unzip util-linux"

return {
  jobs = {
    soak = {
      name = "soak on ${target}",
      run = function()
        ci.sh("missing=$(pacman -T " .. PACMAN_PACKAGES .. ") || sudo pacman -Syu --noconfirm --needed $missing", { name = "install packages" })
        ci.sh({ "./bin/dev", "soak", table.unpack(ci.args) }, { name = "soak" })
      end,
    },
  },
}
