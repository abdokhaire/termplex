{pkgs, ...}: {
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  documentation.nixos.enable = false;

  virtualisation.vmVariant = {
    virtualisation.memorySize = 2048;
  };

  nix = {
    settings = {
      trusted-users = [
        "root"
        "termplex"
      ];
    };
    extraOptions = ''
      experimental-features = nix-command flakes
    '';
  };

  users.mutableUsers = false;

  users.groups.termplex = {};

  users.users.termplex = {
    isNormalUser = true;
    description = "Termplex";
    group = "termplex";
    extraGroups = ["wheel"];
    hashedPassword = "";
  };

  environment.systemPackages = [
    pkgs.kitty
    pkgs.fish
    pkgs.termplex
    pkgs.helix
    pkgs.neovim
    pkgs.xterm
    pkgs.zsh
  ];

  security.polkit = {
    enable = true;
  };

  services.dbus = {
    enable = true;
  };

  services.displayManager = {
    autoLogin = {
      enable = true;
      user = "termplex";
    };
  };

  services.libinput = {
    enable = true;
  };

  services.qemuGuest = {
    enable = true;
  };

  services.spice-vdagentd = {
    enable = true;
  };

  services.xserver = {
    enable = true;
  };
}
