---@class dev.Builtin
---@field words string[] the command words, a noun and a subcommand for a subcommand row
---@field handler string? "legacy" for a bash handler, "lua" for a Lua one, nil for a noun or the project type's builtin
---@field noun boolean? whether the row is a noun
---@field flags string? the flags the verb takes, space separated
---@field usage string? the usage line `dev help <verb>` shows
---@field desc string description shown in `dev help`
---@field group string? heading in `dev help`, nil for a subcommand or a hidden verb
---@field hidden boolean? whether `dev help` keeps the verb to `-a`

---@type dev.Builtin[]
return {
    {
        words = { "lint" },
        desc = "Check style and formatting for the project type",
        group = "Check your work",
    },
    {
        words = { "fmt" },
        desc = "Format the source for the project type",
        group = "Check your work",
    },
    { words = { "test" }, desc = "Run the project's tests", group = "Check your work" },
    { words = { "build" }, desc = "Build the project", group = "Check your work" },
    { words = { "run" }, desc = "Run the project", group = "Check your work" },
    {
        words = { "fetch" },
        desc = "Download the crates and advisory database an offline lint and test need",
        group = "Check your work",
    },
    {
        words = { "deploy" },
        handler = "legacy",
        usage = "(none: add .dev/deploy.sh)",
        desc = "Deploy the project (needs .dev/deploy.sh)",
        group = "Share it",
    },
    {
        words = { "push" },
        handler = "legacy",
        desc = "Push the trunk bookmark (jj) or the current branch (git) to the remote of record (gerrit in a gerrit project, else origin), or to the remotes named",
        group = "Share it",
    },
    {
        words = { "pull" },
        handler = "legacy",
        desc = "Fetch the remote and rebase local work onto it",
        group = "Share it",
    },
    {
        words = { "sync" },
        handler = "legacy",
        flags = "--check --yes -y",
        desc = "Compare copied lint files, the lints block, lib.rs attributes and docs/STYLE.md with the dotfiles templates",
        group = "Set up a machine or project",
    },
    {
        words = { "init" },
        handler = "legacy",
        flags = "--type --public --name --dry-run --no-gerrit",
        usage = "dev init [--type T] [--public] [--name N] [--dry-run] [--no-gerrit]",
        desc = "Seed a project with lint, CI and remotes",
        group = "Set up a machine or project",
    },
    {
        words = { "tools" },
        noun = true,
        desc = "Install and check the tools in .dev/tools.tsv",
        group = "Set up a machine or project",
    },
    {
        words = { "tools", "install" },
        handler = "legacy",
        flags = "--dry-run --force --group --system --user",
        usage = "dev tools install [--system or --user] [--group NAME] [--dry-run] [--force] [tool...]",
        desc = "Install the manifest's tools, only the package rows with --system or only the script and cargo rows with --user",
    },
    {
        words = { "tools", "check" },
        handler = "legacy",
        flags = "--group",
        usage = "dev tools check [--group NAME]",
        desc = "Report which of the manifest's tools are on PATH, exit 1 when one is missing",
    },
    {
        words = { "guide" },
        handler = "legacy",
        usage = "dev guide [question...]",
        desc = "Show this repo's overview, or ask guide a question about its commands and topics",
        group = "Set up a machine or project",
    },
    {
        words = { "connect" },
        handler = "legacy",
        flags = "--ssh",
        usage = "dev connect [<box>] [--ssh]",
        desc = "Attach to a box over Eternal Terminal in a tmux session, picking, resuming or creating one first",
        group = "Boxes",
    },
    {
        words = { "box" },
        noun = true,
        desc = "List, create, show, stop, resume, extend, delete and connect to dev boxes through ci box",
        group = "Boxes",
    },
    {
        words = { "box", "ls" },
        handler = "legacy",
        flags = "--all",
        usage = "dev box ls [--all]",
        desc = "List the boxes with state, target, projects and time left, then the cap",
    },
    {
        words = { "box", "create" },
        handler = "legacy",
        flags = "--target --shape --by --ttl --keep",
        usage = "dev box create [--target T] [--shape S] [--by LABEL] [--ttl HOURS or --keep] [PROJECT...]",
        desc = "Create a box and wait until it runs, with the hub's default target and shape, 4 hours unless told otherwise, and the current project by default",
    },
    {
        words = { "box", "show" },
        handler = "legacy",
        usage = "dev box show BOX",
        desc = "Show one box as key: value lines",
    },
    {
        words = { "box", "stop" },
        handler = "legacy",
        usage = "dev box stop BOX",
        desc = "Stop a box, which ci deletes later unless it is resumed",
    },
    {
        words = { "box", "resume" },
        handler = "legacy",
        flags = "--ttl --keep",
        usage = "dev box resume BOX [--ttl HOURS or --keep]",
        desc = "Start a stopped box again, keeping its lifetime unless told otherwise",
    },
    {
        words = { "box", "extend" },
        handler = "legacy",
        flags = "--ttl --keep",
        usage = "dev box extend BOX (--ttl HOURS or --keep)",
        desc = "Replace a running box's lifetime, counted from now",
    },
    {
        words = { "box", "install-tools" },
        handler = "legacy",
        usage = "dev box install-tools BOX [PROJECT...]",
        desc = "Reinstall a running box's tools, for every project unless some are named",
    },
    {
        words = { "box", "delete" },
        handler = "legacy",
        flags = "--yes -y --no-archive",
        usage = "dev box delete BOX [-y or --yes] [--no-archive]",
        desc = "Archive a box's projects and delete it, or delete it with no archive under --no-archive, after asking unless -y",
    },
    {
        words = { "box", "connect" },
        handler = "legacy",
        flags = "--ssh",
        usage = "dev box connect [<box>] [--ssh]",
        desc = "Same as dev connect",
    },
    {
        words = { "bootstrap" },
        handler = "legacy",
        flags = "--dry-run --no-login",
        usage = "dev bootstrap [--dry-run] [--no-login]",
        desc = "Run bootstrap.sh from the dotfiles clone: the package manager and luajit first, then stow, tailscale, the default packages and the manifest tools",
        hidden = true,
    },
    {
        words = { "help" },
        handler = "lua",
        flags = "-a -k --topics",
        usage = "dev help [-a] [--topics] [-k topic] [verb or topic]",
        desc = "Show the commands, the details of one verb or a topic",
        hidden = true,
    },
}
