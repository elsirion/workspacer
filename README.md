# workspacer

<img src="workspacer.png" align="right" width="120">

A `git worktree`-based workspace manager for git repositories. Allows creating isolated worktrees for feature development without cluttering your main repository, deleting no longer used ones and offers fast navigation between different workspaces.

## Usage

```bash
# Create or enter a workspace (run from any git repo)
ws my-feature

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

- `env`: dotenv-style `KEY=VALUE` lines loaded into sandbox commands (`wss`, `wsc`, `rv`, `claude-sandbox`, `shell-sandbox`).
- `home_ro/`: each entry path is bind-mounted to the same path under `~` read-only.
- `home_rw/`: each entry path is bind-mounted to the same path under `~` read-write.
- `home_cow/`: each entry path is copied to a temporary dir, then mounted read-write to the same path under `~`.

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
