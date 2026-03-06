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

# Review GitHub PR #123 in an isolated workspace with Claude
rv 123

# Return to previous directory
popd
```

## Configuration

Set a custom workspace path (default: `~/.local/share/workspaces`):

```nix
programs.workspacer = {
  enable = true;
  workspacePath = "$HOME/workspaces";
};
```

Or via environment variable:

```bash
export WORKSPACE_PATH="$HOME/workspaces"
```

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
