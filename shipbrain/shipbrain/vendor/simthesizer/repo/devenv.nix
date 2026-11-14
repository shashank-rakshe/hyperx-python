{ lib, pkgs, ... }:

let
  pythonVersion = lib.trim (builtins.readFile ./.python-version);
in
{
  languages.rust.enable = true;
  languages.python = {
    enable = true;
    package = pkgs.${"python" + lib.replaceStrings [ "." ] [ "" ] pythonVersion};
    venv.enable = true;
    uv = {
      enable = true;
      sync = {
        enable = true;
        arguments = [ "--locked" ];
      };
    };
  };

  profiles.vllm.module =
    let
      # Match the CUDA release used by PyTorch in uv.lock.
      cuda = pkgs.cudaPackages_13_0;
      toolkit = pkgs.symlinkJoin {
        name = "cuda-jit-${cuda.cudaMajorMinorVersion}";
        paths = lib.concatMap (package: map (output: package.${output}) package.outputs) [
          cuda.cuda_nvcc
          cuda.cuda_crt
          cuda.cuda_cudart
          cuda.cuda_cccl
          cuda.cuda_nvrtc
          cuda.libcurand
        ];
        postBuild = ''
          ln -s lib "$out/lib64"
        '';
      };
    in
    {
      languages.python.uv.sync.groups = [ "vllm" ];
      packages = [
        toolkit
        pkgs.ninja
      ];
      env = {
        CUDA_HOME = "${toolkit}";
      };
      # Use the host driver; the Toolkit only supplies link-time stubs.
      enterShell = ''
        driverLib="$DEVENV_STATE/nvidia"
        mkdir -p "$driverLib"
        while read -r driverSoname driverPath; do
          ln -sfn "$driverPath" "$driverLib/$driverSoname"
        done < <(
          (${pkgs.glibc.bin}/bin/ldconfig -p -C /etc/ld.so.cache 2>/dev/null || true) |
            ${pkgs.gawk}/bin/awk '$1 ~ /^lib(cuda|nvidia-[^.]+)\.so/ && !seen[$1]++ { print $1, $NF }'
        )
        export LD_LIBRARY_PATH="$driverLib:/run/opengl-driver/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        unset driverLib driverSoname driverPath
      '';
    };
}
