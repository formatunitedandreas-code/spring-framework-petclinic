Set-StrictMode -Version Latest

function Get-WrappableMethodSignatureParameters {
    param([string] $Line)
    $match = [regex]::Match($Line, '^\s*(?:public|private|protected)\s+.+?\(\s*(?<params>.*)\)\s*\{\s*$')
    if (-not $match.Success) { return @() }
    $text = $match.Groups['params'].Value.Trim()
    # Complex annotation expressions require a Java parser; keep them review-only.
    if ([string]::IsNullOrWhiteSpace($text) -or $text -match '[()"''{}]') { return @() }
    $parts = [Collections.Generic.List[string]]::new()
    $depth = 0
    $start = 0
    for ($i = 0; $i -lt $text.Length; $i++) {
        if ($text[$i] -eq '<') { $depth++ }
        elseif ($text[$i] -eq '>') {
            $depth--
            if ($depth -lt 0) { return @() }
        }
        elseif ($text[$i] -eq ',' -and $depth -eq 0) {
            $part = $text.Substring($start, $i - $start).Trim()
            if ([string]::IsNullOrWhiteSpace($part)) { return @() }
            $parts.Add($part)
            $start = $i + 1
        }
    }
    $last = $text.Substring($start).Trim()
    if ($depth -ne 0 -or [string]::IsNullOrWhiteSpace($last)) { return @() }
    $parts.Add($last)
    return $parts.ToArray()
}
