Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/method-signature.ps1')
. (Join-Path $PSScriptRoot 'lib/candidate-class-provenance.ps1')
foreach ($case in @(
    @{ line = 'public void f() {'; count = 0 },
    @{ line = 'public void f(int value) {'; count = 1 },
    @{ line = 'public void f(int left, int right) {'; count = 2 },
    @{ line = 'public void f(Map<String, Integer> value) {'; count = 1 },
    @{ line = 'public void f(Map<String, List<Integer>> value, int right) {'; count = 2 },
    @{ line = 'public void f(@Named("a,b") String value, int right) {'; count = 0 },
    @{ line = 'public void f(Map<String, Integer value, int right) {'; count = 0 }
)) {
    if (@(Get-WrappableMethodSignatureParameters -Line $case.line).Count -ne $case.count) {
        throw "Wrong signature parameter count: $($case.line)"
    }
}
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'run-next-slice.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw 'Runner parse failed' }
foreach ($name in @('ConvertTo-RepoPath', 'Test-AstLiteCandidate', 'Get-NextCandidate')) {
    $function = $ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name}, $true)
    if ($null -eq $function) { throw "Missing runner function: $name" }
    . ([scriptblock]::Create($function.Extent.Text))
}
# Isolate selection from the independent class-admission gate. This fixture
# does not change that gate in the production runner or admit the class.
function Test-ThresholdCandidateClassHasIndependentDiffClassifier {
    param([string] $CandidateClass)
    return $CandidateClass -eq 'method_signature_wrap_cleanup'
}
$root = Join-Path ([IO.Path]::GetTempPath()) ('threshold-signature-filter-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
try {
    $stale = Join-Path $root 'stale.java'
    $valid = Join-Path $root 'valid.java'
    [IO.File]::WriteAllText($stale, 'public void f(int value) {')
    [IO.File]::WriteAllText($valid, 'public void f(int left, int right) {')
    $pocket = Join-Path $root 'pocket.json'
    @{ candidates = @(
        @{ candidateId = 'stale'; candidateClass = 'method_signature_wrap_cleanup'; file = $stale; member = 'line-1'; score = 100; autoPatchable = $true; reviewOnly = $false },
        @{ candidateId = 'valid'; candidateClass = 'method_signature_wrap_cleanup'; file = $valid; member = 'line-1'; score = 100; autoPatchable = $true; reviewOnly = $false }
    ) } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $pocket
    $selected = @(Get-NextCandidate -PocketPath $pocket -MinScore 70 | Where-Object { $null -ne $_ })
    if ($selected.Count -ne 1 -or $selected[0].candidateId -ne 'valid') { throw 'Stale signature was not filtered before selection' }
    [IO.File]::WriteAllText($valid, 'public void f(Map<String, Integer> value) {')
    if ($null -ne (Get-NextCandidate -PocketPath $pocket -MinScore 70)) { throw 'Single generic parameter was incorrectly selected as multiple parameters' }
    Write-Host 'methodSignatureCandidateFilter=passed'
} finally {
    if ([IO.Path]::GetFullPath($root).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}
