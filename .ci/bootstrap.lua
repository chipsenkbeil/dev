-- Proves that bootstrap.sh --no-login builds a usable box on Arch, the way the
-- dev box image build runs it.
--
--   dev --remote bootstrap
--
-- The linux-vm target is an Arch VM: the job runs as root with sudo, and
-- stow and zsh are absent. So the job creates the user the image build uses,
-- gives it passwordless sudo for the run, and does everything else as that user.
-- A full run installs every .dev/tools.tsv row, AUR builds included, so it is long
-- and sits in its own pipeline, outside the default one that runs on every patchset.
local USER = "user"
local HOME = "/home/" .. USER
local CLONE = HOME .. "/projects/dotfiles"

local function as_user(script)
  ci.sh("su - " .. USER .. " -c 'set -e; cd " .. CLONE .. "; " .. script .. "'")
end

return {
  jobs = {
    ["bootstrap"] = {
      matrix = { { target = "linux-vm" } },
      run = function()
        ci.group("create " .. USER, function()
          ci.sh("id " .. USER .. " >/dev/null 2>&1 || useradd -m -s /bin/bash " .. USER)
          ci.sh("echo '" .. USER .. " ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/90-" .. USER .. "-bootstrap")
          ci.sh("chmod 440 /etc/sudoers.d/90-" .. USER .. "-bootstrap")
          ci.sh("rm -rf " .. CLONE .. " && mkdir -p " .. HOME .. "/projects && cp -a \"$PWD\" " .. CLONE)
          ci.sh("chown -R " .. USER .. ":" .. USER .. " " .. HOME .. "/projects")
        end)
        ci.group("bootstrap --no-login", function()
          as_user("bash bootstrap.sh --no-login")
        end)
        ci.group("check the result", function()
          as_user("zsh -ic \"command -v jj nvim\"")
          as_user("./dotfiles/bin/.local/bin/dev test")
          as_user("./dotfiles/bin/.local/bin/dev lint")
          ci.sh("cd " .. CLONE .. " && bash tests/dev/root_test.sh </dev/null")
        end)
        ci.sh("rm -f /etc/sudoers.d/90-" .. USER .. "-bootstrap")
      end,
    },
  },
}
