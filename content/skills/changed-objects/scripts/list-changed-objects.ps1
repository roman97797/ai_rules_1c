# list-changed-objects.ps1 - numbered list of changed 1C metadata objects from git diff + modification markers
param(
	[string]$Task,
	[string]$Base = "HEAD",
	[switch]$StagedOnly,
	[switch]$IncludeUntracked,
	[switch]$Grouped
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$mapPath = Join-Path $scriptDir "folder-type-map.json"
$folderToType = Get-Content -LiteralPath $mapPath -Raw -Encoding UTF8 | ConvertFrom-Json

function Resolve-GitExe {
	$cmd = Get-Command git -ErrorAction SilentlyContinue
	if ($cmd -and $cmd.Source) { return $cmd.Source }
	$candidates = @(
		(Join-Path $env:ProgramFiles 'Git\bin\git.exe'),
		(Join-Path $env:ProgramFiles 'Git\cmd\git.exe')
	)
	if (${env:ProgramFiles(x86)}) {
		$candidates += (Join-Path ${env:ProgramFiles(x86)} 'Git\bin\git.exe')
	}
	foreach ($path in $candidates) {
		if ($path -and (Test-Path -LiteralPath $path)) { return $path }
	}
	Write-Error "git not found."
	exit 1
}

$gitExe = Resolve-GitExe

function Invoke-Git {
	param([Parameter(ValueFromRemainingArguments = $true)][string[]]$GitArgs)
	& $gitExe -c core.quotePath=false @GitArgs
}

$repoRoot = & $gitExe rev-parse --show-toplevel 2>$null
if (-not $repoRoot) {
	Write-Error "Not a git repository."
	exit 1
}
Set-Location $repoRoot

function Get-ObjectPrefixFromPath {
	param([string]$RelativePath)

	$parts = $RelativePath -replace '\\', '/' -split '/'
	for ($i = 0; $i -lt $parts.Count; $i++) {
		$folder = $parts[$i]
		$typeName = $folderToType.PSObject.Properties[$folder]
		if ($typeName -and ($i + 1) -lt $parts.Count) {
			$objectName = $parts[$i + 1] -replace '\.xml$', ''
			return "$($typeName.Value).$objectName"
		}
	}
	return $null
}

function Get-GroupedModuleName {
	param([string]$RelativePath)

	$norm = $RelativePath -replace '\\', '/'
	$objectPrefix = Get-ObjectPrefixFromPath $norm
	if (-not $objectPrefix) { return $null }

	if ($norm -match '/Forms/([^/]+)/Ext/Form/Module\.bsl$') {
		return "$objectPrefix.$($Matches[1]).МодульФормы"
	}
	if ($norm -match '^CommonForms/[^/]+/Ext/Form/Module\.bsl$') {
		return "$objectPrefix.МодульФормы"
	}
	if ($norm -match '/Commands/([^/]+)/Ext/CommandModule\.bsl$') {
		return "$objectPrefix.$($Matches[1]).МодульКоманды"
	}
	if ($norm -match '/Ext/ObjectModule\.bsl$') { return "$objectPrefix.МодульОбъекта" }
	if ($norm -match '/Ext/ManagerModule\.bsl$') { return "$objectPrefix.МодульМенеджера" }
	if ($norm -match '/Ext/RecordSetModule\.bsl$') { return "$objectPrefix.МодульНабораЗаписей" }
	if ($norm -match '/Ext/Module\.bsl$') { return "$objectPrefix.Модуль" }
	if ($norm -match '/Forms/([^/]+)(?:\.xml|/Ext/Form\.xml)$') {
		return "$objectPrefix.$($Matches[1])"
	}
	if ($norm -match '^CommonForms/[^/]+\.xml$' -or $norm -match '^CommonForms/[^/]+/Ext/Form\.xml$') {
		return $objectPrefix
	}
	if ($norm -match '^[^/]+/[^/]+\.xml$') { return $objectPrefix }
	return $null
}

function Get-QualifiedPrefixFromPath {
	param([string]$RelativePath)

	$parts = $RelativePath -replace '\\', '/' -split '/'

	for ($i = 0; $i -lt $parts.Count; $i++) {
		if ($parts[$i] -ne 'Forms' -or ($i + 1) -ge $parts.Count) { continue }

		$formName = $parts[$i + 1]
		for ($j = $i - 1; $j -ge 1; $j--) {
			$typeName = $folderToType.PSObject.Properties[$parts[$j - 1]]
			if ($typeName) {
				return "$($typeName.Value).$($parts[$j]).$formName"
			}
		}
	}

	if ($parts.Count -ge 2 -and $parts[0] -eq 'CommonForms') {
		return "ОбщаяФорма.$($parts[1])"
	}

	return Get-ObjectPrefixFromPath $RelativePath
}

function Test-IsOpenMarker {
	param([string]$Line)

	if ($Line -notmatch '^\s*//') { return $false }
	if ($Line -match '^\s*//\s*\+\+\s+\S+\s*#(\d+)') { return $true }
	if ($Line -match '^\s*//\s*\{\S+\}\#(\d+)') { return $true }
	if ($Line -match '^\s*//\s*\+\+\+\s*.+;\s*.+;\s*.+;\s*(\d+)') { return $true }
	return $false
}

function Test-IsCloseMarker {
	param([string]$Line)

	if ($Line -notmatch '^\s*//') { return $false }
	if ($Line -match '^\s*//\s*--\s+\S+\s*#(\d+)') { return $true }
	if ($Line -match '^\s*//\s*---\s*.+;\s*.+;\s*.+;\s*(\d+)') { return $true }
	return $false
}

function Get-TaskFromMarkerLine {
	param([string]$Line)

	if ($Line -match '#(\d+)') { return $Matches[1] }
	if ($Line -match ';\s*(\d+)\s*$') { return $Matches[1] }
	return $null
}

function Get-RoutineNamesFromText {
	param([string[]]$Lines)

	$names = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
	$routinePattern = '(\u041F\u0440\u043E\u0446\u0435\u0434\u0443\u0440\u0430|\u0424\u0443\u043D\u043A\u0446\u0438\u044F)\s+(\S+)\s*\('
	foreach ($line in $Lines) {
		if ($line -match $routinePattern) {
			[void]$names.Add($Matches[2])
		}
	}
	return @($names)
}

function Find-EnclosingRoutine {
	param(
		[string[]]$Lines,
		[int]$Index
	)

	$routinePattern = '(\u041F\u0440\u043E\u0446\u0435\u0434\u0443\u0440\u0430|\u0424\u0443\u043D\u043A\u0446\u0438\u044F)\s+(\S+)\s*\('
	for ($i = $Index; $i -ge 0; $i--) {
		if ($Lines[$i] -match $routinePattern) {
			return $Matches[2]
		}
	}
	return $null
}

function Get-RoutinesFromAddedDiffLines {
	param(
		[string]$FilePath,
		[string]$FilterTask
	)

	$gitArgs = @('diff', $Base, '--', $FilePath)
	if ($StagedOnly) {
		$gitArgs = @('diff', '--cached', $Base, '--', $FilePath)
	}

	$diffText = Invoke-Git @gitArgs 2>$null
	if (-not $diffText) { return @() }

	$routinePattern = '^\+(?!\+\+).*?(\u041F\u0440\u043E\u0446\u0435\u0434\u0443\u0440\u0430|\u0424\u0443\u043D\u043A\u0446\u0438\u044F)\s+(\S+)\s*\('
	$names = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)

	foreach ($line in $diffText) {
		if ($line -match $routinePattern) {
			[void]$names.Add($Matches[2])
		}
	}

	if (-not $FilterTask) { return @($names) }

	$fullPath = Join-Path $repoRoot ($FilePath -replace '/', [IO.Path]::DirectorySeparatorChar)
	if (-not (Test-Path -LiteralPath $fullPath)) { return @() }
	$fileLines = Get-Content -LiteralPath $fullPath -Encoding UTF8
	$hasTaskMarker = $false
	foreach ($line in $fileLines) {
		if ((Test-IsOpenMarker $line) -and ((Get-TaskFromMarkerLine $line) -eq $FilterTask)) {
			$hasTaskMarker = $true
			break
		}
	}
	if (-not $hasTaskMarker) { return @() }
	return @($names)
}

function Get-RoutinesFromMarkerBlocks {
	param(
		[string[]]$Lines,
		[string]$FilterTask
	)

	$result = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
	$depth = 0
	$currentTask = $null
	$blockStart = -1

	for ($i = 0; $i -lt $Lines.Count; $i++) {
		$line = $Lines[$i]

		if (Test-IsOpenMarker $line) {
			if ($depth -eq 0) {
				$blockStart = $i
				$currentTask = Get-TaskFromMarkerLine $line
			}
			$depth++
			continue
		}

		if (Test-IsCloseMarker $line) {
			if ($depth -gt 0) {
				$depth--
				if ($depth -eq 0) {
					if (-not $FilterTask -or $currentTask -eq $FilterTask) {
						$blockLines = $Lines[$blockStart..$i]
						foreach ($name in (Get-RoutineNamesFromText $blockLines)) {
							[void]$result.Add($name)
						}
						$outer = Find-EnclosingRoutine $Lines ($blockStart - 1)
						if ($outer) { [void]$result.Add($outer) }
					}
					$blockStart = -1
					$currentTask = $null
				}
			}
			continue
		}
	}

	return @($result)
}

function Get-RoutinesFromDiff {
	param(
		[string]$FilePath,
		[string]$FilterTask
	)

	$gitArgs = @('diff', $Base, '--unified=0', '--', $FilePath)
	if ($StagedOnly) {
		$gitArgs = @('diff', '--cached', $Base, '--unified=0', '--', $FilePath)
	}

	$diffText = Invoke-Git @gitArgs 2>$null
	if (-not $diffText) { return @() }

	$lines = Get-Content -LiteralPath (Join-Path $repoRoot ($FilePath -replace '/', [IO.Path]::DirectorySeparatorChar)) -Encoding UTF8
	$names = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)

	foreach ($diffLine in $diffText) {
		if ($diffLine -match '^@@\s+-\d+(?:,\d+)?\s+\+(\d+)(?:,(\d+))?\s+@@') {
			$start = [int]$Matches[1]
			$count = if ($Matches[2]) { [int]$Matches[2] } else { 1 }
			for ($n = 0; $n -lt $count; $n++) {
				$idx = $start + $n - 1
				if ($idx -ge 0 -and $idx -lt $lines.Count) {
					$routine = Find-EnclosingRoutine $lines $idx
					if ($routine) { [void]$names.Add($routine) }
				}
			}
		}
	}

	if ($FilterTask) {
		$markerNames = Get-RoutinesFromMarkerBlocks $lines $FilterTask
		$filtered = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
		foreach ($name in $names) {
			if ($markerNames -contains $name) { [void]$filtered.Add($name) }
		}
		return @($filtered)
	}

	return @($names)
}

function Get-AttributesFromXmlDiff {
	param(
		[string]$FilePath,
		[string]$ObjectPrefix
	)

	$gitArgs = @('diff', $Base, '--', $FilePath)
	if ($StagedOnly) {
		$gitArgs = @('diff', '--cached', $Base, '--', $FilePath)
	}

	$diffText = Invoke-Git @gitArgs 2>$null
	if (-not $diffText) { return @() }

	$attrs = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)

	foreach ($line in $diffText) {
		if ($line -match '^\+(?!\+)(.*)$') {
			$added = $Matches[1]
			if ($added -match '<Name>([^<]+)</Name>') {
				$name = $Matches[1]
				if ($name -notin @('ru', 'en')) {
					[void]$attrs.Add("$ObjectPrefix.$name")
				}
			}
		}
	}

	return @($attrs)
}

$gitDiffArgs = @('diff', '--name-only', $Base)
if ($StagedOnly) {
	$gitDiffArgs = @('diff', '--cached', '--name-only', $Base)
}

$changedFiles = @(Invoke-Git @gitDiffArgs)
if ($IncludeUntracked) {
	$untracked = @(Invoke-Git ls-files --others --exclude-standard)
	$changedFiles = @($changedFiles + $untracked | Select-Object -Unique)
}

if ($Grouped) {
	$seenObjects = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
	$objects = [System.Collections.Generic.List[string]]::new()
	foreach ($relPath in $changedFiles) {
		$relPath = (($relPath -replace '\\', '/').Trim())
		if (-not $relPath) { continue }
		if ($relPath -like 'openspec/*' -or $relPath -eq 'ConfigDumpInfo.xml' -or $relPath -eq 'Configuration.xml' -or $relPath -eq '.dev.env') { continue }
		$moduleName = Get-GroupedModuleName $relPath
		if (-not $moduleName) { continue }
		if ($seenObjects.Add($moduleName)) { $objects.Add($moduleName) }
	}

	$kept = [System.Collections.Generic.List[string]]::new()
	foreach ($moduleName in $objects) {
		$formModule = "$moduleName.МодульФормы"
		$ownModule = "$moduleName.Модуль"
		if ($seenObjects.Contains($formModule) -or $seenObjects.Contains($ownModule)) { continue }
		$kept.Add($moduleName)
	}
	$objects = $kept

	$groupOrder = @(
		'РегистрСведений', 'РегистрНакопления', 'РегистрБухгалтерии', 'РегистрРасчета',
		'ОбщийМодуль', 'Документ', 'Справочник', 'Перечисление', 'Обработка', 'Отчёт',
		'ОбщаяФорма', 'WebСервис', 'HTTPСервис', 'ПланВидовХарактеристик', 'ПланСчетов',
		'ПланВидовРасчета', 'БизнесПроцесс', 'Задача', 'ПланОбмена', 'Константа',
		'РегламентноеЗадание', 'ПодпискаНаСобытие', 'Роль', 'ОпределяемыйТип'
	)
	$groupTitle = @{
		'РегистрСведений' = 'Регистр сведений'
		'РегистрНакопления' = 'Регистр накопления'
		'РегистрБухгалтерии' = 'Регистр бухгалтерии'
		'РегистрРасчета' = 'Регистр расчета'
		'ОбщийМодуль' = 'Общий модуль'
		'Документ' = 'Документ'
		'Справочник' = 'Справочник'
		'Перечисление' = 'Перечисление'
		'Обработка' = 'Обработка'
		'Отчёт' = 'Отчёт'
		'ОбщаяФорма' = 'Общая форма'
		'WebСервис' = 'Web-сервис'
		'HTTPСервис' = 'HTTP-сервис'
		'ПланВидовХарактеристик' = 'План видов характеристик'
		'ПланСчетов' = 'План счетов'
		'ПланВидовРасчета' = 'План видов расчета'
		'БизнесПроцесс' = 'Бизнес-процесс'
		'Задача' = 'Задача'
		'ПланОбмена' = 'План обмена'
		'Константа' = 'Константа'
		'РегламентноеЗадание' = 'Регламентное задание'
		'ПодпискаНаСобытие' = 'Подписка на событие'
		'Роль' = 'Роль'
		'ОпределяемыйТип' = 'Определяемый тип'
	}

	$byType = @{}
	foreach ($objectName in $objects) {
		$typeName = ($objectName -split '\.', 2)[0]
		if (-not $byType.ContainsKey($typeName)) { $byType[$typeName] = [System.Collections.Generic.List[string]]::new() }
		$byType[$typeName].Add($objectName)
	}

	if ($byType.Count -eq 0) {
		Write-Host "Изменений не найдено."
		exit 0
	}

	Write-Host "## Изменённые объекты"
	Write-Host ""
	$index = 1
	$printed = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
	foreach ($typeName in $groupOrder) {
		if (-not $byType.ContainsKey($typeName)) { continue }
		$title = $groupTitle[$typeName]
		if (-not $title) { $title = $typeName }
		Write-Host "**$title**"
		foreach ($objectName in ($byType[$typeName] | Sort-Object)) {
			Write-Host "$index. $objectName"
			$index++
		}
		Write-Host ""
		[void]$printed.Add($typeName)
	}
	foreach ($typeName in ($byType.Keys | Sort-Object)) {
		if ($printed.Contains($typeName)) { continue }
		Write-Host "**$typeName**"
		foreach ($objectName in ($byType[$typeName] | Sort-Object)) {
			Write-Host "$index. $objectName"
			$index++
		}
		Write-Host ""
	}
	exit 0
}

$entries = [System.Collections.Generic.List[string]]::new()

foreach ($relPath in $changedFiles) {
	$relPath = $relPath -replace '\\', '/'
	$prefix = Get-QualifiedPrefixFromPath $relPath
	if (-not $prefix) { continue }

	$fullPath = Join-Path $repoRoot ($relPath -replace '/', [IO.Path]::DirectorySeparatorChar)
	if (-not (Test-Path -LiteralPath $fullPath)) { continue }

	if ($relPath -match '\.bsl$') {
		$lines = Get-Content -LiteralPath $fullPath -Encoding UTF8
		$markerRoutines = Get-RoutinesFromMarkerBlocks $lines $Task
		$allRoutines = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
		foreach ($routine in $markerRoutines) { [void]$allRoutines.Add($routine) }
		foreach ($routine in (Get-RoutinesFromAddedDiffLines $relPath $Task)) { [void]$allRoutines.Add($routine) }
		if ($allRoutines.Count -eq 0) {
			foreach ($routine in (Get-RoutinesFromDiff $relPath $Task)) { [void]$allRoutines.Add($routine) }
		}
		foreach ($routine in $allRoutines) {
			$entries.Add("$prefix.$routine()")
		}
	}
	elseif ($relPath -match '\.xml$') {
		$attrs = Get-AttributesFromXmlDiff $relPath $prefix
		foreach ($attr in $attrs) {
			$entries.Add($attr)
		}
		if (-not $attrs) {
			$entries.Add($prefix)
		}
	}
}

$unique = [System.Collections.Generic.List[string]]::new()
$seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($item in ($entries | Sort-Object)) {
	if ($seen.Add($item)) { [void]$unique.Add($item) }
}

if ($unique.Count -eq 0) {
	if ($Task) {
		Write-Host "No changed objects found (task #$Task, base=$Base)."
	}
	else {
		Write-Host "No changed objects found (base=$Base)."
	}
	exit 0
}

$index = 1
foreach ($item in $unique) {
	Write-Host "$index. $item"
	$index++
}
