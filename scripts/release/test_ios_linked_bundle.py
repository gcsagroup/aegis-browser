"""Exercise missing and swapped carriers using a completed native Xcode build."""
import argparse
from pathlib import Path
from shutil import copy2
import tempfile

from ios_embedded_core import verify_bundle


def check(bundle, products, derived, platform):
    verify_bundle(bundle, products, derived, platform)
    with tempfile.TemporaryDirectory() as directory:
        clone = Path(directory) / bundle.name
        frame = Path("Frameworks/AccessKit.framework")
        (clone / frame).mkdir(parents=True)
        for relative in ("Aegis", frame / "embedded-core-lock.json", frame / "embedded-core-build.json"):
            copy2(bundle / relative, clone / relative)
        if (bundle / "Aegis.debug.dylib").exists():
            copy2(bundle / "Aegis.debug.dylib", clone)
        carrier = clone / frame / "AccessKit"
        for problem in ("missing", "swapped"):
            if problem == "swapped":
                copy2(bundle / "Frameworks/BrowserKit.framework/BrowserKit", carrier)
            try:
                verify_bundle(clone, products, derived, platform)
            except (FileNotFoundError, ValueError) as error:
                print(f"Rejected {problem} core carrier: {error}")
            else:
                raise AssertionError(f"accepted {problem} core carrier")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for argument in ["bundle", "products", "derived"]:
        parser.add_argument(argument, type=Path)
    parser.add_argument("platform", choices=("simulator", "device"))
    args = parser.parse_args()
    check(args.bundle, args.products, args.derived, args.platform)
