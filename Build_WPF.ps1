# Forest Studio v0.4.1: build WPF shell with Windows PowerShell 5.1 / .NET Framework.
# Resolve WPF assemblies from the runtime (GAC), not from bare DLL names.
$ErrorActionPreference = 'Stop'

try {
    if ($PSVersionTable.PSEdition -ne 'Desktop') {
        throw 'This builder requires Windows PowerShell 5.1 (powershell.exe), not PowerShell 7 (pwsh.exe).'
    }

    $base = Split-Path -Parent $MyInvocation.MyCommand.Path
    $source = Join-Path $base 'ForestStudio.Wpf.cs'
    $output = Join-Path $base 'ForestStudio.Wpf.dll'

    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "Missing C# source: $source"
    }

    Write-Host 'Forest Studio WPF - build v0.4.1'
    Write-Host ('.NET Framework runtime: ' + [System.Runtime.InteropServices.RuntimeEnvironment]::GetSystemVersion())
    Write-Host 'Resolving reference assemblies:'

    # Use the actual installed .NET Framework assemblies. This works without a
    # separate Developer Pack on systems where desktop WPF is installed.
    $names = @('System', 'System.Core', 'System.Xaml', 'System.Windows.Forms', 'System.Drawing', 'WindowsBase', 'PresentationCore', 'PresentationFramework')
    $references = New-Object 'System.Collections.Generic.List[string]'
    foreach ($name in $names) {
        try {
            Add-Type -AssemblyName $name -ErrorAction Stop
            $assembly = [AppDomain]::CurrentDomain.GetAssemblies() |
                Where-Object { $_.GetName().Name -eq $name -and -not [string]::IsNullOrEmpty($_.Location) } |
                Select-Object -First 1
            if ($null -eq $assembly -or -not (Test-Path -LiteralPath $assembly.Location -PathType Leaf)) {
                throw "Assembly found but its DLL path is unavailable: $name"
            }
            $references.Add($assembly.Location)
            Write-Host ('  ' + $name + ': ' + $assembly.Location)
        }
        catch {
            throw "Unable to load $name from the installed .NET Framework. Check the Windows WPF/.NET Framework 4.x installation. Detail: $($_.Exception.Message)"
        }
    }

    if (Test-Path -LiteralPath $output) {
        Remove-Item -LiteralPath $output -Force
    }

    # Read UTF-8 explicitly (Russian labels in C# must stay intact).
    $sourceCode = [System.IO.File]::ReadAllText($source, [System.Text.Encoding]::UTF8)
    Write-Host 'Compiling ForestStudio.Wpf.dll ...'
    Add-Type -TypeDefinition $sourceCode -Language CSharp -ReferencedAssemblies $references.ToArray() `
        -OutputAssembly $output -OutputType Library -ErrorAction Stop

    if (-not (Test-Path -LiteralPath $output -PathType Leaf)) {
        throw 'Compiler returned, but ForestStudio.Wpf.dll was not created.'
    }
    $size = (Get-Item -LiteralPath $output).Length
    if ($size -lt 1024) { throw "Unexpected DLL size: $size bytes." }

    Write-Host ('OK: ForestStudio.Wpf.dll created (' + $size + ' bytes).') -ForegroundColor Green
    Write-Host ('Location: ' + $output)
    exit 0
}
catch {
    Write-Host ''
    Write-Host 'BUILD FAILED:' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    if ($_.InvocationInfo -and $_.InvocationInfo.PositionMessage) {
        Write-Host $_.InvocationInfo.PositionMessage
    }
    exit 1
}
