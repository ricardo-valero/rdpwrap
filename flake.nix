{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };
  outputs = {nixpkgs, ...}: let
    systems = nixpkgs.lib.systems.flakeExposed;
  in {
    devShells = nixpkgs.lib.genAttrs systems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.mkShell {
        packages = builtins.attrValues {
          inherit (pkgs) nixd alejandra;
          inherit (pkgs) git gh;
          inherit (pkgs) zig;
          python = pkgs.python3.withPackages (p: builtins.attrValues {inherit (p) uv;});
        };
        shellHook = ''
          if [ ! -d .venv ]; then
            uv venv .venv
          fi
          source .venv/bin/activate
          uv sync --quiet 2>/dev/null
        '';
      };
    });
  };
}
