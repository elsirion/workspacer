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

Workspaces are stored in $WORKSPACE_PATH (default: ~/.local/share/workspaces)
organized by repository name.

When entering a workspace, a branch named <year>-<month>-<name> is created
or checked out, and direnv is allowed if .envrc exists.

The <project>/<workspace> syntax allows you to enter workspaces from any directory,
even when not in a git repository. The project name is the repository directory name.

Use 'popd' to return to the previous directory after entering a workspace.
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

# Register bash completion
if [[ -n "$BASH_VERSION" ]]; then
    complete -F _ws_completions ws
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
fi
