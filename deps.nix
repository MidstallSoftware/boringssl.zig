# generated by zon2nix (https://github.com/nix-community/zon2nix)

{ linkFarm, fetchzip }:

linkFarm "zig-packages" [
  {
    name = "12201cad8e77deaaa1702718e70346a30f4b54d169e9152a696621d098edb093d4f3";
    path = fetchzip {
      url = "https://github.com/google/boringssl/archive/2635bedc5d12407e4e78f2250d9c8c534954e045.tar.gz";
      hash = "sha256-ZrOk7GUTMBD6Mtr3Za3LcS3s23+OljRY1fJXTyqqGpk=";
    };
  }
]