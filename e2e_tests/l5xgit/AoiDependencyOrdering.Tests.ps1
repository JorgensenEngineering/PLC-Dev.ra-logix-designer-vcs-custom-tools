#Requires -Modules Pester
param(
    [switch]$Debug
)

$env:E2E_DEBUG = if ($Debug) { '1' } else { '0' }

BeforeAll {
    . "$PSScriptRoot/../Helpers.ps1"

    if (-not (Test-Path $l5xplode)) {
        throw "l5xplode.exe not found at '$l5xplode'. Run 'dotnet build -c Release' first."
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# AOI dependency ordering — explicit <Dependencies> elements
# ─────────────────────────────────────────────────────────────────────────────
Describe 'AOI dependency ordering with explicit Dependencies' {

    Context 'round-trip sorts AOIs by dependency order' {
        BeforeAll {
            $script:tempDir = New-TestTempDir -Prefix 'aoi_explicit'
            $l5xFile = Join-Path $fixturesDir 'sample_with_aoi_dependencies.L5X'

            # Explode (AOIs are in reverse order in the source file: TopAOI, IndependentAOI, MiddleAOI, ZBaseAOI)
            $explodeResult = Invoke-L5xplode @('explode', '--l5x', $l5xFile, '--dir', $script:tempDir, '--force')
            if ($explodeResult.ExitCode -ne 0) {
                throw "Explode failed: $($explodeResult.StdErr)"
            }

            # Implode back
            $script:outputL5x = Join-Path $script:tempDir 'sorted_output.L5X'
            $implodeResult = Invoke-L5xplode @('implode', '--dir', $script:tempDir, '--l5x', $script:outputL5x, '--force')
            if ($implodeResult.ExitCode -ne 0) {
                throw "Implode failed: $($implodeResult.StdErr)"
            }

            [xml]$script:xml = Get-Content $script:outputL5x
            $script:aoiNames = @($script:xml.RSLogix5000Content.Controller.AddOnInstructionDefinitions.AddOnInstruction | ForEach-Object { $_.Name })
        }

        AfterAll {
            $ProgressPreference = 'SilentlyContinue'
            if (Test-Path $script:tempDir) { Remove-Item $script:tempDir -Recurse -Force }
        }

        It 'produces all four AOIs' {
            $script:aoiNames.Count | Should -Be 4
        }

        It 'places ZBaseAOI before MiddleAOI' {
            $baseIdx   = [array]::IndexOf($script:aoiNames, 'ZBaseAOI')
            $middleIdx = [array]::IndexOf($script:aoiNames, 'MiddleAOI')
            $baseIdx | Should -BeLessThan $middleIdx
        }

        It 'places MiddleAOI before TopAOI' {
            $middleIdx = [array]::IndexOf($script:aoiNames, 'MiddleAOI')
            $topIdx    = [array]::IndexOf($script:aoiNames, 'TopAOI')
            $middleIdx | Should -BeLessThan $topIdx
        }

        It 'does not include any L5XGitPrevAOI elements (Dependencies mode does not inject hints)' {
            $content = Get-Content $script:outputL5x -Raw
            $content | Should -Not -Match 'L5XGitPrevAOI'
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# AOI ordering with --unsafe-skip-dependency-check (implicit deps, no <Dependencies>)
# ─────────────────────────────────────────────────────────────────────────────
Describe 'AOI ordering with --unsafe-skip-dependency-check' {

    Context 'no-deps fixture without encoded AOIs succeeds without --unsafe flag' {
        It 'succeeds because there are no encrypted/encoded AOIs' {
            $tempDir = New-TestTempDir -Prefix 'aoi_noexport'
            try {
                $l5xFile = Join-Path $fixturesDir 'sample_implicit_deps_no_export_option.L5X'
                $result = Invoke-L5xplode @('explode', '--l5x', $l5xFile, '--dir', $tempDir, '--force')

                $result.ExitCode | Should -Be 0
            }
            finally {
                $ProgressPreference = 'SilentlyContinue'
                if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }
            }
        }
    }

    Context 'explode with --unsafe-skip-dependency-check adds ordering hints' {
        BeforeAll {
            $script:tempDir = New-TestTempDir -Prefix 'aoi_unsafe'
            $l5xFile = Join-Path $fixturesDir 'sample_implicit_deps_no_export_option.L5X'

            $script:result = Invoke-L5xplode @(
                'explode', '--l5x', $l5xFile, '--dir', $script:tempDir,
                '--force', '--unsafe-skip-dependency-check'
            )
        }

        AfterAll {
            $ProgressPreference = 'SilentlyContinue'
            if (Test-Path $script:tempDir) { Remove-Item $script:tempDir -Recurse -Force }
        }

        It 'succeeds' {
            $script:result.ExitCode | Should -Be 0
        }

        It 'persists unsafe_skip_dependency_check as true' {
            $optionsFile = Join-Path $script:tempDir 'RSLogix5000Content/export-options.yaml'
            $content = Get-Content $optionsFile -Raw
            $content | Should -Match 'unsafe_skip_dependency_check:\s*true'
        }

        It 'adds L5XGitPrevAOI hints to AOI files' {
            # The fixture has 3 AOIs: TopAOI, MiddleAOI, ZBaseAOI (in that order).
            # After explode, the 2nd and 3rd AOIs should have L5XGitPrevAOI hints.
            $aoiDir = Join-Path $script:tempDir 'RSLogix5000Content/AddOnInstructionDefinitions'

            # MiddleAOI should have a hint pointing to TopAOI (the AOI before it in the source)
            $middleFile = Join-Path $aoiDir 'MiddleAOI/MiddleAOI.xml'
            $middleFile | Should -Exist
            $middleContent = Get-Content $middleFile -Raw
            $middleContent | Should -Match 'L5XGitPrevAOI'

            # ZBaseAOI should have a hint pointing to MiddleAOI
            $baseFile = Join-Path $aoiDir 'ZBaseAOI/ZBaseAOI.xml'
            $baseFile | Should -Exist
            $baseContent = Get-Content $baseFile -Raw
            $baseContent | Should -Match 'L5XGitPrevAOI'
        }

        It 'does NOT add L5XGitPrevAOI to the first AOI' {
            $aoiDir = Join-Path $script:tempDir 'RSLogix5000Content/AddOnInstructionDefinitions'
            $topFile = Join-Path $aoiDir 'TopAOI/TopAOI.xml'
            $topFile | Should -Exist
            $topContent = Get-Content $topFile -Raw
            $topContent | Should -Not -Match 'L5XGitPrevAOI'
        }
    }

    Context 'round-trip with implicit deps sorts AOIs and strips hints' {
        BeforeAll {
            $script:tempDir = New-TestTempDir -Prefix 'aoi_roundtrip'
            $l5xFile = Join-Path $fixturesDir 'sample_implicit_deps_no_export_option.L5X'

            # Explode with unsafe flag
            $explodeResult = Invoke-L5xplode @(
                'explode', '--l5x', $l5xFile, '--dir', $script:tempDir,
                '--force', '--unsafe-skip-dependency-check'
            )
            if ($explodeResult.ExitCode -ne 0) {
                throw "Explode failed: $($explodeResult.StdErr)"
            }

            # Implode back
            $script:outputL5x = Join-Path $script:tempDir 'implicit_sorted.L5X'
            $implodeResult = Invoke-L5xplode @('implode', '--dir', $script:tempDir, '--l5x', $script:outputL5x, '--force')
            if ($implodeResult.ExitCode -ne 0) {
                throw "Implode failed: $($implodeResult.StdErr)"
            }

            [xml]$script:xml = Get-Content $script:outputL5x
            $script:aoiNames = @($script:xml.RSLogix5000Content.Controller.AddOnInstructionDefinitions.AddOnInstruction | ForEach-Object { $_.Name })
        }

        AfterAll {
            $ProgressPreference = 'SilentlyContinue'
            if (Test-Path $script:tempDir) { Remove-Item $script:tempDir -Recurse -Force }
        }

        It 'produces all three AOIs' {
            $script:aoiNames.Count | Should -Be 3
        }

        It 'places ZBaseAOI before MiddleAOI (implicit dep via Parameter DataType)' {
            $baseIdx   = [array]::IndexOf($script:aoiNames, 'ZBaseAOI')
            $middleIdx = [array]::IndexOf($script:aoiNames, 'MiddleAOI')
            $baseIdx | Should -BeLessThan $middleIdx
        }

        It 'places MiddleAOI before TopAOI (implicit dep via Parameter DataType)' {
            $middleIdx = [array]::IndexOf($script:aoiNames, 'MiddleAOI')
            $topIdx    = [array]::IndexOf($script:aoiNames, 'TopAOI')
            $middleIdx | Should -BeLessThan $topIdx
        }

        It 'strips L5XGitPrevAOI ordering hints from the imploded output' {
            $content = Get-Content $script:outputL5x -Raw
            $content | Should -Not -Match 'L5XGitPrevAOI'
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Indirect AOI dependencies — ConsumerAOI -> DataType -> NestedAOI
#
# The fixture's original AOI order deliberately contradicts that dependency:
#   ConsumerAOI, FirstIndependentAOI, NestedAOI, LastIndependentAOI
# ─────────────────────────────────────────────────────────────────────────────
Describe 'AOI ordering with an indirect dependency through a DataType' {

    Context 'original order recorded in ordering hints contradicts the dependency graph' {
        BeforeAll {
            $script:tempDir = New-TestTempDir -Prefix 'aoi_indirect_hints'
            $l5xFile = Join-Path $fixturesDir 'sample_indirect_aoi_dependency.L5X'

            # --unsafe-skip-dependency-check makes explode record the original order as
            # L5XGitPrevAOI hints, which is what gives the sort an order to contradict.
            $explodeResult = Invoke-L5xplode @(
                'explode', '--l5x', $l5xFile, '--dir', $script:tempDir,
                '--force', '--unsafe-skip-dependency-check'
            )
            if ($explodeResult.ExitCode -ne 0) {
                throw "Explode failed: $($explodeResult.StdErr)"
            }

            $script:outputL5x = Join-Path $script:tempDir 'indirect_hints.L5X'
            $implodeResult = Invoke-L5xplode @('implode', '--dir', $script:tempDir, '--l5x', $script:outputL5x, '--force')
            if ($implodeResult.ExitCode -ne 0) {
                throw "Implode failed: $($implodeResult.StdErr)"
            }

            [xml]$script:xml = Get-Content $script:outputL5x
            $script:aoiNames = @($script:xml.RSLogix5000Content.Controller.AddOnInstructionDefinitions.AddOnInstruction | ForEach-Object { $_.Name })
        }

        AfterAll {
            $ProgressPreference = 'SilentlyContinue'
            if (Test-Path $script:tempDir) { Remove-Item $script:tempDir -Recurse -Force }
        }

        It 'produces all four AOIs' {
            $script:aoiNames.Count | Should -Be 4
        }

        It 'places NestedAOI before ConsumerAOI even though the original order had it after' {
            $nestedIdx   = [array]::IndexOf($script:aoiNames, 'NestedAOI')
            $consumerIdx = [array]::IndexOf($script:aoiNames, 'ConsumerAOI')
            $nestedIdx | Should -BeLessThan $consumerIdx
        }

        It 'keeps the original relative order of the AOIs the dependency does not constrain' {
            $firstIdx  = [array]::IndexOf($script:aoiNames, 'FirstIndependentAOI')
            $nestedIdx = [array]::IndexOf($script:aoiNames, 'NestedAOI')
            $lastIdx   = [array]::IndexOf($script:aoiNames, 'LastIndependentAOI')
            $firstIdx | Should -BeLessThan $nestedIdx
            $nestedIdx | Should -BeLessThan $lastIdx
        }

        It 'moves ConsumerAOI the minimum distance needed to satisfy the dependency' {
            # Original order was Consumer, First, Nested, Last. Only ConsumerAOI moves, and only
            # far enough to land after NestedAOI.
            $script:aoiNames | Should -Be @('FirstIndependentAOI', 'NestedAOI', 'ConsumerAOI', 'LastIndependentAOI')
        }

        It 'strips L5XGitPrevAOI ordering hints from the imploded output' {
            $content = Get-Content $script:outputL5x -Raw
            $content | Should -Not -Match 'L5XGitPrevAOI'
        }
    }

    Context 'without ordering hints the dependency is still honoured' {
        BeforeAll {
            $script:tempDir = New-TestTempDir -Prefix 'aoi_indirect_plain'
            $l5xFile = Join-Path $fixturesDir 'sample_indirect_aoi_dependency.L5X'

            $explodeResult = Invoke-L5xplode @('explode', '--l5x', $l5xFile, '--dir', $script:tempDir, '--force')
            if ($explodeResult.ExitCode -ne 0) {
                throw "Explode failed: $($explodeResult.StdErr)"
            }

            $script:outputL5x = Join-Path $script:tempDir 'indirect_plain.L5X'
            $implodeResult = Invoke-L5xplode @('implode', '--dir', $script:tempDir, '--l5x', $script:outputL5x, '--force')
            if ($implodeResult.ExitCode -ne 0) {
                throw "Implode failed: $($implodeResult.StdErr)"
            }

            [xml]$script:xml = Get-Content $script:outputL5x
            $script:aoiNames = @($script:xml.RSLogix5000Content.Controller.AddOnInstructionDefinitions.AddOnInstruction | ForEach-Object { $_.Name })
        }

        AfterAll {
            $ProgressPreference = 'SilentlyContinue'
            if (Test-Path $script:tempDir) { Remove-Item $script:tempDir -Recurse -Force }
        }

        It 'places NestedAOI before ConsumerAOI' {
            $nestedIdx   = [array]::IndexOf($script:aoiNames, 'NestedAOI')
            $consumerIdx = [array]::IndexOf($script:aoiNames, 'ConsumerAOI')
            $nestedIdx | Should -BeLessThan $consumerIdx
        }
    }

    Context 'the dependencies command reports the indirect requirement' {
        BeforeAll {
            $l5xFile = Join-Path $fixturesDir 'sample_indirect_aoi_dependency.L5X'
            $script:result = Invoke-L5xplode @('dependencies', '--l5x', $l5xFile)
        }

        It 'succeeds' {
            $script:result.ExitCode | Should -Be 0
        }

        It 'names NestedAOI as an indirect prerequisite of ConsumerAOI' {
            $script:result.StdOut | Should -Match 'must be preceded by: NestedAOI \(indirect\)'
        }

        It 'shows NestedAOI nested under BridgeUDT in the tree' {
            $script:result.StdOut | Should -Match '- BridgeUDT \[DataType\]'
            $script:result.StdOut | Should -Match '- NestedAOI \[AOI\]'
        }

        It 'marks nothing as inferred, because every edge was declared' {
            $script:result.StdOut | Should -Not -Match 'inferred'
        }

        It 'reports only the one AOI that has dependencies' {
            $script:result.StdOut | Should -Match '1 of 4 add-on instruction\(s\) have dependencies\.'
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# The same ConsumerAOI -> BridgeUDT -> NestedAOI chain, but with nothing declaring it.
# The link must be inferred from the Parameter and Member DataType attributes alone.
# ─────────────────────────────────────────────────────────────────────────────
Describe 'AOI ordering with an indirect dependency inferred from type references' {

    Context 'original order recorded in ordering hints contradicts the inferred dependency' {
        BeforeAll {
            $script:tempDir = New-TestTempDir -Prefix 'aoi_implicit_hints'
            $l5xFile = Join-Path $fixturesDir 'sample_indirect_aoi_dependency_implicit.L5X'

            $explodeResult = Invoke-L5xplode @(
                'explode', '--l5x', $l5xFile, '--dir', $script:tempDir,
                '--force', '--unsafe-skip-dependency-check'
            )
            if ($explodeResult.ExitCode -ne 0) {
                throw "Explode failed: $($explodeResult.StdErr)"
            }

            $script:outputL5x = Join-Path $script:tempDir 'implicit_indirect.L5X'
            $implodeResult = Invoke-L5xplode @('implode', '--dir', $script:tempDir, '--l5x', $script:outputL5x, '--force')
            if ($implodeResult.ExitCode -ne 0) {
                throw "Implode failed: $($implodeResult.StdErr)"
            }

            [xml]$script:xml = Get-Content $script:outputL5x
            $script:aoiNames = @($script:xml.RSLogix5000Content.Controller.AddOnInstructionDefinitions.AddOnInstruction | ForEach-Object { $_.Name })
        }

        AfterAll {
            $ProgressPreference = 'SilentlyContinue'
            if (Test-Path $script:tempDir) { Remove-Item $script:tempDir -Recurse -Force }
        }

        It 'connects ConsumerAOI to NestedAOI through the UDT and reorders accordingly' {
            $nestedIdx   = [array]::IndexOf($script:aoiNames, 'NestedAOI')
            $consumerIdx = [array]::IndexOf($script:aoiNames, 'ConsumerAOI')
            $nestedIdx | Should -BeLessThan $consumerIdx
        }

        It 'moves ConsumerAOI the minimum distance needed to satisfy the dependency' {
            $script:aoiNames | Should -Be @('FirstIndependentAOI', 'NestedAOI', 'ConsumerAOI', 'LastIndependentAOI')
        }

        It 'strips L5XGitPrevAOI ordering hints from the imploded output' {
            $content = Get-Content $script:outputL5x -Raw
            $content | Should -Not -Match 'L5XGitPrevAOI'
        }
    }

    Context 'without ordering hints the inferred dependency is still honoured' {
        BeforeAll {
            $script:tempDir = New-TestTempDir -Prefix 'aoi_implicit_plain'
            $l5xFile = Join-Path $fixturesDir 'sample_indirect_aoi_dependency_implicit.L5X'

            # No --unsafe flag: the fixture has no encoded AOIs, so the missing Dependencies
            # export option is not fatal.
            $script:explodeResult = Invoke-L5xplode @('explode', '--l5x', $l5xFile, '--dir', $script:tempDir, '--force')
            if ($script:explodeResult.ExitCode -ne 0) {
                throw "Explode failed: $($script:explodeResult.StdErr)"
            }

            $script:outputL5x = Join-Path $script:tempDir 'implicit_plain.L5X'
            $implodeResult = Invoke-L5xplode @('implode', '--dir', $script:tempDir, '--l5x', $script:outputL5x, '--force')
            if ($implodeResult.ExitCode -ne 0) {
                throw "Implode failed: $($implodeResult.StdErr)"
            }

            [xml]$script:xml = Get-Content $script:outputL5x
            $script:aoiNames = @($script:xml.RSLogix5000Content.Controller.AddOnInstructionDefinitions.AddOnInstruction | ForEach-Object { $_.Name })
        }

        AfterAll {
            $ProgressPreference = 'SilentlyContinue'
            if (Test-Path $script:tempDir) { Remove-Item $script:tempDir -Recurse -Force }
        }

        It 'explodes without --unsafe-skip-dependency-check' {
            $script:explodeResult.ExitCode | Should -Be 0
        }

        It 'places NestedAOI before ConsumerAOI' {
            $nestedIdx   = [array]::IndexOf($script:aoiNames, 'NestedAOI')
            $consumerIdx = [array]::IndexOf($script:aoiNames, 'ConsumerAOI')
            $nestedIdx | Should -BeLessThan $consumerIdx
        }
    }

    Context 'the dependencies command reports the inferred indirect requirement' {
        BeforeAll {
            $l5xFile = Join-Path $fixturesDir 'sample_indirect_aoi_dependency_implicit.L5X'
            $script:result = Invoke-L5xplode @('dependencies', '--l5x', $l5xFile)
        }

        It 'succeeds' {
            $script:result.ExitCode | Should -Be 0
        }

        It 'warns that dependencies are inferred' {
            $script:result.StdOut | Should -Match "exported without the 'Dependencies' option"
        }

        It 'names NestedAOI as an indirect prerequisite of ConsumerAOI' {
            $script:result.StdOut | Should -Match 'must be preceded by: NestedAOI \(indirect\)'
        }

        It 'marks both edges of the chain as inferred' {
            $script:result.StdOut | Should -Match '- BridgeUDT \[DataType\] \(inferred\)'
            $script:result.StdOut | Should -Match '- NestedAOI \[AOI\] \(inferred\)'
        }

        It 'explains the inferred marker' {
            $script:result.StdOut | Should -Match 'Entries marked \(inferred\)'
        }
    }
}
