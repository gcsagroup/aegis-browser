"""Locate the test target in legacy or configuration-based XCTest descriptors."""


def aegis_test_target(descriptor):
    if "AegisTests" in descriptor:
        return descriptor["AegisTests"]
    targets = [target for configuration in descriptor.get("TestConfigurations", [])
               if configuration.get("IsEnabled", True)
               for target in configuration.get("TestTargets", [])
               if target.get("BlueprintName") == "AegisTests"]
    if len(targets) != 1:
        raise ValueError("Expected exactly one enabled AegisTests target in the XCTest descriptor")
    return targets[0]
