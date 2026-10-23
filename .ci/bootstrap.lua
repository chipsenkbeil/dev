-- Proves that bootstrap.sh --no-login builds a usable box on Arch, the way the
-- dev box image build runs it.
--
--   ci run bootstrap --local --job bootstrap-arch -f
--
-- The linux-vm target is an Arch VM: the job runs as root with sudo, and
-- stow and zsh are absent. So the job creates the user the image build uses,
-- gives it passwordless sudo for the run, and does everything else as that user.
-- A full run installs every .dev/tools.tsv row, AUR builds included, so it is long
-- and never part of a default run.
local USER = "user"
local HOME = "/home/" .. USER
local CLONE = HOME .. "/projects/dotfiles"

local function as_user(script)
  ci.sh("su - " .. USER .. " -c 'set -e; cd " .. CLONE .. "; " .. script .. "'")
end

return {
  jobs = {
    ["root-tests"] = {
      matrix = { { os = "linux-base" } },
      run = function()
        ci.sh("[ \"$(id -u)\" -eq 0 ] || { echo 'root-tests must run as root' >&2; exit 1; }")
        ci.sh("bash tests/dev/root_test.sh </dev/null")
        ci.sh("bash tests/dev/tools_test.sh </dev/null")
      end,
    },
    ["bootstrap-arch"] = {
      matrix = { { os = "linux-vm" } },
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
          as_user("zsh -ic \"command -v mosh jj nvim\"")
          as_user("./dotfiles/bin/.local/bin/dev test")
          as_user("./dotfiles/bin/.local/bin/dev lint")
          ci.sh("cd " .. CLONE .. " && bash tests/dev/root_test.sh </dev/null")
        end)
        ci.sh("rm -f /etc/sudoers.d/90-" .. USER .. "-bootstrap")
      end,
    },
  },
}
