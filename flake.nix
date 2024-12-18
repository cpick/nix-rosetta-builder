{
  description = "Lima-based, Rosetta 2-enabled, Apple silicon (macOS/Darwin)-hosted Linux builder";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixos-generators, nixpkgs }:
  let
    darwinSystem = "aarch64-darwin";
    linuxSystem = builtins.replaceStrings [ "darwin" ] [ "linux" ] darwinSystem;
    lib = nixpkgs.lib;

    name = "rosetta-builder"; # update `darwinGroup` if adding or removing special characters
    linuxHostName = name; # no prefix because it's user visible (on prompt when `ssh`d in)
    linuxUser = "builder"; # follow linux-builder/darwin-builder precedent

    sshKeyType = "ed25519";
    sshHostPrivateKeyFileName = "ssh_host_${sshKeyType}_key";
    sshHostPublicKeyFileName = "${sshHostPrivateKeyFileName}.pub";
    sshUserPrivateKeyFileName = "ssh_user_${sshKeyType}_key";
    sshUserPublicKeyFileName = "${sshUserPrivateKeyFileName}.pub";

    debug = false; # enable root access in VM and debug logging

  in {
    packages."${linuxSystem}".default = nixos-generators.nixosGenerate (
    let
      imageFormat = "qcow-efi"; # must match `vmYaml.images.location`s extension
      pkgs = nixpkgs.legacyPackages."${linuxSystem}";

      sshdKeys = "sshd-keys";
      sshDirPath = "/etc/ssh";
      sshHostPrivateKeyFilePath = "${sshDirPath}/${sshHostPrivateKeyFileName}";

    in {
      format = imageFormat;

      modules = [ {
        boot = {
          kernelParams = [ "console=tty0" ];

          loader = {
            efi.canTouchEfiVariables = true;
            systemd-boot.enable = true; 
          };
        };

        documentation.enable = false;

        fileSystems = {
          "/".options = [ "discard" "noatime" ];
          "/boot".options = [ "discard" "noatime" "umask=0077" ];
        };

        networking.hostName = linuxHostName;

        nix = {
          channel.enable = false;
          registry.nixpkgs.flake = nixpkgs;

          settings = {
            auto-optimise-store = true;
            experimental-features = [ "flakes" "nix-command" ];
            min-free = "5G";
            max-free = "7G";
            trusted-users = [ linuxUser ];
          };
        };

        security = {
          sudo = {
            enable = debug;
            wheelNeedsPassword = !debug;
          };
        };

        services = {
          getty = lib.optionalAttrs debug { autologinUser = linuxUser; };

          openssh = {
            enable = true;
            hostKeys = []; # disable automatic host key generation

            settings = {
              HostKey = sshHostPrivateKeyFilePath;
              PasswordAuthentication = false;
            };
          };
        };

        system = {
          disableInstallerTools = true;
          stateVersion = "24.05";
        };

        # macOS' Virtualization framework's virtiofs implementation will grant any guest user access
        # to mounted files; they always appear to be owned by the effective UID and so access cannot
        # be restricted.
        # To protect the guest's SSH host key, the VM is configured to prevent any logins (via
        # console, SSH, etc) by default.  This service then runs before sshd, mounts virtiofs,
        # copies the keys to local files (with appropriate ownership and permissions), and unmounts
        # the filesystem before allowing SSH to start.
        # Once SSH has been allowed to start (and given the guest user a chance to log in), the
        # virtiofs must never be mounted again (as the user could have left some process active to
        # read its secrets).  This is prevented by `unitconfig.ConditionPathExists` below.
        systemd.services."${sshdKeys}" =
        let
          # Lima labels its virtiofs folder mounts counting up:
          # https://github.com/lima-vm/lima/blob/0e931107cadbcb6dbc7bbb25626f66cdbca1f040/pkg/vz/vm_darwin.go#L568
          # So this suffix must match `vmYaml.mounts.location`s order:
          sshdKeysVirtiofsTag = "mount0";

          sshdKeysDirPath = "/var/${sshdKeys}";
          sshAuthorizedKeysUserFilePath = "${sshDirPath}/authorized_keys.d/${linuxUser}";
          sshdService = "sshd.service";

        in {
          before = [ sshdService ];
          description = "Install sshd's host and authorized keys";
          enableStrictShellChecks = true;
          path = [ pkgs.mount pkgs.umount ];
          requiredBy = [ sshdService ];

          script =
          let
            sshAuthorizedKeysUserFilePathSh = lib.escapeShellArg sshAuthorizedKeysUserFilePath;
            sshAuthorizedKeysUserTmpFilePathSh =
              lib.escapeShellArg "${sshAuthorizedKeysUserFilePath}.tmp";
            sshHostPrivateKeyFileNameSh = lib.escapeShellArg sshHostPrivateKeyFileName;
            sshHostPrivateKeyFilePathSh = lib.escapeShellArg sshHostPrivateKeyFilePath;
            sshUserPublicKeyFileNameSh = lib.escapeShellArg sshUserPublicKeyFileName;
            sshdKeysDirPathSh = lib.escapeShellArg sshdKeysDirPath;
            sshdKeysVirtiofsTagSh = lib.escapeShellArg sshdKeysVirtiofsTag;

          in ''
            # must be idempotent in the face of partial failues

            mkdir -p ${sshdKeysDirPathSh}
            mount \
              -t 'virtiofs' \
              -o 'nodev,noexec,nosuid,ro' \
              ${sshdKeysVirtiofsTagSh} \
              ${sshdKeysDirPathSh}

            mkdir -p "$(dirname ${sshHostPrivateKeyFilePathSh})"
            (
              umask 'go='
              cp ${sshdKeysDirPathSh}/${sshHostPrivateKeyFileNameSh} ${sshHostPrivateKeyFilePathSh}
            )

            mkdir -p "$(dirname ${sshAuthorizedKeysUserTmpFilePathSh})"
            cp \
              ${sshdKeysDirPathSh}/${sshUserPublicKeyFileNameSh} \
              ${sshAuthorizedKeysUserTmpFilePathSh}
            chmod 'a+r' ${sshAuthorizedKeysUserTmpFilePathSh}

            umount ${sshdKeysDirPathSh}
            rmdir ${sshdKeysDirPathSh}

            # must be last so only now `unitConfig.ConditionPathExists` triggers
            mv ${sshAuthorizedKeysUserTmpFilePathSh} ${sshAuthorizedKeysUserFilePathSh}
          '';

          serviceConfig.Type = "oneshot";

          # see comments on this service and in its `script`
          unitConfig.ConditionPathExists = "!${sshAuthorizedKeysUserFilePath}";
        };

        users = {
          # console and (initial) SSH logins are purposely disabled
          # see: `systemd.services."${sshdKeys}"`
          allowNoPasswordLogin = true;

          mutableUsers = false;

          users."${linuxUser}" = {
            isNormalUser = true;
            extraGroups = lib.optionals debug [ "wheel" ];
          };
        };

        virtualisation.rosetta = {
          enable = true;

          # Lima's virtiofs label for rosetta:
          # https://github.com/lima-vm/lima/blob/0e931107cadbcb6dbc7bbb25626f66cdbca1f040/pkg/vz/rosetta_directory_share_arm64.go#L15
          mountTag = "vz-rosetta";
        };
      } ];

      system = linuxSystem;
    });

    devShells."${darwinSystem}".default =
    let
      pkgs = nixpkgs.legacyPackages."${darwinSystem}";
    in pkgs.mkShell {
      packages = [ pkgs.lima ];
    };

    darwinModules.default = { lib, pkgs, ... }:
    let
      cores = 8;
      daemonName = "${name}d";

      # `sysadminctl -h` says role account UIDs (no mention of service accounts or GIDs) should be
      # in the 200-400 range `mkuser`s README.md mentions the same:
      # https://github.com/freegeek-pdx/mkuser/blob/b7a7900d2e6ef01dfafad1ba085c94f7302677d9/README.md?plain=1#L413-L437
      # Determinate's `nix-installer` (and, I believe, current versions of the official one) uses a
      # variable number starting at 350 and up:
      # https://github.com/DeterminateSystems/nix-installer/blob/6beefac4d23bd9a0b74b6758f148aa24d6df3ca9/README.md?plain=1#L511-L514
      # Meanwhile, new macOS versions are installing accounts that encroach from below.
      # Try to fit in between:
      darwinGid = 349;
      darwinUid = darwinGid;

      darwinGroup = builtins.replaceStrings [ "-" ] [ "" ] name; # keep in sync with `name`s format
      darwinUser = "_${darwinGroup}";
      linuxSshdKeysDirName = "linux-sshd-keys";

      # `nix.linux-builder` uses 31022:
      # https://github.com/LnL7/nix-darwin/blob/a35b08d09efda83625bef267eb24347b446c80b8/modules/nix/linux-builder.nix#L199
      # Use a similar, but different one:
      port = 31122;

      sshGlobalKnownHostsFileName = "ssh_known_hosts";
      sshHost = name; # no prefix because it's user visible (in `sudo ssh '${sshHost}'`)
      sshHostKeyAlias = "${sshHost}-key";
      workingDirPath = "/var/lib/${name}";

      vmYaml = (pkgs.formats.yaml {}).generate "${name}.yaml" {
        # Prevent ~200MiB unused nerdctl-full*.tar.gz download
        # https://github.com/lima-vm/lima/blob/0e931107cadbcb6dbc7bbb25626f66cdbca1f040/pkg/instance/start.go#L43
        containerd.user = false;

        cpus = cores;

        images = [{
          # extension must match `imageFormat`
          location = "${self.packages."${linuxSystem}".default}/nixos.qcow2";
        }];

        memory = "6GiB";

        mounts = [{
          # order must match `sshdKeysVirtiofsTag`s suffix
          location = "${workingDirPath}/${linuxSshdKeysDirName}";
        }];

        rosetta.enabled = true;
        ssh.localPort = port;
      };

    in {
      environment.etc."ssh/ssh_config.d/100-${sshHost}.conf".text = ''
        Host "${sshHost}"
          GlobalKnownHostsFile "${workingDirPath}/${sshGlobalKnownHostsFileName}"
          Hostname localhost
          HostKeyAlias "${sshHostKeyAlias}"
          Port "${toString port}"
          StrictHostKeyChecking yes
          User "${linuxUser}"
          IdentityFile "${workingDirPath}/${sshUserPrivateKeyFileName}"
      '';

      launchd.daemons."${daemonName}" = {
        path = [
          pkgs.coreutils
          pkgs.gnugrep
          pkgs.lima
          pkgs.openssh

          # Lima calls `sw_vers` which is not packaged in Nix:
          # https://github.com/lima-vm/lima/blob/0e931107cadbcb6dbc7bbb25626f66cdbca1f040/pkg/osutil/osversion_darwin.go#L13
          # If the call fails it will not use the Virtualization framework bakend (by default? among
          # other things?).
          "/usr/bin/"
        ];

        script =
        let
          darwinUserSh = lib.escapeShellArg darwinUser;
          linuxHostNameSh = lib.escapeShellArg linuxHostName;
          linuxSshdKeysDirNameSh = lib.escapeShellArg linuxSshdKeysDirName;
          sshGlobalKnownHostsFileNameSh = lib.escapeShellArg sshGlobalKnownHostsFileName;
          sshHostKeyAliasSh = lib.escapeShellArg sshHostKeyAlias;
          sshHostPrivateKeyFileNameSh = lib.escapeShellArg sshHostPrivateKeyFileName;
          sshHostPublicKeyFileNameSh = lib.escapeShellArg sshHostPublicKeyFileName;
          sshKeyTypeSh = lib.escapeShellArg sshKeyType;
          sshUserPrivateKeyFileNameSh = lib.escapeShellArg sshUserPrivateKeyFileName;
          sshUserPublicKeyFileNameSh = lib.escapeShellArg sshUserPublicKeyFileName;
          vmNameSh = lib.escapeShellArg "${name}-vm";
          vmYamlSh = lib.escapeShellArg vmYaml;

        in ''
          set -e
          set -u

          umask 'g-w,o='
          chmod 'g-w,o=' .

          # must be idempotent in the face of partial failues
          limactl list -q 2>'/dev/null' | grep -q ${vmNameSh} || {
            yes | ssh-keygen \
              -C ${darwinUserSh}@darwin -f ${sshUserPrivateKeyFileNameSh} -N "" -t ${sshKeyTypeSh}
            yes | ssh-keygen \
              -C root@${linuxHostNameSh} -f ${sshHostPrivateKeyFileNameSh} -N "" -t ${sshKeyTypeSh}

            mkdir -p ${linuxSshdKeysDirNameSh}
            mv \
              ${sshUserPublicKeyFileNameSh} ${sshHostPrivateKeyFileNameSh} ${linuxSshdKeysDirNameSh}

            echo ${sshHostKeyAliasSh} "$(cat ${sshHostPublicKeyFileNameSh})" \
            >${sshGlobalKnownHostsFileNameSh}

            # must be last so `limactl list` only now succeeds
            limactl create --name=${vmNameSh} ${vmYamlSh}
          }

          exec limactl start ${lib.optionalString debug "--debug"} --foreground ${vmNameSh}
        '';

        serviceConfig = {
          KeepAlive = true;
          RunAtLoad = true;
          UserName = darwinUser;
          WorkingDirectory = workingDirPath;
        } // lib.optionalAttrs debug {
          StandardErrorPath = "/tmp/${daemonName}.err.log";
          StandardOutPath = "/tmp/${daemonName}.out.log";
        };
      };

      nix = {
        buildMachines = [{
          hostName = sshHost;
          maxJobs = cores;
          protocol = "ssh-ng";
          supportedFeatures = [ "benchmark" "big-parallel" "kvm" ];
          systems = [ linuxSystem "x86_64-linux" ];
        }];

        distributedBuilds = true;
        settings.builders-use-substitutes = true;
      };

      # `users.users` cannot create a service account and cannot create an empty home directory so do it
      # manually in an activation script.  This `extraActivation` was chosen in particiular because it's one of the system level (as opposed to user level) ones that's been set aside for customization:
      # https://github.com/LnL7/nix-darwin/blob/a35b08d09efda83625bef267eb24347b446c80b8/modules/system/activation-scripts.nix#L121-L125
      # And of those, it's the one that's executed latest but still before
      # `activationScripts.launchd` which needs the group, user, and directory in place:
      # https://github.com/LnL7/nix-darwin/blob/a35b08d09efda83625bef267eb24347b446c80b8/modules/system/activation-scripts.nix#L58-L66
      system.activationScripts.extraActivation.text =
      let
        gidSh = lib.escapeShellArg (toString darwinGid);
        groupSh = lib.escapeShellArg darwinGroup;
        groupPathSh = lib.escapeShellArg "/Groups/${darwinGroup}";

        uidSh = lib.escapeShellArg (toString darwinUid);
        userSh = lib.escapeShellArg darwinUser;
        userPathSh = lib.escapeShellArg "/Users/${darwinUser}";

        workingDirPathSh = lib.escapeShellArg workingDirPath;

      # apply "after" to work cooperatively with any other modules using this activation script
      in lib.mkAfter ''
        printf >&2 'setting up group %s...\n' ${groupSh}

        if ! primaryGroupId="$(dscl . -read ${groupPathSh} 'PrimaryGroupID' 2>'/dev/null')" ; then
          printf >&2 'creating group %s...\n' ${groupSh}
          dscl . -create ${groupPathSh} 'PrimaryGroupID' ${gidSh}
        elif [[ "$primaryGroupId" != *\ ${gidSh} ]] ; then
          printf >&2 \
            '\e[1;31merror: existing group: %s has unexpected %s\e[0m\n' \
            ${groupSh} \
            "$primaryGroupId"
          exit 1
        fi
        unset 'primaryGroupId'


        printf >&2 'setting up user %s...\n' ${userSh}

        if ! uid="$(id -u ${userSh} 2>'/dev/null')" ; then
          printf >&2 'creating user %s...\n' ${userSh}
          dscl . -create ${userPathSh}
          dscl . -create ${userPathSh} 'PrimaryGroupID' ${gidSh}
          dscl . -create ${userPathSh} 'NFSHomeDirectory' ${workingDirPathSh}
          dscl . -create ${userPathSh} 'UserShell' '/usr/bin/false'
          dscl . -create ${userPathSh} 'IsHidden' 1
          dscl . -create ${userPathSh} 'UniqueID' ${uidSh} # must be last so `id` only now succeeds
        elif [ "$uid" -ne ${uidSh} ] ; then
          printf >&2 \
            '\e[1;31merror: existing user: %s has unexpected UID: %s\e[0m\n' \
            ${userSh} \
            "$uid"
          exit 1
        fi
        unset 'uid'


        printf >&2 'setting up working directory %s...\n' ${workingDirPathSh}
        mkdir -p ${workingDirPathSh}
        chown ${userSh}:${groupSh} ${workingDirPathSh}
      '';

    };
  };
}
