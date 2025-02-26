{
  # configuration
  image,
  linuxSystem,
}:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    escapeShellArg
    mkAfter
    mkDefault
    mkEnableOption
    mkForce
    mkIf
    mkOption
    optionalAttrs
    optionalString
    types
    ;
in
{
  options.nix-rosetta-builder = {
    enable = (mkEnableOption "Nix Rosetta Linux builder") // {
      default = true;
    };

    cores = mkOption {
      type = types.int;
      default = 8;
      description = ''
        The number of CPU cores allocated to the VM.
        This also sets the maximum number of jobs allowed for the
        builder in the `nix.buildMachines` specification.
      '';
    };

    diskSize = mkOption {
      type = types.str;
      default = "100GiB";
      description = ''
        The size of the disk image for the VM.
      '';
    };

    memory = mkOption {
      type = types.str;
      default = "6GiB";
      description = ''
        The amount of memory to allocate to the VM.
      '';
      example = "8GiB";
    };

    onDemand = mkOption {
      type = types.bool;
      default = false;
      description = ''
        By default, the VM will run all the time as a daemon in the background.  This allows Linux
        builds to start right away, but means the VM is always consuming RAM (and a bit of CPU).

        Alternatively, this option will cause the VM to run only "on-demand": when not in use the VM
        will not be running.  Any Linux build will cause it to automatically start up
        (blocking/pausing the build for several seconds until the VM boots) and after a period of
        time/hours without any active Linux builds, the VM will power itself off.
      '';
    };

    port = mkOption {
      type = types.int;

      # `nix.linux-builder` uses 31022:
      # https://github.com/LnL7/nix-darwin/blob/a35b08d09efda83625bef267eb24347b446c80b8/modules/nix/linux-builder.nix#L199
      # Use a similar, but different one:
      default = 31122;

      description = ''
        The SSH port used by the VM.
      '';
    };
  };

  config =
    let
      inherit (import ./constants.nix)
        name
        linuxHostName
        linuxUser
        sshKeyType
        sshHostPrivateKeyFileName
        sshHostPublicKeyFileName
        sshUserPrivateKeyFileName
        sshUserPublicKeyFileName
        ;

      debugInsecurely = false; # enable root access in VM and debug logging

      imageWithFinalConfig = image.override {
        inherit debugInsecurely;
        onDemand = cfg.onDemand;
      };

      cfg = config.nix-rosetta-builder;
      daemonName = "${name}d";
      daemonSocketName = "Listener";

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

      sshGlobalKnownHostsFileName = "ssh_known_hosts";
      sshHost = name; # no prefix because it's user visible (in `sudo ssh '${sshHost}'`)
      sshHostKeyAlias = "${sshHost}-key";
      workingDirPath = "/var/lib/${name}";

      vmYaml = (pkgs.formats.yaml { }).generate "${name}.yaml" {
        # Prevent ~200MiB unused nerdctl-full*.tar.gz download
        # https://github.com/lima-vm/lima/blob/0e931107cadbcb6dbc7bbb25626f66cdbca1f040/pkg/instance/start.go#L43
        containerd.user = false;

        cpus = cfg.cores;

        disk = cfg.diskSize;

        images = [
          {
            # extension must match `imageFormat`
            location = "${imageWithFinalConfig}/nixos.qcow2";
          }
        ];

        memory = cfg.memory;

        mounts = [
          {
            # order must match `sshdKeysVirtiofsTag`s suffix
            location = "${workingDirPath}/${linuxSshdKeysDirName}";
          }
        ];

        rosetta.enabled = true;

        ssh = {
          launchdSocketName = optionalString cfg.onDemand daemonSocketName;
          localPort = cfg.port;
        };
      };
    in
    mkIf cfg.enable {
      environment.etc."ssh/ssh_config.d/100-${sshHost}.conf".text = ''
        Host "${sshHost}"
          GlobalKnownHostsFile "${workingDirPath}/${sshGlobalKnownHostsFileName}"
          Hostname localhost
          HostKeyAlias "${sshHostKeyAlias}"
          Port "${toString cfg.port}"
          StrictHostKeyChecking yes
          User "${linuxUser}"
          IdentityFile "${workingDirPath}/${sshUserPrivateKeyFileName}"
      '';

      launchd.daemons."${daemonName}" = {
        path = [
          pkgs.coreutils
          pkgs.gnugrep
          (pkgs.lima.overrideAttrs (old: {
            src = pkgs.fetchFromGitHub {
              owner = "cpick";
              repo = "lima";
              rev = "afbfdfb8dd5fa370547b7fc64a16ce2a354b1ff0";
              hash = "sha256-tCildZJp6ls+WxRAbkoeLRb4WdroBYn/gvE5Vb8Hm5A=";
            };

            vendorHash = "sha256-I84971WovhJL/VO/Ycu12qa9lDL3F9USxlt9rXcsnTU=";
          }))
          pkgs.openssh

          # Lima calls `sw_vers` which is not packaged in Nix:
          # https://github.com/lima-vm/lima/blob/0e931107cadbcb6dbc7bbb25626f66cdbca1f040/pkg/osutil/osversion_darwin.go#L13
          # If the call fails it will not use the Virtualization framework bakend (by default? among
          # other things?).
          "/usr/bin"
        ];

        script =
          let
            darwinUserSh = escapeShellArg darwinUser;
            linuxHostNameSh = escapeShellArg linuxHostName;
            linuxSshdKeysDirNameSh = escapeShellArg linuxSshdKeysDirName;
            sshGlobalKnownHostsFileNameSh = escapeShellArg sshGlobalKnownHostsFileName;
            sshHostKeyAliasSh = escapeShellArg sshHostKeyAlias;
            sshHostPrivateKeyFileNameSh = escapeShellArg sshHostPrivateKeyFileName;
            sshHostPublicKeyFileNameSh = escapeShellArg sshHostPublicKeyFileName;
            sshKeyTypeSh = escapeShellArg sshKeyType;
            sshUserPrivateKeyFileNameSh = escapeShellArg sshUserPrivateKeyFileName;
            sshUserPublicKeyFileNameSh = escapeShellArg sshUserPublicKeyFileName;
            vmNameSh = escapeShellArg "${name}-vm";
            vmYamlSh = escapeShellArg vmYaml;
          in
          ''
            set -e
            set -u

            umask 'g-w,o='
            chmod 'g-w,o=' .

            # must be idempotent in the face of partial failues
            cmp -s ${vmYamlSh} .lima/${vmNameSh}/lima.yaml && \
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

              limactl delete --force ${vmNameSh}

              # must be last so `limactl list` only now succeeds
              limactl create --name=${vmNameSh} ${vmYamlSh}
            }

            exec limactl start ${optionalString debugInsecurely "--debug"} --foreground ${vmNameSh}
          '';

        serviceConfig =
          {
            KeepAlive = !cfg.onDemand;

            Sockets."${daemonSocketName}" = optionalAttrs cfg.onDemand {
              SockFamily = "IPv4";
              SockNodeName = "localhost";
              SockServiceName = toString cfg.port;
            };

            UserName = darwinUser;
            WorkingDirectory = workingDirPath;
          }
          // optionalAttrs debugInsecurely {
            StandardErrorPath = "/tmp/${daemonName}.err.log";
            StandardOutPath = "/tmp/${daemonName}.out.log";
          };
      };

      nix = {
        buildMachines = [
          {
            hostName = sshHost;
            maxJobs = cfg.cores;
            protocol = "ssh-ng";
            supportedFeatures = [
              "benchmark"
              "big-parallel"
              "kvm"
              "nixos-test"
            ];
            systems = [
              linuxSystem
              "x86_64-linux"
            ];
          }
        ];

        distributedBuilds = mkForce true;
        settings.builders-use-substitutes = mkDefault true;
      };

      # `users.users` cannot create a service account and cannot create an empty home directory so do
      # it manually in an activation script.  This `extraActivation` was chosen in particiular because
      # it's one of the system level (as opposed to user level) ones that's been set aside for
      # customization:
      # https://github.com/LnL7/nix-darwin/blob/a35b08d09efda83625bef267eb24347b446c80b8/modules/system/activation-scripts.nix#L121-L125
      # And of those, it's the one that's executed latest but still before
      # `activationScripts.launchd` which needs the group, user, and directory in place:
      # https://github.com/LnL7/nix-darwin/blob/a35b08d09efda83625bef267eb24347b446c80b8/modules/system/activation-scripts.nix#L58-L66
      system.activationScripts.extraActivation.text =
        let
          gidSh = escapeShellArg (toString darwinGid);
          groupSh = escapeShellArg darwinGroup;
          groupPathSh = escapeShellArg "/Groups/${darwinGroup}";

          uidSh = escapeShellArg (toString darwinUid);
          userSh = escapeShellArg darwinUser;
          userPathSh = escapeShellArg "/Users/${darwinUser}";

          workingDirPathSh = escapeShellArg workingDirPath;
        in
        # apply "after" to work cooperatively with any other modules using this activation script
        mkAfter ''
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
}
