import file
import json
import models.io.upbound.dev.meta.v1alpha1 as meta

# Shared with the native render runner, allowing the same contracts to run
# when a remote Docker proxy cannot execute up's internal render container.
_cases = json.decode(file.read("cases.json"))
items = [meta.CompositionTest {metadata = case.metadata, spec = case.spec} for case in _cases]
