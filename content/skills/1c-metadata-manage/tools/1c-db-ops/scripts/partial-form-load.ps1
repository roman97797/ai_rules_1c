# Shared by db-load-xml and db-load-git.
# On platform 8.3.13, /LoadConfigFromFiles -partial treats Forms/<Form>/Ext
# as a child metadata object and rejects it:
# "Неизвестный объект метаданных …Form.<Имя>.Ext".
# The same Ext folder of the object itself (ObjectModule.bsl and the like) loads.
# A form is therefore loaded as a whole object by its root XML, without -partial.

function Get-ManagedFormRootRelativePath {
    param([string]$RelativePath)

    $norm = ($RelativePath.Trim() -replace '\\', '/')
    if (-not $norm) { return $null }
    $parts = $norm -split '/'
    for ($i = 0; $i -lt $parts.Count; $i++) {
        $segment = $parts[$i]
        if ($segment -ne 'Forms' -and $segment -ne 'CommonForms') { continue }
        if (($i + 1) -ge $parts.Count) { return $null }
        $name = $parts[$i + 1]
        if ($name -match '(?i)\.xml$') { $name = $name.Substring(0, $name.Length - 4) }
        if (-not $name) { return $null }
        $head = @()
        if ($i -gt 0) { $head = $parts[0..($i - 1)] }
        return ((@($head) + @($segment, "$name.xml")) -join '/')
    }
    return $null
}

function Split-PartialFormFiles {
    param(
        [string[]]$RelativePaths,
        [string]$ConfigDir
    )

    $partial = New-Object System.Collections.Generic.List[string]
    $forms = New-Object System.Collections.Generic.List[string]
    $missing = New-Object System.Collections.Generic.List[string]
    $seenForms = @{}
    foreach ($raw in $RelativePaths) {
        if (-not $raw) { continue }
        $root = Get-ManagedFormRootRelativePath $raw
        if (-not $root) {
            $partial.Add($raw)
            continue
        }
        if ($seenForms.ContainsKey($root)) { continue }
        $seenForms[$root] = $true
        $full = Join-Path $ConfigDir ($root -replace '/', '\')
        if (-not (Test-Path -LiteralPath $full)) {
            $missing.Add($root)
        } else {
            $forms.Add($root)
        }
    }
    return [pscustomobject]@{
        PartialFiles     = [string[]]@($partial)
        FormRoots        = [string[]]@($forms)
        MissingFormRoots = [string[]]@($missing)
    }
}

function Resolve-DesignerBatchExitCode {
    param(
        [int]$ProcessExitCode,
        [string]$ResultFile
    )

    $exitCode = $ProcessExitCode
    if ($exitCode -ne 0) { return $exitCode }
    $dumpCode = ''
    if (Test-Path -LiteralPath $ResultFile) {
        $dumpText = Get-Content -LiteralPath $ResultFile -Raw -ErrorAction SilentlyContinue
        if ($dumpText) { $dumpCode = ($dumpText -replace '[^\d\-]', '') }
    }
    if ($dumpCode -eq '0') { return 0 }
    if ($dumpCode) {
        Write-Host "[error] batch result $dumpCode reported by /DumpResult (0 = success)" -ForegroundColor Red
    } else {
        Write-Host "[error] /DumpResult wrote no result - the batch command did not complete" -ForegroundColor Red
    }
    return 1
}

function Get-LoadLogRejections {
    param([string]$LogContent)

    $fatalLogPatterns = @(
        'Неверное свойство объекта метаданных',
        'не входит в состав объекта метаданных',
        'Неизвестное имя типа',
        'Неизвестный объект метаданных',
        'Ни один из документов не является регистратором для регистра',
        'Неверное значение перечисления',
        'не может быть приведен к типу'
    )
    $silentFailures = New-Object System.Collections.Generic.List[string]
    if ($LogContent) {
        foreach ($line in ($LogContent -split "`r?`n")) {
            foreach ($pat in $fatalLogPatterns) {
                if ($line -match [regex]::Escape($pat)) {
                    $silentFailures.Add($line.Trim())
                    break
                }
            }
        }
    }
    return ,[string[]]@($silentFailures)
}
