-- Proves that bootstrap.sh --no-login builds a usable box on Arch, the way the
-- dev box image build runs it.
--
--   dev --remote bootstrap
--
-- The linux-x86-base target with vm = true is an Arch VM: the job runs as root
-- with sudo, and stow and zsh are absent. So the job creates the user the image build uses,
-- gives it passwordless sudo for the run, and does everything else as that user.
-- A full run installs every .dev/tools.tsv row, AUR builds included, so it is long
-- and sits in its own pipeline, outside the default one that runs on every patchset.
local USER = "user"
local HOME = "/home/" .. USER
local CLONE = HOME .. "/projects/dotfiles"

local function as_user(script, name)
  ci.sh("su - " .. USER .. " -c 'set -e; cd " .. CLONE .. "; " .. script .. "'", { name = name })
end

return {
  jobs = {
    ["bootstrap"] = {
      name = "bootstrap on ${target}",
      matrix = { { target = "linux-x86-base", vm = true } },
      run = function()
        ci.group("create " .. USER, function()
          ci.sh("id " .. USER .. " >/dev/null 2>&1 || useradd -m -s /bin/bash " .. USER, { name = "create user" })
          ci.sh("echo '" .. USER .. " ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/90-" .. USER .. "-bootstrap", { name = "grant sudo" })
          ci.sh("chmod 440 /etc/sudoers.d/90-" .. USER .. "-bootstrap", { name = "lock sudoers file" })
          ci.sh("rm -rf " .. CLONE .. " && mkdir -p " .. HOME .. "/projects && cp -a \"$PWD\" " .. CLONE, { name = "copy clone" })
          ci.sh("chown -R " .. USER .. ":" .. USER .. " " .. HOME .. "/projects", { name = "chown clone" })
        end)
        ci.group("bootstrap --no-login", function()
          as_user("bash bootstrap.sh --no-login", "bootstrap")
        end)
        ci.group("check the result", function()
          as_user("zsh -ic \"command -v jj nvim\"", "check tools")
          as_user("./dotfiles/bin/.local/bin/dev test", "test")
          as_user("./dotfiles/bin/.local/bin/dev lint", "lint")
          ci.sh("cd " .. CLONE .. " && bash tests/dev/root_test.sh </dev/null", { name = "root test" })
        end)
        ci.sh("rm -f /etc/sudoers.d/90-" .. USER .. "-bootstrap", { name = "remove sudo grant" })
      end,
    },
  },
}
