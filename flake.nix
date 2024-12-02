{
  description = "Lima-based, Rosetta 2-enabled, macOS (Darwin) builder";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixos-generators, nixpkgs }:
  let
    system = "aarch64-darwin";
    pkgs = nixpkgs.legacyPackages."${system}";
    linuxSystem = builtins.replaceStrings [ "darwin" ] [ "linux" ] system;

  in {
    packages."${linuxSystem}".default = nixos-generators.nixosGenerate {
      format = "raw-efi";
      modules = [
        {
          imports = [
            (nixpkgs + "/nixos/modules/profiles/qemu-guest.nix")
          ];
          # FIXME: ?
          # nix.registry.nixpkgs.flake = nixpkgs;
          # virtualisation.diskSize = 10 * 1024;
          # virtualisation.rosetta.enable = true;

          # boot.loader = {
          #   systemd-boot.enable = true; 
          #   efi.canTouchEfiVariables = true;
          # };
          boot.loader.grub = {
            device = "nodev";
            efiSupport = true;
            efiInstallAsRemovable = true;
          };

          services.openssh = {
            enable = true;
            settings.PermitRootLogin = "yes";
          };

          users.users.root.password = "nixos"; # FIXME:

          fileSystems."/boot" = {
            device = "/dev/disk/by-label/ESP"; # /dev/vda1
            fsType = "vfat";
          };

          fileSystems."/" = {
            device = "/dev/disk/by-label/nixos";
            autoResize = true;
            fsType = "ext4";
            options = ["noatime" "nodiratime" "discard"];
          };

        }
      ];
      system = linuxSystem;
    };

    devShells."${system}".default = pkgs.mkShell { packages = [
      pkgs.lima
    ]; };
  };
}