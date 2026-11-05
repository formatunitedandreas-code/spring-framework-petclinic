# Finite current source candidate rule

This normal policy PR proposes one finite, user-directed current-source route for
original PR 184. It does not use its own route and changes no active lease or
autonomous candidate class. The registration must already be present in the actual
target base before source PR 184 can use it. Every other PR continues through the
ordinary governance checks.

The fixed registration references the root-reviewed, normally merged PR 202
proposal at `753d4946eb128e43babda4a1346e295960788b40`. Its Git blob hash binds
the full two-file patch, before/after identities, complete Maven test-input trees,
published tested witness `45128d9e3877f8254bc68cb99d212b3eed8d4d8c`, and actual
126/126 local log. The verifier reads those bytes from immutable target-base Git
objects. Mutable checkout copies cannot supply the registration or its evidence.

The verifier binds the observed event's own repository, source repository, main
base repository/ref/SHA, PR number 184, and actual source head. The actual base and
published witness must both be ancestors of that source head. The checkout must
be the source head or the genuine two-parent base/source merge with the exact same
root tree, with a clean tracked worktree and index. Synthetic checkout commits are
reported separately and never called the source witness.
Untracked and ignored files under the complete registered Maven inputs also reject
the candidate, including a locally downloaded untracked wrapper jar or extra Java,
resource, or `.mvn` configuration. Use a fresh checkout for qualification; unrelated
local artifacts must not be removed to force a pass. This is a source-input check,
not a qualification of the external JDK, Maven cache, or runtime environment.

The final delta must contain exactly the registered extractor and test file,
including modes and complete canonical diff. Before test inputs must still equal
the registered baseline; after inputs must exactly equal the tested witness,
including Git object types and modes. Changed policy, registration, lease,
receipts, KG, trainer, or any extra file rejects the finite route. Missing or
changed witness, evidence, base, source, or event bindings fail closed.

Success means **verified_current_source_candidate** only. Fresh current CI and an
actual independent exact-head review remain explicitly required. The verifier does
not claim either passed and cannot make the final merge decision. Root must
observe all current required checks green, no findings, and the actual source
review before any merge. The old `a867b493...` historical admission remains HOLD;
no old receipt or historical execution is qualified retroactively.

`learningEligible=false`, `RuntimeAuthority=NONE`, `ExecutionAuthorized=false`.
This rule creates no runtime, provider, installation, activation, KG, trainer,
learning, or general autonomous permission.
