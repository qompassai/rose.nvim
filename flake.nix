# /qompassai/rose.nvim/flake.nix
# -------------------------------------
# Copyright (C) 2025 Qompass AI, All rights reserved

{
  description = "Qompass AI rose.nvim Flake";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";

  outputs = { self, nixpkgs }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
  in {
    devShells.${system}.default = pkgs.mkShell {
      packages = [
        pkgs.lua5_1
        pkgs.luajit
      ];
      shellHook = ''
        echo "Lua 5.1: $(lua5.1 -v)"
        echo "LuaJIT: $(luajit -v)"
      '';
    };
  };
}
