local remote = require("dev.remote")

return function(run)
    local opts = { verbosity = run.verbose }
    if #run.words == 1 and run.words[1] == "bootstrap" then
        opts.pipeline = "bootstrap"
    end
    return remote.ci_runner(run, opts)
end
