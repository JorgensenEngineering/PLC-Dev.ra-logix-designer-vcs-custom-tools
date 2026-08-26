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

Describe 'l5xplode CLI validation' {

    Context 'explode with missing required options' {
        It 'reports error when --l5x is not provided' {
            $tempDir = New-TestTempDir -Prefix 'l5xplode_cli'
            try {
                $result = Invoke-L5xplode @('explode', '--dir', $tempDir)
                $result.ExitCode | Should -Not -Be 0
                $result.StdErr | Should -Match "--l5x.*required|required.*--l5x"
            }
            finally {
                $ProgressPreference = 'SilentlyContinue'
                if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }
            }
        }

        It 'reports error when --dir is not provided' {
            $l5xFile = Join-Path $fixturesDir 'sample_with_dependencies.L5X'
            $result = Invoke-L5xplode @('explode', '--l5x', $l5xFile)
            $result.ExitCode | Should -Not -Be 0
            $result.StdErr | Should -Match "--dir.*required|required.*--dir"
        }
    }

    Context 'explode with non-existent L5X file' {
        It 'reports the file-exists validation message naming the option' {
            $tempDir = New-TestTempDir -Prefix 'l5xplode_cli'
            try {
                $result = Invoke-L5xplode @('explode', '--l5x', 'C:\nonexistent\file.L5X', '--dir', $tempDir, '--force')
                $result.ExitCode | Should -Not -Be 0
                $result.StdErr | Should -Match ([regex]::Escape('Option "--l5x" must be a file which exists.'))
            }
            finally {
                $ProgressPreference = 'SilentlyContinue'
                if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }
            }
        }
    }

    Context 'explode with wrong file extension' {
        It 'reports the extension validation message naming the option' {
            $tempDir = New-TestTempDir -Prefix 'l5xplode_cli'
            $txtFile = Join-Path $tempDir 'notanl5x.txt'
            Set-Content -Path $txtFile -Value 'hello'
            try {
                $result = Invoke-L5xplode @('explode', '--l5x', $txtFile, '--dir', $tempDir, '--force')
                $result.ExitCode | Should -Not -Be 0
                $result.StdErr | Should -Match ([regex]::Escape('Option "--l5x" must end with .l5x'))
            }
            finally {
                $ProgressPreference = 'SilentlyContinue'
                if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }
            }
        }
    }

    # System.CommandLine 2.0.11 changed Option.Name to include the leading dashes. Our validators
    # used to prepend their own, producing "----l5x". Exit codes alone did not catch it.
    Context 'validation messages render the option name exactly once' {
        It 'never emits an option name with more than two leading dashes' {
            $tempDir = New-TestTempDir -Prefix 'l5xplode_cli'
            try {
                $result = Invoke-L5xplode @('explode', '--l5x', 'C:\nonexistent\file.L5X', '--dir', $tempDir, '--force')
                $result.StdErr | Should -Not -Match '-{3,}'
            }
            finally {
                $ProgressPreference = 'SilentlyContinue'
                if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }
            }
        }
    }

    Context 'dependencies command option validation' {
        It 'reports error when --l5x is not provided' {
            $result = Invoke-L5xplode @('dependencies')
            $result.ExitCode | Should -Not -Be 0
            $result.StdErr | Should -Match "--l5x.*required|required.*--l5x"
        }

        It 'reports the file-exists validation message naming the option' {
            $result = Invoke-L5xplode @('dependencies', '--l5x', 'C:\nonexistent\file.L5X')
            $result.ExitCode | Should -Not -Be 0
            $result.StdErr | Should -Match ([regex]::Escape('Option "--l5x" must be a file which exists.'))
        }
    }

    Context 'implode with missing required options' {
        It 'reports error when --dir is not provided' {
            $result = Invoke-L5xplode @('implode', '--l5x', 'output.L5X')
            $result.ExitCode | Should -Not -Be 0
            $result.StdErr | Should -Match "--dir.*required|required.*--dir"
        }

        It 'reports error when --l5x is not provided' {
            $tempDir = New-TestTempDir -Prefix 'l5xplode_cli'
            try {
                $result = Invoke-L5xplode @('implode', '--dir', $tempDir)
                $result.ExitCode | Should -Not -Be 0
                $result.StdErr | Should -Match "--l5x.*required|required.*--l5x"
            }
            finally {
                $ProgressPreference = 'SilentlyContinue'
                if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }
            }
        }
    }

    Context 'no subcommand provided' {
        It 'shows help text on stdout' {
            $result = Invoke-L5xplode @()
            $result.StdOut | Should -Match 'l5xplode'
        }
    }

    Context 'unknown subcommand' {
        It 'reports an error on stderr' {
            $result = Invoke-L5xplode @('bogus')
            $result.ExitCode | Should -Not -Be 0
            $result.StdErr | Should -Match 'Unrecognized command or argument'
        }
    }
}
