local remote = require("dev.remote")

local PIPELINES = { bootstrap = "bootstrap", soak = "soak" }

return function(run)
    local opts = { verbosity = run.verbose }
    if #run.words == 1 then
        opts.pipeline = PIPELINES[run.words[1]]
    end
    return remote.ci_runner(run, opts)
end
