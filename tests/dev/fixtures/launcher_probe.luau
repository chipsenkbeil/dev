local dev_os = require("@dev/os")

for _, name in ipairs(arg) do
    dev_os.stdout:write(name, "=", dev_os.getenv(name) or "<unset>", "\n")
end
