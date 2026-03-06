#!/bin/bash
# ws - Workspace manager for git repositories
# Source this file in your shell rc file: source /path/to/ws.sh

# Default workspace path follows XDG Base Directory Specification
: "${WORKSPACE_PATH:=${XDG_DATA_HOME:-$HOME/.local/share}/workspaces}"

ws() {
    local workspace_arg="$1"

    # Check if we're in a git repository
    local git_root
    git_root=$(git rev-parse --show-toplevel 2>/dev/null)

    # No argument: go back to main repo directory
    if [[ -z "$workspace_arg" ]]; then
        if [[ -z "$git_root" ]]; then
            echo "Error: Not in a git repository" >&2
            return 1
        fi
        local main_repo
        # Check if we're in a worktree and get the main worktree path
        main_repo=$(git worktree list --porcelain 2>/dev/null | head -n1 | sed 's/^worktree //')
        if [[ -z "$main_repo" ]]; then
            main_repo="$git_root"
        fi
        pushd "$main_repo" > /dev/null || return 1
        echo "Changed to main repo: $main_repo (use 'popd' to return)"
        return 0
    fi

    # Handle options (anything starting with - or --)
    if [[ "$workspace_arg" == -* ]]; then
        case "$workspace_arg" in
            --list|-l)
                _ws_list_workspaces
                return 0
                ;;
            --clean|-c)
                _ws_clean_workspaces
                return $?
                ;;
            --help|-h)
                _ws_help
                return 0
                ;;
            *)
                echo "Error: Unknown option '$workspace_arg'" >&2
                echo "Run 'ws --help' for usage information" >&2
                return 1
                ;;
        esac
    fi

    # Parse <project>/<workspace> syntax
    local repo_name workspace_name
    if [[ "$workspace_arg" == */* ]]; then
        # Split on first /
        repo_name="${workspace_arg%%/*}"
        workspace_name="${workspace_arg#*/}"

        # Validate that both parts are non-empty
        if [[ -z "$repo_name" || -z "$workspace_name" ]]; then
            echo "Error: Invalid format. Use: ws <project>/<workspace>" >&2
            return 1
        fi

        # Check if this project has any workspaces
        if [[ ! -d "$WORKSPACE_PATH/$repo_name" ]]; then
            echo "Error: No workspaces found for project '$repo_name'" >&2
            echo "Available projects:" >&2
            _ws_list_all_projects >&2
            return 1
        fi
    else
        # No slash, use current repo if we're in one
        workspace_name="$workspace_arg"
        if [[ -z "$git_root" ]]; then
            echo "Error: Not in a git repository. Use <project>/<workspace> syntax to specify project." >&2
            echo "Available projects:" >&2
            _ws_list_all_projects >&2
            return 1
        fi
        repo_name=$(basename "$git_root")
    fi

    # Workspace directory path
    local workspace_dir="$WORKSPACE_PATH/$repo_name/$workspace_name"

    # Find the main repository for this project
    local main_repo_path=""
    if [[ -n "$git_root" ]] && [[ "$(basename "$git_root")" == "$repo_name" ]]; then
        # We're in the correct git repo
        main_repo_path=$(git worktree list --porcelain 2>/dev/null | head -n1 | sed 's/^worktree //')
        if [[ -z "$main_repo_path" ]]; then
            main_repo_path="$git_root"
        fi
    else
        # Try to find an existing workspace for this project to get the main repo
        if [[ -d "$WORKSPACE_PATH/$repo_name" ]]; then
            for ws_dir in "$WORKSPACE_PATH/$repo_name"/*/; do
                if [[ -d "$ws_dir/.git" ]] || [[ -f "$ws_dir/.git" ]]; then
                    main_repo_path=$(git -C "$ws_dir" worktree list --porcelain 2>/dev/null | head -n1 | sed 's/^worktree //')
                    if [[ -n "$main_repo_path" ]]; then
                        break
                    fi
                fi
            done
        fi
    fi

    # Create workspace if it doesn't exist
    if [[ ! -d "$workspace_dir" ]]; then
        echo "Creating new workspace: $workspace_dir"

        # Create parent directory
        mkdir -p "$(dirname "$workspace_dir")"

        # Clone/worktree the repository
        # Use git worktree for efficiency (shares .git objects)
        if [[ -n "$main_repo_path" ]] && git -C "$main_repo_path" worktree add "$workspace_dir" -b "_ws_temp_$$" 2>/dev/null; then
            # Remove the temporary branch, we'll create the proper one later
            git -C "$workspace_dir" branch -D "_ws_temp_$$" 2>/dev/null || true
        else
            echo "Error: Cannot create workspace. No main repository found for project '$repo_name'" >&2
            echo "Hint: Create the first workspace while in the git repository" >&2
            return 1
        fi
    fi

    # Change to workspace directory (use pushd so user can popd back)
    pushd "$workspace_dir" > /dev/null || return 1
    echo "Changed to workspace: $workspace_dir (use 'popd' to return)"

    # Generate branch name: <year>-<month>-<workspace_name>
    local year month branch_name
    year=$(date +%Y)
    month=$(date +%m)
    branch_name="${year}-${month}-${workspace_name}"

    # Check out the branch (create if it doesn't exist)
    local current_branch
    current_branch=$(git branch --show-current 2>/dev/null)

    if [[ "$current_branch" != "$branch_name" ]]; then
        if git show-ref --verify --quiet "refs/heads/$branch_name"; then
            echo "Checking out existing branch: $branch_name"
            git checkout "$branch_name"
        else
            echo "Creating and checking out new branch: $branch_name"
            git checkout -b "$branch_name"
        fi
    else
        echo "Already on branch: $branch_name"
    fi

    # Allow and enter direnv if .envrc exists
    if [[ -f ".envrc" ]]; then
        if command -v direnv &>/dev/null; then
            echo "Allowing direnv..."
            direnv allow .
        else
            echo "Note: .envrc found but direnv is not installed"
        fi
    fi

    return 0
}

# Internal: Run a command in a sandboxed environment
# Usage: _ws_run_sandboxed <workdir> <command> [args...]
_ws_run_sandboxed() {
    local workdir="$1"
    shift
    local cmd=("$@")

    # Resolve to absolute path
    workdir=$(cd "$workdir" && pwd)

    if [[ ! -d "$workdir" ]]; then
        echo "Error: Directory does not exist: $workdir" >&2
        return 1
    fi

    # Check for bubblewrap
    if ! command -v bwrap &>/dev/null; then
        echo "Error: bubblewrap (bwrap) is not installed" >&2
        echo "Install it with: nix-shell -p bubblewrap" >&2
        return 1
    fi

    echo "Starting sandbox in: $workdir"
    echo "  - Filesystem: $workdir + ~/.claude are writable"
    echo "  - Network: full access"
    echo "  - Processes: isolated"

    # Build the bwrap command
    local -a bwrap_args=(
        --unshare-all
        --share-net
        --die-with-parent
        # Mount nix store read-only
        --ro-bind /nix /nix
        # System essentials (read-only)
        --ro-bind /etc/resolv.conf /etc/resolv.conf
        --ro-bind /etc/ssl /etc/ssl
        --ro-bind /etc/hosts /etc/hosts
        --ro-bind /etc/passwd /etc/passwd
        --ro-bind /etc/group /etc/group
        # NixOS-specific paths
        --ro-bind /run/current-system /run/current-system
        # Nix daemon socket for nix commands inside sandbox
        --ro-bind /nix/var/nix/daemon-socket /nix/var/nix/daemon-socket
        # Device, proc, and sys filesystems
        --dev /dev
        --proc /proc
        --ro-bind /sys /sys
        # Tmpfs for temp files and fake home
        --tmpfs /tmp
        --tmpfs "$HOME"
        # Workspace directory (read-write)
        --bind "$workdir" "$workdir"
        # Set working directory
        --chdir "$workdir"
        # Set HOME to actual home (on tmpfs, but with config mounted below)
        --setenv HOME "$HOME"
    )

    # Mount git config and any included config files (read-only)
    if [[ -f "$HOME/.gitconfig" ]]; then
        bwrap_args+=(--ro-bind "$HOME/.gitconfig" "$HOME/.gitconfig")
        # Parse includeIf paths and mount them too
        local inc_path
        while read -r _ inc_path; do
            # Expand ~ to $HOME
            inc_path="${inc_path/#\~/$HOME}"
            if [[ -f "$inc_path" ]]; then
                bwrap_args+=(--ro-bind "$inc_path" "$inc_path")
            fi
        done < <(git config --global --get-regexp 'includeIf\..*\.path' 2>/dev/null)
    fi

    # Mount GPG keyring (read-only) and agent socket for commit signing
    if [[ -d "$HOME/.gnupg" ]]; then
        bwrap_args+=(--ro-bind "$HOME/.gnupg" "$HOME/.gnupg")
    fi
    local gpg_socket_dir
    gpg_socket_dir="$(gpgconf --list-dirs socketdir 2>/dev/null)"
    if [[ -n "$gpg_socket_dir" && -d "$gpg_socket_dir" ]]; then
        bwrap_args+=(--ro-bind "$gpg_socket_dir" "$gpg_socket_dir")
    fi

    # If workdir is a git worktree, mount the main repo's .git directory
    # Worktrees have a .git file (not directory) pointing to .git/worktrees/<name>
    if [[ -f "$workdir/.git" ]]; then
        local git_common_dir
        git_common_dir="$(git -C "$workdir" rev-parse --git-common-dir 2>/dev/null)"
        if [[ -n "$git_common_dir" ]]; then
            git_common_dir="$(cd "$workdir" && cd "$git_common_dir" && pwd)"
            bwrap_args+=(--bind "$git_common_dir" "$git_common_dir")
        fi
    fi

    # Mount Claude config directory if it exists (read-write for session state)
    if [[ -d "$HOME/.claude" ]]; then
        bwrap_args+=(--bind "$HOME/.claude" "$HOME/.claude")
    fi

    # Mount ~/.claude.json if it exists (contains MCP server config)
    if [[ -f "$HOME/.claude.json" ]]; then
        bwrap_args+=(--bind "$HOME/.claude.json" "$HOME/.claude.json")
    fi

    # Mount ~/.config/claude if it exists
    if [[ -d "$HOME/.config/claude" ]]; then
        bwrap_args+=(--ro-bind "$HOME/.config/claude" "$HOME/.config/claude")
    fi

    # Mount ~/.local for MCP servers (e.g., playwright) and user-installed tools
    if [[ -d "$HOME/.local/bin" ]]; then
        bwrap_args+=(--ro-bind "$HOME/.local/bin" "$HOME/.local/bin")
    fi
    if [[ -d "$HOME/.local/lib" ]]; then
        bwrap_args+=(--ro-bind "$HOME/.local/lib" "$HOME/.local/lib")
    fi

    # Mount shell config files read-only so the user's shell environment works
    local shell_configs=(.bashrc .bash_profile .profile .zshrc .zprofile .zshenv .inputrc)
    for cfg in "${shell_configs[@]}"; do
        if [[ -f "$HOME/$cfg" ]]; then
            bwrap_args+=(--ro-bind "$HOME/$cfg" "$HOME/$cfg")
        fi
    done

    # Add /etc/static if it exists (NixOS)
    if [[ -d /etc/static ]]; then
        bwrap_args+=(--ro-bind /etc/static /etc/static)
    fi

    # Run with direnv environment if available
    if command -v direnv &>/dev/null && [[ -f "$workdir/.envrc" ]]; then
        echo "  - Environment: loaded from .envrc"
        direnv exec "$workdir" bwrap "${bwrap_args[@]}" "${cmd[@]}"
    else
        bwrap "${bwrap_args[@]}" "${cmd[@]}"
    fi
}

# Run claude in a sandboxed environment
claude-sandbox() {
    local workdir="${1:-$(pwd)}"

    # Check for claude
    if ! command -v claude &>/dev/null; then
        echo "Error: claude is not installed" >&2
        return 1
    fi

    _ws_run_sandboxed "$workdir" claude --dangerously-skip-permissions
}

# Run a shell in a sandboxed environment
shell-sandbox() {
    local workdir="${1:-$(pwd)}"
    _ws_run_sandboxed "$workdir" bash
}

# Internal: Enter workspace and run a sandboxed command
_ws_enter_and_sandbox() {
    local workspace_arg="$1"
    shift
    local cmd=("$@")

    if [[ -z "$workspace_arg" ]]; then
        echo "Error: Workspace name required" >&2
        return 1
    fi

    # Enter the workspace (this uses pushd internally)
    ws "$workspace_arg" || return 1

    # Run sandboxed command in the workspace
    _ws_run_sandboxed "$(pwd)" "${cmd[@]}"
}

# Enter workspace and start sandboxed claude
wsc() {
    if [[ "$1" == "--help" || "$1" == "-h" ]]; then
        echo "wsc - Enter workspace and start sandboxed claude"
        echo ""
        echo "Usage: wsc <name>  or  wsc <project>/<workspace>"
        return 0
    fi

    if ! command -v claude &>/dev/null; then
        echo "Error: claude is not installed" >&2
        return 1
    fi

    _ws_enter_and_sandbox "$1" claude --dangerously-skip-permissions
}

# Enter workspace and start sandboxed shell
wss() {
    if [[ "$1" == "--help" || "$1" == "-h" ]]; then
        echo "wss - Enter workspace and start sandboxed shell"
        echo ""
        echo "Usage: wss <name>  or  wss <project>/<workspace>"
        return 0
    fi

    _ws_enter_and_sandbox "$1" bash
}

# Review a pull request in an isolated workspace with claude
rv() {
    if [[ "$1" == "--help" || "$1" == "-h" ]]; then
        cat <<'EOF'
rv - Review a GitHub pull request in an isolated workspace

Usage: rv <pr-number>

Creates/enters workspace pr-<pr-number>-review, checks out the PR branch
with gh, then launches claude in interactive sandboxed mode with a review prompt.
EOF
        return 0
    fi

    local pr_number="$1"
    if [[ -z "$pr_number" ]]; then
        echo "Error: PR number required" >&2
        echo "Usage: rv <pr-number>" >&2
        return 1
    fi

    if [[ ! "$pr_number" =~ ^[0-9]+$ ]]; then
        echo "Error: PR number must be numeric" >&2
        return 1
    fi

    local git_root
    git_root=$(git rev-parse --show-toplevel 2>/dev/null)
    if [[ -z "$git_root" ]]; then
        echo "Error: rv must be run inside a git repository" >&2
        return 1
    fi

    if ! command -v gh &>/dev/null; then
        echo "Error: gh (GitHub CLI) is not installed" >&2
        return 1
    fi

    if ! command -v claude &>/dev/null; then
        echo "Error: claude is not installed" >&2
        return 1
    fi

    local main_repo
    main_repo=$(git worktree list --porcelain 2>/dev/null | head -n1 | sed 's/^worktree //')
    if [[ -z "$main_repo" ]]; then
        main_repo="$git_root"
    fi

    local repo_name
    repo_name=$(basename "$main_repo")
    local workspace_name="pr-${pr_number}-review"

    # Enter/create a dedicated review workspace.
    ws "${repo_name}/${workspace_name}" || return 1

    echo "Checking out PR #$pr_number..."
    if ! gh pr checkout "$pr_number"; then
        echo "Error: Failed to check out PR #$pr_number" >&2
        return 1
    fi

    local review_prompt="Review pull request #${pr_number} in this repository. Start by checking changed files and commits, then report findings ordered by severity with file/line references."
    _ws_run_sandboxed "$(pwd)" claude --dangerously-skip-permissions "$review_prompt"
}

# List all projects (repos) that have workspaces
_ws_list_all_projects() {
    if [[ ! -d "$WORKSPACE_PATH" ]]; then
        echo "  (none)"
        return
    fi

    local found=0
    for project_dir in "$WORKSPACE_PATH"/*/; do
        if [[ -d "$project_dir" ]]; then
            basename "$project_dir"
            found=1
        fi
    done

    if [[ $found -eq 0 ]]; then
        echo "  (none)"
    fi
}

# List workspaces for the current repository
_ws_list_workspaces() {
    local git_root
    git_root=$(git rev-parse --show-toplevel 2>/dev/null)
    if [[ -z "$git_root" ]]; then
        echo "Error: Not in a git repository" >&2
        return 1
    fi

    local repo_name
    repo_name=$(basename "$git_root")

    local repo_workspace_dir="$WORKSPACE_PATH/$repo_name"

    if [[ -d "$repo_workspace_dir" ]]; then
        echo "Workspaces for $repo_name:"
        for ws_dir in "$repo_workspace_dir"/*/; do
            if [[ -d "$ws_dir" ]]; then
                basename "$ws_dir"
            fi
        done
    else
        echo "No workspaces found for this repository"
    fi
}

# Clean workspaces without any changes (staged, unstaged, or untracked)
_ws_clean_workspaces() {
    local git_root
    git_root=$(git rev-parse --show-toplevel 2>/dev/null)
    if [[ -z "$git_root" ]]; then
        echo "Error: Not in a git repository" >&2
        return 1
    fi

    # Get the main repo for worktree operations
    local main_repo
    main_repo=$(git worktree list --porcelain 2>/dev/null | head -n1 | sed 's/^worktree //')
    if [[ -z "$main_repo" ]]; then
        main_repo="$git_root"
    fi

    local repo_name
    repo_name=$(basename "$main_repo")

    local repo_workspace_dir="$WORKSPACE_PATH/$repo_name"

    if [[ ! -d "$repo_workspace_dir" ]]; then
        echo "No workspaces found for this repository"
        return 0
    fi

    local cleaned=0
    local kept=0

    for ws_dir in "$repo_workspace_dir"/*/; do
        if [[ ! -d "$ws_dir" ]]; then
            continue
        fi

        local ws_name
        ws_name=$(basename "$ws_dir")

        # Check if workspace has any changes (staged, unstaged, or untracked)
        # git status --porcelain returns empty if clean
        if [[ -z $(git -C "$ws_dir" status --porcelain 2>/dev/null) ]]; then
            echo "Removing clean workspace: $ws_name"

            # Remove worktree registration if it exists
            git -C "$main_repo" worktree remove "$ws_dir" --force 2>/dev/null || rm -rf "$ws_dir"

            ((cleaned++))
        else
            echo "Keeping workspace with changes: $ws_name"
            ((kept++))
        fi
    done

    echo ""
    echo "Cleaned: $cleaned, Kept: $kept"

    # Remove repo workspace dir if empty
    rmdir "$repo_workspace_dir" 2>/dev/null || true
}

# Show help message
_ws_help() {
    cat <<'EOF'
ws - Workspace manager for git repositories

Usage:
  ws                        Go back to main repository directory
  ws <name>                 Create/enter workspace with given name (requires being in a git repo)
  ws <project>/<workspace>  Create/enter workspace for specific project (works from anywhere)
  ws -l, --list             List all workspaces for current repo
  ws -c, --clean            Delete workspaces without any changes
  ws -h, --help             Show this help message

Sandbox:
  claude-sandbox [dir]      Run claude in an isolated sandbox (default: current dir)
  shell-sandbox [dir]       Run bash in an isolated sandbox (default: current dir)
  wsc <name>                Enter workspace and start sandboxed claude
  wss <name>                Enter workspace and start sandboxed shell
  rv <pr-number>            Review a GitHub PR in an isolated workspace

Workspaces are stored in $WORKSPACE_PATH (default: ~/.local/share/workspaces)
organized by repository name.

When entering a workspace, a branch named <year>-<month>-<name> is created
or checked out, and direnv is allowed if .envrc exists.

The <project>/<workspace> syntax allows you to enter workspaces from any directory,
even when not in a git repository. The project name is the repository directory name.

Use 'popd' to return to the previous directory after entering a workspace.

Sandbox Details:
  The claude-sandbox command runs claude inside a bubblewrap container with:
  - Full network access
  - Read-write access to the specified directory and ~/.claude
  - Read-only access to /nix (for nix run/develop)
  - Read-only access to ~/.local/bin and ~/.local/lib (for MCP servers)
  - Process isolation (cannot see/signal other processes)
  - No access to SSH keys or other sensitive files
  - GPG signing works via agent forwarding (keys stay outside sandbox)
  - If .envrc exists, the direnv environment is loaded before entering
EOF
}

# Completion function for bash
_ws_completions() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local git_root
    git_root=$(git rev-parse --show-toplevel 2>/dev/null)

    local suggestions=()
    local has_project_suggestions=0

    # Check if input contains a slash (project/workspace syntax)
    if [[ "$cur" == */* ]]; then
        # Extract project name from current input
        local project_prefix="${cur%%/*}"
        local workspace_prefix="${cur#*/}"
        local project_workspace_dir="$WORKSPACE_PATH/$project_prefix"

        # Suggest workspaces from the specified project
        if [[ -d "$project_workspace_dir" ]]; then
            for ws_dir in "$project_workspace_dir"/*/; do
                if [[ -d "$ws_dir" ]]; then
                    local ws_name=$(basename "$ws_dir")
                    suggestions+=("$project_prefix/$ws_name")
                fi
            done
        fi
    elif [[ -z "$git_root" ]]; then
        # Not in a git repo and no slash - suggest all projects
        if [[ -d "$WORKSPACE_PATH" ]]; then
            for project_dir in "$WORKSPACE_PATH"/*/; do
                if [[ -d "$project_dir" ]]; then
                    local project_name=$(basename "$project_dir")
                    suggestions+=("$project_name/")
                    has_project_suggestions=1
                fi
            done
        fi
        # Add options
        suggestions+=("--list" "--clean" "--help")
    else
        # In a git repo and no slash - suggest workspaces from current repo
        local repo_name=$(basename "$git_root")
        local repo_workspace_dir="$WORKSPACE_PATH/$repo_name"

        if [[ -d "$repo_workspace_dir" ]]; then
            for ws_dir in "$repo_workspace_dir"/*/; do
                if [[ -d "$ws_dir" ]]; then
                    suggestions+=("$(basename "$ws_dir")")
                fi
            done
        fi

        # Also suggest all projects with trailing slash for cross-project access
        if [[ -d "$WORKSPACE_PATH" ]]; then
            for project_dir in "$WORKSPACE_PATH"/*/; do
                if [[ -d "$project_dir" ]]; then
                    local project_name=$(basename "$project_dir")
                    suggestions+=("$project_name/")
                    has_project_suggestions=1
                fi
            done
        fi

        # Add options
        suggestions+=("--list" "--clean" "--help")
    fi

    COMPREPLY=($(compgen -W "${suggestions[*]}" -- "$cur"))

    # Disable space after completion if we're suggesting projects with trailing slash
    if [[ $has_project_suggestions -eq 1 ]]; then
        compopt -o nospace 2>/dev/null
    fi
}

# Completion function for wsc (bash) - like ws but only workspace names
_wsc_completions() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local git_root
    git_root=$(git rev-parse --show-toplevel 2>/dev/null)

    local suggestions=()
    local has_project_suggestions=0

    # Check if input contains a slash (project/workspace syntax)
    if [[ "$cur" == */* ]]; then
        local project_prefix="${cur%%/*}"
        local workspace_prefix="${cur#*/}"
        local project_workspace_dir="$WORKSPACE_PATH/$project_prefix"

        if [[ -d "$project_workspace_dir" ]]; then
            for ws_dir in "$project_workspace_dir"/*/; do
                if [[ -d "$ws_dir" ]]; then
                    local ws_name=$(basename "$ws_dir")
                    suggestions+=("$project_prefix/$ws_name")
                fi
            done
        fi
    elif [[ -z "$git_root" ]]; then
        # Not in a git repo - suggest all projects
        if [[ -d "$WORKSPACE_PATH" ]]; then
            for project_dir in "$WORKSPACE_PATH"/*/; do
                if [[ -d "$project_dir" ]]; then
                    local project_name=$(basename "$project_dir")
                    suggestions+=("$project_name/")
                    has_project_suggestions=1
                fi
            done
        fi
        suggestions+=("--help")
    else
        # In a git repo - suggest workspaces from current repo
        local repo_name=$(basename "$git_root")
        local repo_workspace_dir="$WORKSPACE_PATH/$repo_name"

        if [[ -d "$repo_workspace_dir" ]]; then
            for ws_dir in "$repo_workspace_dir"/*/; do
                if [[ -d "$ws_dir" ]]; then
                    suggestions+=("$(basename "$ws_dir")")
                fi
            done
        fi

        # Also suggest all projects
        if [[ -d "$WORKSPACE_PATH" ]]; then
            for project_dir in "$WORKSPACE_PATH"/*/; do
                if [[ -d "$project_dir" ]]; then
                    local project_name=$(basename "$project_dir")
                    suggestions+=("$project_name/")
                    has_project_suggestions=1
                fi
            done
        fi
        suggestions+=("--help")
    fi

    COMPREPLY=($(compgen -W "${suggestions[*]}" -- "$cur"))

    if [[ $has_project_suggestions -eq 1 ]]; then
        compopt -o nospace 2>/dev/null
    fi
}

# Completion function for rv (bash)
_rv_completions() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    COMPREPLY=($(compgen -W "--help" -- "$cur"))
}

# Register bash completion
if [[ -n "$BASH_VERSION" ]]; then
    complete -F _ws_completions ws
    complete -F _wsc_completions wsc
    complete -F _wsc_completions wss
    complete -F _rv_completions rv
fi

# Completion function for zsh
if [[ -n "$ZSH_VERSION" ]]; then
    _ws_zsh_completions() {
        local git_root
        git_root=$(git rev-parse --show-toplevel 2>/dev/null)

        local -a workspaces projects options
        local curcontext="$curcontext" state line
        typeset -A opt_args

        # Get current word being completed
        local cur="${words[CURRENT]}"

        # Check if input contains a slash (project/workspace syntax)
        if [[ "$cur" == */* ]]; then
            # Extract project name from current input
            local project_prefix="${cur%%/*}"
            local workspace_prefix="${cur#*/}"
            local project_workspace_dir="$WORKSPACE_PATH/$project_prefix"

            # Suggest workspaces from the specified project
            if [[ -d "$project_workspace_dir" ]]; then
                for ws_dir in "$project_workspace_dir"/*/; do
                    if [[ -d "$ws_dir" ]]; then
                        local ws_name=$(basename "$ws_dir")
                        workspaces+=("$project_prefix/$ws_name")
                    fi
                done
            fi
            compadd -a workspaces
        elif [[ -z "$git_root" ]]; then
            # Not in a git repo and no slash - suggest all projects
            if [[ -d "$WORKSPACE_PATH" ]]; then
                for project_dir in "$WORKSPACE_PATH"/*/; do
                    if [[ -d "$project_dir" ]]; then
                        local project_name=$(basename "$project_dir")
                        projects+=("$project_name/")
                    fi
                done
            fi
            # Add options
            options=("--list" "--clean" "--help")

            # Add projects without space, options with space
            compadd -S '' -a projects
            compadd -a options
        else
            # In a git repo and no slash - suggest workspaces from current repo
            local repo_name=$(basename "$git_root")
            local repo_workspace_dir="$WORKSPACE_PATH/$repo_name"

            if [[ -d "$repo_workspace_dir" ]]; then
                for ws_dir in "$repo_workspace_dir"/*/; do
                    if [[ -d "$ws_dir" ]]; then
                        workspaces+=("$(basename "$ws_dir")")
                    fi
                done
            fi

            # Also suggest all projects with trailing slash for cross-project access
            if [[ -d "$WORKSPACE_PATH" ]]; then
                for project_dir in "$WORKSPACE_PATH"/*/; do
                    if [[ -d "$project_dir" ]]; then
                        local project_name=$(basename "$project_dir")
                        projects+=("$project_name/")
                    fi
                done
            fi

            # Add options
            options=("--list" "--clean" "--help")

            # Add workspaces and options with space, projects without space
            compadd -a workspaces
            compadd -S '' -a projects
            compadd -a options
        fi
    }

    compdef _ws_zsh_completions ws

    # Completion function for wsc (zsh) - like ws but only workspace names
    _wsc_zsh_completions() {
        local git_root
        git_root=$(git rev-parse --show-toplevel 2>/dev/null)

        local -a workspaces projects options
        local cur="${words[CURRENT]}"

        if [[ "$cur" == */* ]]; then
            local project_prefix="${cur%%/*}"
            local workspace_prefix="${cur#*/}"
            local project_workspace_dir="$WORKSPACE_PATH/$project_prefix"

            if [[ -d "$project_workspace_dir" ]]; then
                for ws_dir in "$project_workspace_dir"/*/; do
                    if [[ -d "$ws_dir" ]]; then
                        local ws_name=$(basename "$ws_dir")
                        workspaces+=("$project_prefix/$ws_name")
                    fi
                done
            fi
            compadd -a workspaces
        elif [[ -z "$git_root" ]]; then
            if [[ -d "$WORKSPACE_PATH" ]]; then
                for project_dir in "$WORKSPACE_PATH"/*/; do
                    if [[ -d "$project_dir" ]]; then
                        local project_name=$(basename "$project_dir")
                        projects+=("$project_name/")
                    fi
                done
            fi
            options=("--help")
            compadd -S '' -a projects
            compadd -a options
        else
            local repo_name=$(basename "$git_root")
            local repo_workspace_dir="$WORKSPACE_PATH/$repo_name"

            if [[ -d "$repo_workspace_dir" ]]; then
                for ws_dir in "$repo_workspace_dir"/*/; do
                    if [[ -d "$ws_dir" ]]; then
                        workspaces+=("$(basename "$ws_dir")")
                    fi
                done
            fi

            if [[ -d "$WORKSPACE_PATH" ]]; then
                for project_dir in "$WORKSPACE_PATH"/*/; do
                    if [[ -d "$project_dir" ]]; then
                        local project_name=$(basename "$project_dir")
                        projects+=("$project_name/")
                    fi
                done
            fi
            options=("--help")
            compadd -a workspaces
            compadd -S '' -a projects
            compadd -a options
        fi
    }

    compdef _wsc_zsh_completions wsc
    compdef _wsc_zsh_completions wss

    _rv_zsh_completions() {
        local -a options
        options=("--help")
        compadd -a options
    }

    compdef _rv_zsh_completions rv
fi
