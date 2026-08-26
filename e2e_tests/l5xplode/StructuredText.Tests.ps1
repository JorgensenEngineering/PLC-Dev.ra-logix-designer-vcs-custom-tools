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
# Structured text routines are stored as .st files. Everything else about the routine
# lives in a sibling element file so it survives the round trip.
# ─────────────────────────────────────────────────────────────────────────────
Describe 'Structured text routine round trip' {

    Context 'exploded layout' {
        BeforeAll {
            $script:tempDir = New-TestTempDir -Prefix 'st_layout'
            $l5xFile = Join-Path $fixturesDir 'sample_structured_text.L5X'

            $script:explodeResult = Invoke-L5xplode @('explode', '--l5x', $l5xFile, '--dir', $script:tempDir, '--force')
            if ($script:explodeResult.ExitCode -ne 0) {
                throw "Explode failed: $($script:explodeResult.StdErr)"
            }

            $script:aoiRoutines     = Join-Path $script:tempDir 'RSLogix5000Content/AddOnInstructionDefinitions/StAoi/Routines'
            $script:programRoutines = Join-Path $script:tempDir 'RSLogix5000Content/Programs/MainProgram/Routines'
        }

        AfterAll {
            $ProgressPreference = 'SilentlyContinue'
            if (Test-Path $script:tempDir) { Remove-Item $script:tempDir -Recurse -Force }
        }

        It 'writes the structured text to a .st file' {
            Join-Path $script:aoiRoutines 'AoiStLogic.st' | Should -Exist
            Join-Path $script:aoiRoutines 'AoiStEdgeCases.st' | Should -Exist
            Join-Path $script:programRoutines 'ProgramStLogic.st' | Should -Exist
        }

        It 'writes the routine element alongside it' {
            Join-Path $script:aoiRoutines 'AoiStLogic.xml' | Should -Exist
            Join-Path $script:aoiRoutines 'AoiStEdgeCases.xml' | Should -Exist
            Join-Path $script:programRoutines 'ProgramStLogic.xml' | Should -Exist
        }

        It 'keeps the description in the routine element, not the .st file' {
            $xml = Get-Content (Join-Path $script:aoiRoutines 'AoiStLogic.xml') -Raw
            $xml | Should -Match 'AOI structured text routine description'

            $st = Get-Content (Join-Path $script:aoiRoutines 'AoiStLogic.st') -Raw
            $st | Should -Not -Match 'description'
        }

        It 'moves the Line elements out of the routine element' {
            $xml = Get-Content (Join-Path $script:aoiRoutines 'AoiStLogic.xml') -Raw
            $xml | Should -Not -Match '<Line'
        }

        It 'writes the structured text verbatim' {
            $st = Get-Content (Join-Path $script:aoiRoutines 'AoiStLogic.st') -Raw
            $st | Should -Match ([regex]::Escape('Counter := Counter + 1;'))
            $st | Should -Match ([regex]::Escape('END_IF;'))
        }

        It 'writes XML-hostile characters to the .st file as plain text' {
            $lines = Get-Content (Join-Path $script:aoiRoutines 'AoiStEdgeCases.st')
            $lines[0] | Should -BeExactly 'IF x < 5 AND y > 3 THEN'
            $lines[1] | Should -BeExactly "s := 'A & B';"
            $lines[2] | Should -BeExactly 'IF a[b[i]]> 0 THEN'
            $lines[3] | Should -BeExactly "tag := '<![CDATA[not really]]>';"
            $lines[4] | Should -BeExactly '(* trailing spaces   *)'
        }
    }

    Context 'implode restores the routine' {
        BeforeAll {
            $script:tempDir = New-TestTempDir -Prefix 'st_roundtrip'
            $l5xFile = Join-Path $fixturesDir 'sample_structured_text.L5X'

            $explodeResult = Invoke-L5xplode @('explode', '--l5x', $l5xFile, '--dir', $script:tempDir, '--force')
            if ($explodeResult.ExitCode -ne 0) { throw "Explode failed: $($explodeResult.StdErr)" }

            $script:outputL5x = Join-Path $script:tempDir 'st_out.L5X'
            $implodeResult = Invoke-L5xplode @('implode', '--dir', $script:tempDir, '--l5x', $script:outputL5x, '--force')
            if ($implodeResult.ExitCode -ne 0) { throw "Implode failed: $($implodeResult.StdErr)" }

            [xml]$script:xml = Get-Content $script:outputL5x
            $aoiRoutines = @($script:xml.RSLogix5000Content.Controller.AddOnInstructionDefinitions.AddOnInstruction.Routines.Routine)
            $script:aoiRoutine  = $aoiRoutines | Where-Object { $_.Name -eq 'AoiStLogic' }
            $script:edgeRoutine = $aoiRoutines | Where-Object { $_.Name -eq 'AoiStEdgeCases' }
            $script:programRoutine = $script:xml.RSLogix5000Content.Controller.Programs.Program.Routines.Routine
        }

        AfterAll {
            $ProgressPreference = 'SilentlyContinue'
            if (Test-Path $script:tempDir) { Remove-Item $script:tempDir -Recurse -Force }
        }

        It 'restores the routine name and type' {
            $script:aoiRoutine.Name | Should -Be 'AoiStLogic'
            $script:aoiRoutine.Type | Should -Be 'ST'
        }

        It 'restores the AOI routine description' {
            $script:aoiRoutine.Description.InnerText | Should -Match 'AOI structured text routine description'
        }

        It 'restores the program routine description' {
            $script:programRoutine.Description.InnerText | Should -Match 'Program structured text routine description'
        }

        It 'restores every line in order' {
            $lines = @($script:aoiRoutine.STContent.Line)
            $lines.Count | Should -Be 4
            $lines[0].Number | Should -Be '0'
            $lines[0].'#cdata-section' | Should -Be 'Counter := Counter + 1;'
            $lines[3].'#cdata-section' | Should -Be 'END_IF;'
        }

        # InnerText rather than #cdata-section: a line containing ]]> cannot live in one CDATA
        # section, so it comes back split across two and must be read as the concatenation.
        It 'restores XML-hostile lines byte for byte' {
            $lines = @($script:edgeRoutine.STContent.Line)
            $lines.Count | Should -Be 5
            $lines[0].InnerText | Should -BeExactly 'IF x < 5 AND y > 3 THEN'
            $lines[1].InnerText | Should -BeExactly "s := 'A & B';"
            $lines[2].InnerText | Should -BeExactly 'IF a[b[i]]> 0 THEN'
            $lines[3].InnerText | Should -BeExactly "tag := '<![CDATA[not really]]>';"
            $lines[4].InnerText | Should -BeExactly '(* trailing spaces   *)'
        }

        It 'keeps the line content in CDATA rather than escaping it' {
            $raw = Get-Content $script:outputL5x -Raw
            $raw | Should -Match ([regex]::Escape('<![CDATA[IF x < 5 AND y > 3 THEN]]>'))
            $raw | Should -Not -Match ([regex]::Escape('IF x &lt; 5'))
        }
    }

    # Directories exploded before the routine element was persisted contain only the .st file.
    # Those must still implode, even though the discarded metadata cannot be recovered.
    Context 'legacy exploded directory with no routine element file' {
        BeforeAll {
            $script:tempDir = New-TestTempDir -Prefix 'st_legacy'
            $l5xFile = Join-Path $fixturesDir 'sample_structured_text.L5X'

            $explodeResult = Invoke-L5xplode @('explode', '--l5x', $l5xFile, '--dir', $script:tempDir, '--force')
            if ($explodeResult.ExitCode -ne 0) { throw "Explode failed: $($explodeResult.StdErr)" }

            # Reproduce the old layout by removing the element file next to each .st file.
            Get-ChildItem $script:tempDir -Recurse -Filter '*.st' | ForEach-Object {
                $sibling = [System.IO.Path]::ChangeExtension($_.FullName, '.xml')
                if (Test-Path $sibling) { Remove-Item $sibling -Force }
            }

            $script:outputL5x = Join-Path $script:tempDir 'st_legacy_out.L5X'
            $script:implodeResult = Invoke-L5xplode @('implode', '--dir', $script:tempDir, '--l5x', $script:outputL5x, '--force')
        }

        AfterAll {
            $ProgressPreference = 'SilentlyContinue'
            if (Test-Path $script:tempDir) { Remove-Item $script:tempDir -Recurse -Force }
        }

        It 'still implodes' {
            $script:implodeResult.ExitCode | Should -Be 0
        }

        It 'rebuilds the routine from the .st file alone' {
            [xml]$xml = Get-Content $script:outputL5x
            $routines = @($xml.RSLogix5000Content.Controller.AddOnInstructionDefinitions.AddOnInstruction.Routines.Routine)
            $routine = $routines | Where-Object { $_.Name -eq 'AoiStLogic' }
            $routine.Type | Should -Be 'ST'
            @($routine.STContent.Line).Count | Should -Be 4
        }

        It 'still round-trips XML-hostile lines without the routine element' {
            [xml]$xml = Get-Content $script:outputL5x
            $routines = @($xml.RSLogix5000Content.Controller.AddOnInstructionDefinitions.AddOnInstruction.Routines.Routine)
            $edge = $routines | Where-Object { $_.Name -eq 'AoiStEdgeCases' }
            $lines = @($edge.STContent.Line)
            $lines.Count | Should -Be 5
            $lines[2].InnerText | Should -BeExactly 'IF a[b[i]]> 0 THEN'
            $lines[3].InnerText | Should -BeExactly "tag := '<![CDATA[not really]]>';"
        }

        It 'cannot recover the description that the old layout never stored' {
            $content = Get-Content $script:outputL5x -Raw
            $content | Should -Not -Match 'AOI structured text routine description'
        }
    }
}
