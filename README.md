# workspacer

<img src="workspacer.png" align="right" width="120">

A `git worktree`-based workspace manager for git repositories. Allows creating isolated worktrees for feature development without cluttering your main repository, deleting no longer used ones and offers fast navigation between different workspaces.

## Usage

Most common workflow: `wss` to enter a workspace and start an isolated shell.

```bash
# Create/enter workspace and start sandboxed shell (recommended)
wss my-feature

# Create or enter a workspace (run from any git repo)
ws my-feature

# Start sandboxed Claude in a workspace
wsc my-feature

# Start sandboxed Codex in a workspace without approval prompts
wsx my-feature

# Return to main repository
ws

# List workspaces for current repo
ws --list
ws -l

# Delete workspaces without any changes
ws --clean
ws -c

# Show help
ws --help
ws -h

# Review GitHub PR #123 in an isolated workspace with Claude (inside repo)
rv 123

# Review GitHub PR #123 from anywhere by specifying project name
rv myrepo 123

# Return to previous directory
popd
```

For `rv <project> <pr>`, the project must already exist under `$WORKSPACE_PATH`
(for example from a prior `ws` workspace in that repo).

## Configuration

Set a custom workspace path (default: `~/.local/share/workspaces`):

```nix
programs.workspacer = {
  enable = true;
  workspacePath = "$HOME/workspaces";
  configDir = "$HOME/.config/workspacer";
};
```

Or via environment variable:

```bash
export WORKSPACE_PATH="$HOME/workspaces"
```

Set a custom sandbox config directory (default: `~/.config/workspacer`):

```bash
export WORKSPACER_CONFIG_DIR="$HOME/.config/workspacer"
```

Sandbox home/config layout:

```text
$WORKSPACER_CONFIG_DIR/
├── env
├── home_ro/
├── home_rw/
└── home_cow/
```

- `env`: dotenv-style `KEY=VALUE` lines loaded into sandbox commands (`wss`, `wsc`, `wsx`, `rv`, `claude-sandbox`, `shell-sandbox`).
- `home_ro/`: each entry path is bind-mounted to the same path under `~` read-only.
- `home_rw/`: each entry path is bind-mounted to the same path under `~` read-write.
- `home_cow/`: each entry path is copied to a temporary dir, then mounted read-write to the same path under `~`.

Practical setup example (minimal and safe defaults for `wss`, `wsc`, `wsx`, `rv`):

```bash
cfg="${WORKSPACER_CONFIG_DIR:-$HOME/.config/workspacer}"
mkdir -p "$cfg"/home_ro "$cfg"/home_rw "$cfg"/home_cow

# Shell startup files in sandbox (copy when you want to remove secrets from sandbox view)
cp -f "$HOME/.bashrc" "$cfg/home_ro/.bashrc"
cp -f "$HOME/.profile" "$cfg/home_ro/.profile"
ln -sfn "$HOME/.bash_profile" "$cfg/home_ro/.bash_profile"
ln -sfn "$HOME/.zprofile" "$cfg/home_ro/.zprofile"
ln -sfn "$HOME/.zshrc" "$cfg/home_ro/.zshrc"

# Only mount required .local paths (avoid mounting all of ~/.local)
mkdir -p "$cfg/home_ro/.local"
ln -sfn "$HOME/.local/bin" "$cfg/home_ro/.local/bin"
ln -sfn "$HOME/.local/lib" "$cfg/home_ro/.local/lib"

# Agent state/config
ln -sfn "$HOME/.claude" "$cfg/home_rw/.claude"
ln -sfn "$HOME/.claude.json" "$cfg/home_rw/.claude.json"
ln -sfn "$HOME/.codex" "$cfg/home_rw/.codex"

# Separate key material for sandbox only (recommended)
mkdir -p "$cfg/home_rw/.gnupg" "$cfg/home_rw/.ssh"
chmod 700 "$cfg/home_rw/.gnupg" "$cfg/home_rw/.ssh"
```

Notes:
- Nested paths are supported. For example, `home_ro/.local/bin` mounts to `~/.local/bin`.
- Prefer mounting specific subpaths instead of whole trees (for example `.local/bin` and `.local/lib`, not all of `.local`).
- `home_cow` is useful when tools need writable configs but you do not want changes to persist.

## Directory Structure

Workspaces are organized by repository name:

```
$WORKSPACE_PATH/
└── myrepo/
    ├── feature-a/
    ├── feature-b/
    └── bugfix-123/
```

## Installation

### NixOS (recommended)

Add to your flake inputs and enable the module:

```nix
{
  inputs.workspacer.url = "github:elsirion/workspacer";

  outputs = { self, nixpkgs, workspacer, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        workspacer.nixosModules.default
        {
          programs.workspacer.enable = true;
        }
      ];
    };
  };
}
```

### Manual

Source the script in your shell rc file:

```bash
source /path/to/ws.sh
```



## License

MIT
