{
  description = "ws - Workspace manager for git repositories";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    in
    {
      packages = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = self.packages.${system}.workspacer;

          workspacer = pkgs.stdenvNoCC.mkDerivation {
            pname = "workspacer";
            version = "0.1.0";

            src = ./.;

            installPhase = ''
              mkdir -p $out/share/workspacer
              cp ws.sh $out/share/workspacer/ws.sh
            '';

            meta = with pkgs.lib; {
              description = "Workspace manager for git repositories";
              homepage = "https://github.com/elsirion/workspacer";
              license = licenses.mit;
              platforms = platforms.unix;
            };
          };
        });

      nixosModules.default = { config, lib, pkgs, ... }:
        let
          cfg = config.programs.workspacer;
          workspacerPkg = self.packages.${pkgs.system}.workspacer;
        in
        {
          options.programs.workspacer = {
            enable = lib.mkEnableOption "workspacer - workspace manager for git repositories";

            workspacePath = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Custom workspace path. Defaults to $XDG_DATA_HOME/workspaces";
              example = "$HOME/workspaces";
            };
          };

          config = lib.mkIf cfg.enable {
            programs.bash.interactiveShellInit = ''
              ${lib.optionalString (cfg.workspacePath != null) ''
                export WORKSPACE_PATH="${cfg.workspacePath}"
              ''}
              source "${workspacerPkg}/share/workspacer/ws.sh"
            '';

            programs.zsh.interactiveShellInit = ''
              ${lib.optionalString (cfg.workspacePath != null) ''
                export WORKSPACE_PATH="${cfg.workspacePath}"
              ''}
              source "${workspacerPkg}/share/workspacer/ws.sh"
            '';
          };
        };
    };
}
