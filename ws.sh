#!/bin/bash
# ws - Workspace manager for git repositories
# Source this file in your shell rc file: source /path/to/ws.sh

# Default workspace path follows XDG Base Directory Specification
: "${WORKSPACE_PATH:=${XDG_DATA_HOME:-$HOME/.local/share}/workspaces}"

ws() {
    local workspace_name="$1"

    # Ensure we're in a git repository (or workspace)
    local git_root
    git_root=$(git rev-parse --show-toplevel 2>/dev/null)
    if [[ -z "$git_root" ]]; then
        echo "Error: Not in a git repository" >&2
        return 1
    fi

    # No argument: go back to main repo directory
    if [[ -z "$workspace_name" ]]; then
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

    # Handle --list option
    if [[ "$workspace_name" == "--list" || "$workspace_name" == "-l" ]]; then
        _ws_list_workspaces
        return 0
    fi

    # Handle --clean option: delete workspaces without changes
    if [[ "$workspace_name" == "--clean" || "$workspace_name" == "-c" ]]; then
        _ws_clean_workspaces
        return $?
    fi

    # Get the repo name from the git root directory
    local repo_name
    repo_name=$(basename "$git_root")

    # Workspace directory path
    local workspace_dir="$WORKSPACE_PATH/$repo_name/$workspace_name"

    # Create workspace if it doesn't exist
    if [[ ! -d "$workspace_dir" ]]; then
        echo "Creating new workspace: $workspace_dir"

        # Create parent directory
        mkdir -p "$(dirname "$workspace_dir")"

        # Clone/worktree the repository
        # Use git worktree for efficiency (shares .git objects)
        if git -C "$git_root" worktree add "$workspace_dir" -b "_ws_temp_$$" 2>/dev/null; then
            # Remove the temporary branch, we'll create the proper one later
            git -C "$workspace_dir" branch -D "_ws_temp_$$" 2>/dev/null || true
        else
            # Fallback: clone the repository
            echo "Creating workspace via clone..."
            git clone "$git_root" "$workspace_dir"
            if [[ $? -ne 0 ]]; then
                echo "Error: Failed to create workspace" >&2
                return 1
            fi
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

# Completion function for bash
_ws_completions() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local git_root
    git_root=$(git rev-parse --show-toplevel 2>/dev/null)

    if [[ -z "$git_root" ]]; then
        return
    fi

    local repo_name
    repo_name=$(basename "$git_root")

    local repo_workspace_dir="$WORKSPACE_PATH/$repo_name"

    local workspaces=()
    if [[ -d "$repo_workspace_dir" ]]; then
        for ws_dir in "$repo_workspace_dir"/*/; do
            if [[ -d "$ws_dir" ]]; then
                workspaces+=("$(basename "$ws_dir")")
            fi
        done
    fi

    # Add options
    workspaces+=("--list" "--clean")

    COMPREPLY=($(compgen -W "${workspaces[*]}" -- "$cur"))
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

        if [[ -z "$git_root" ]]; then
            return
        fi

        local repo_name
        repo_name=$(basename "$git_root")

        local repo_workspace_dir="$WORKSPACE_PATH/$repo_name"

        local workspaces=()
        if [[ -d "$repo_workspace_dir" ]]; then
            for ws_dir in "$repo_workspace_dir"/*/; do
                if [[ -d "$ws_dir" ]]; then
                    workspaces+=("$(basename "$ws_dir")")
                fi
            done
        fi

        # Add options
        workspaces+=("--list" "--clean")

        _describe 'workspace' workspaces
    }

    compdef _ws_zsh_completions ws
fi
