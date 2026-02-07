# nix-rosetta-builder

A [Rosetta 2](https://developer.apple.com/documentation/virtualization/running_intel_binaries_in_linux_vms_with_rosetta)-enabled,
Apple silicon (macOS/Darwin)-hosted Linux
[Nix builder](https://nix.dev/manual/nix/2.18/advanced-topics/distributed-builds).

Runs on aarch64-darwin and builds aarch64-linux (natively) and x86_64-linux (quickly using Rosetta
2).

## Features

Advantages over nix-darwin's built in
[`nix.linux-builder`](https://daiderd.com/nix-darwin/manual/index.html#opt-nix.linux-builder.enable)
(which is based on
[`pkgs.darwin.linux-builder`](https://nixos.org/manual/nixpkgs/stable/#sec-darwin-builder)):

* x86_64-linux support enabled by default and much faster (using Rosetta 2)
* Multi-core by default
* Optionally runs VM on-demand, powering off when idle (see: `nix-rosetta-builder.onDemand` option)
* More secure:
  * VM runs with minimum permissions (runs as a non-root/admin/wheel user/service account)
  * VM doesn't accept remote connections (it binds to the loopback interface (127.0.0.1))
  * VM cannot be impersonated (its private SSH host key is not publicly-known)

## nix-darwin flake setup

flake.nix:
```nix
{
  description = "Configure macOS using nix-darwin with rosetta-builder";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    nix-darwin = {
      url = "github:lnl7/nix-darwin";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-rosetta-builder = {
      url = "github:cpick/nix-rosetta-builder";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs@{ self, nix-darwin, nix-rosetta-builder, nixpkgs }: {
    darwinConfigurations."${hostname}" = nix-darwin.lib.darwinSystem {
      modules = [
        # An existing Linux builder is needed to initially bootstrap `nix-rosetta-builder`.
        # If one isn't already available: comment out the `nix-rosetta-builder` module below,
        # uncomment this `linux-builder` module, and run `darwin-rebuild switch`:
        # { nix.linux-builder.enable = true; }
        # Then: uncomment `nix-rosetta-builder`, remove `linux-builder`, and `darwin-rebuild switch`
        # a second time. Subsequently, `nix-rosetta-builder` can rebuild itself.
        nix-rosetta-builder.darwinModules.default
        {
          # see available options in module.nix's `options.nix-rosetta-builder`
          nix-rosetta-builder.onDemand = true;
        }
      ];
    };
  };
}
```

## Rosetta dependency

`nix-rosetta-builder` depends on macOS having `rosetta` installed:
```
softwareupdate --install-rosetta
```

## Uninstall

1. Set `nix-rosetta-builder.enable = false` in the nix-darwin configuration and run
   `darwin-rebuild switch` to clean up resources (including VM, user, group, storage, etc)
2. Optionally remove `nix-rosetta-builder` from the nix-darwin configuration

## Contributing

Feature requests, bug reports, and pull requests are all welcome.
