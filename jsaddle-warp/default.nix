{ mkDerivation, aeson, base, bytestring, containers, deepseq
, doctest, filepath, ghc-prim, http-types, jsaddle, lens, primitive
, process, QuickCheck, ref-tf, stdenv, stm, text, time
, transformers, wai, wai-websockets, warp, websockets
, darwin, webdriver, phantomjs, ghc
}:
mkDerivation {
  pname = "jsaddle-warp";
  version = "0.9.0.0";
  src = builtins.filterSource (path: type: !(builtins.elem (baseNameOf path) [ ".git" "dist" ])) ./.;
  libraryHaskellDepends = [
    aeson base containers http-types jsaddle stm text time transformers
    wai wai-websockets warp websockets
  ];
  testHaskellDepends = [
    base bytestring deepseq doctest filepath ghc-prim jsaddle lens
    primitive process QuickCheck ref-tf webdriver phantomjs
  ];
  testTarget = "--test-option=${jsaddle.src}";
  description = "Interface for JavaScript that works with GHCJS and GHC";
  license = stdenv.lib.licenses.mit;
}
