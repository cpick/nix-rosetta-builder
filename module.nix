# configuration
{ images
, linuxSystem
}:
{ config, lib, pkgs, ... }: {
  options.nix-rosetta-builder = {
    enable = (lib.mkEnableOption "Nix Rosetta Linux builder") // { default = true; };

    onDemand = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        FIXME
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

      debug
      ;
    cfg = config.nix-rosetta-builder;
    cores = 8;
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
        location = "${if cfg.onDemand then images.on-demand else images.default}/nixos.qcow2";
      }];

      memory = "6GiB";

      mounts = [{
        # order must match `sshdKeysVirtiofsTag`s suffix
        location = "${workingDirPath}/${linuxSshdKeysDirName}";
      }];

      rosetta.enabled = true;
      ssh = {
        launchdSocketName = lib.optionalString cfg.onDemand daemonSocketName;
        localPort = port;
      };
    };

  in lib.mkIf cfg.enable {
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

        exec limactl start ${lib.optionalString debug "--debug"} --foreground ${vmNameSh}
      '';

      serviceConfig = {
        KeepAlive = !cfg.onDemand;

        Sockets."${daemonSocketName}" = lib.optionalAttrs cfg.onDemand {
          SockFamily = "IPv4";
          SockNodeName = "localhost";
          SockServiceName = toString port;
        };

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
        supportedFeatures = [ "benchmark" "big-parallel" "kvm" "nixos-test" ];
        systems = [ linuxSystem "x86_64-linux" ];
      }];

      distributedBuilds = true;
      settings.builders-use-substitutes = true;
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
}
