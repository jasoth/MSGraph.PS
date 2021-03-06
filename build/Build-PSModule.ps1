param
(
    # Directory used to base all relative paths
    [parameter(Mandatory=$false)]
    [string] $BaseDirectory = "..\",
    #
    [parameter(Mandatory=$false)]
    [string] $OutputDirectory = ".\build\release\",
    #
    [parameter(Mandatory=$false)]
    [string] $SourceDirectory = ".\src\",
    #
    [parameter(Mandatory=$false)]
    [string] $ModuleManifestPath,
    #
    [parameter(Mandatory=$false)]
    [string] $PackagesConfigPath = ".\packages.config",
    #
    [parameter(Mandatory=$false)]
    [string] $PackagesDirectory = ".\build\packages"
)

Write-Debug @"
Environment Variables
Processor_Architecture: $env:Processor_Architecture
      CurrentDirectory: $((Get-Location).ProviderPath)
          PSScriptRoot: $PSScriptRoot
"@

## Initialize
Remove-Module CommonFunctions -ErrorAction SilentlyContinue
Import-Module "$PSScriptRoot\CommonFunctions.psm1" -ErrorAction Stop

[System.IO.DirectoryInfo] $BaseDirectoryInfo = Get-PathInfo $BaseDirectory -InputPathType Directory -ErrorAction Stop
[System.IO.DirectoryInfo] $OutputDirectoryInfo = Get-PathInfo $OutputDirectory -InputPathType Directory -DefaultDirectory $BaseDirectoryInfo.FullName -ErrorAction SilentlyContinue
[System.IO.DirectoryInfo] $SourceDirectoryInfo = Get-PathInfo $SourceDirectory -InputPathType Directory -DefaultDirectory $BaseDirectoryInfo.FullName -ErrorAction Stop
[System.IO.FileInfo] $ModuleManifestFileInfo = Get-PathInfo $ModuleManifestPath -DefaultDirectory $SourceDirectoryInfo.FullName -DefaultFilename "*.psd1" -ErrorAction Stop
[System.IO.FileInfo] $PackagesConfigFileInfo = Get-PathInfo $PackagesConfigPath -DefaultDirectory $BaseDirectoryInfo.FullName -DefaultFilename "packages.config" -ErrorAction Stop
[System.IO.DirectoryInfo] $PackagesDirectoryInfo = Get-PathInfo $PackagesDirectory -InputPathType Directory -DefaultDirectory $BaseDirectoryInfo.FullName -ErrorAction SilentlyContinue

## Read Module Manifest
$ModuleManifest = Import-PowershellDataFile $ModuleManifestFileInfo.FullName
[System.IO.DirectoryInfo] $ModuleOutputDirectoryInfo = Join-Path $OutputDirectoryInfo.FullName (Join-Path $ModuleManifestFileInfo.BaseName $ModuleManifest.ModuleVersion)

## Copy Source Module Code to Module Output Directory
Assert-DirectoryExists $ModuleOutputDirectoryInfo -ErrorAction Stop | Out-Null
Copy-Item ("{0}\*" -f $SourceDirectoryInfo.FullName) -Destination $ModuleOutputDirectoryInfo.FullName -Recurse -Force

## NuGet Restore
&$PSScriptRoot\Restore-NugetPackages.ps1 -PackagesConfigPath $PackagesConfigFileInfo.FullName -OutputDirectory $PackagesDirectoryInfo.FullName

## Read Packages Configuration
$xmlPackagesConfig = New-Object xml
$xmlPackagesConfig.Load($PackagesConfigFileInfo.FullName)

## Copy Packages to Module Output Directory
foreach ($package in $xmlPackagesConfig.packages.package) {
    [string[]] $targetFrameworks = $package.targetFramework
    if (!$targetFrameworks) {
        [string[]] $targetFrameworks = "net45","netstandard1.3"
        switch ($package.id) {
            'Microsoft.Graph' { $targetFrameworks = "net45","netstandard1.3"; break }
            'Microsoft.Graph.Core' { $targetFrameworks = "net45","netstandard1.1"; break }
            'System.ValueTuple' { $targetFrameworks = "portable-net40+sl4+win8+wp8","netstandard1.0"; break }
        }
    }
    foreach ($targetFramework in $targetFrameworks) {
        [System.IO.DirectoryInfo] $PackageDirectory = Join-Path $PackagesDirectoryInfo.FullName ("{0}.{1}\???\{2}" -f $package.id, $package.version, $targetFramework) -Resolve
        [System.IO.DirectoryInfo] $PackageOutputDirectory = "{0}\{1}.{2}\{3}" -f $ModuleOutputDirectoryInfo.FullName, $package.id, $package.version, $targetFramework
        $PackageOutputDirectory
        Assert-DirectoryExists $PackageOutputDirectory -ErrorAction Stop | Out-Null
        Copy-Item ("{0}\*" -f $PackageDirectory) -Destination $PackageOutputDirectory.FullName -Recurse -Force
    }
}

## Get Module Output FileList
$ModuleFileListFileInfo = Get-ChildItem $ModuleOutputDirectoryInfo.FullName -Recurse -File
$ModuleRequiredAssembliesFileInfo = $ModuleFileListFileInfo | Where-Object Extension -eq '.dll'
$ModuleManifestOutputFileInfo = $ModuleFileListFileInfo | Where-Object Name -eq $ModuleManifestFileInfo.Name

$ModuleFileList = Get-RelativePath $ModuleFileListFileInfo.FullName -BaseDirectory $ModuleOutputDirectoryInfo.FullName -ErrorAction Stop
$ModuleRequiredAssemblies = Get-RelativePath $ModuleRequiredAssembliesFileInfo.FullName -BaseDirectory $ModuleOutputDirectoryInfo.FullName -ErrorAction Stop

## Update Module Manifest in Module Output Directory
Update-ModuleManifest -Path $ModuleManifestOutputFileInfo.FullName -FileList $ModuleFileList -NestedModules $ModuleManifest.NestedModules -CmdletsToExport $ModuleManifest.CmdletsToExport -AliasesToExport $ModuleManifest.AliasesToExport #-RequiredAssemblies $ModuleRequiredAssemblies
Write-Warning "PowerShell Core fails to load assembly if net45 dll comes before netcore dll in the FileList so fix the order before publishing."
