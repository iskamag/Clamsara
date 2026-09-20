# Reporting-only array stress

`500k.log` is the unchanged output of the native 500,000-element test on the
`6e268e4` production implementation plus the reporting-only model-resource test
changes committed with this evidence. Source/test hashes are in
`source-hashes.json`; every listed file matched after the component, stress and
full ASDF gates. The stress SBCL process exited 0 in 5.980 seconds including
startup and reporting. This is not isolated performance or benchmark acceptance.
The normal `run-model-resource-array-stress :element-count 500000` entry was used.
All 20 benchmark fixtures and the normative paper remained unchanged.
