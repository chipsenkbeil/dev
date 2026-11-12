local PACMAN_PACKAGES = "git jujutsu luajit bats shellcheck shfmt stylua selene ast-grep jq go-yq dash stow ripgrep fd sd man-db zsh unzip"
local ROOT_CLONE = "/root/dotfiles"

local function real_root(file, name)
  local run = "sudo bash -c 'cd " .. ROOT_CLONE .. " && bash " .. file .. " </dev/null' >$log 2>&1"
  local check = "if grep -q '^SKIP real-root' $log; then echo 'a real-root case skipped in " .. file .. "'; exit 1; fi"
  ci.sh("log=$(mktemp); " .. run .. "; status=$?; cat $log; [ $status -eq 0 ] || exit $status; " .. check, { name = name })
end

local function shell_quote(word)
  return "'" .. (word:gsub("'", "'\\''")) .. "'"
end

local function prepare()
  ci.sh("missing=$(pacman -T " .. PACMAN_PACKAGES .. ") || sudo pacman -Syu --noconfirm --needed $missing", { name = "install packages" })
end

return {
  jobs = {
    lint = {
      name = "lint on ${target} (${shape})",
      matrix = { { target = "linux-x86-dev", shape = "small" } },
      run = function()
        prepare()
        ci.sh("./dotfiles/bin/.local/bin/dev lint </dev/null", { name = "lint" })
      end,
    },
    test = {
      name = "test on ${target}",
      matrix = { { target = "linux-x86-rust" } },
      run = function()
        prepare()
        local command = "./dotfiles/bin/.local/bin/dev test"
        for _, word in ipairs(ci.args) do
          command = command .. " " .. shell_quote(word)
        end
        ci.sh(command .. " </dev/null", { name = "test" })
        if #ci.args > 0 then
          return
        end
        ci.group("real root", function()
          ci.sh("sudo rm -rf " .. ROOT_CLONE .. " && sudo cp -a \"$PWD\" " .. ROOT_CLONE, { name = "copy clone" })
          ci.sh("sudo chown -R root:root " .. ROOT_CLONE .. " && sudo chmod -R go-w " .. ROOT_CLONE, { name = "chown clone" })
          real_root("tests/dev/root_test.sh", "root test")
          real_root("tests/dev/tools_test.sh", "tools test")
        end)
      end,
    },
  },
}
