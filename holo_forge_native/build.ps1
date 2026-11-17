# Builds holo_forge_native.dll (Release) and copies it with its DLLs into
# godot-board-racing/addons/holo_forge/bin. Build trees live on C: (D: is short on space).
# Run: powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1 [-Clean]
param([switch]$Clean)

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$buildRoot = "C:\Users\Blaze\holo_forge_build"
$vcpkg = Join-Path $buildRoot "vcpkg"
$buildDir = Join-Path $buildRoot "build"

function Find-Tool([string]$name, [string[]]$candidates) {
    $onPath = Get-Command $name -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }
    foreach ($pattern in $candidates) {
        $hit = Get-ChildItem $pattern -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    throw "Could not find $name"
}

$cmake = Find-Tool "cmake.exe" @(
    "C:\Program Files\CMake\bin\cmake.exe",
    (Join-Path $vcpkg "downloads\tools\cmake-*\cmake-*\bin\cmake.exe")
)
$python = Find-Tool "python.exe" @(
    "$env:LOCALAPPDATA\Programs\Python\Python313\python.exe"
)
# The Microsoft Store "python.exe" stub cannot run scripts; prefer the real install.
if ($python -like "*WindowsApps*") { $python = "$env:LOCALAPPDATA\Programs\Python\Python313\python.exe" }

Write-Host "cmake:  $cmake"
Write-Host "python: $python"

if ($Clean -and (Test-Path $buildDir)) { Remove-Item -Recurse -Force $buildDir }

& $cmake -S $root -B $buildDir -G "Visual Studio 17 2022" -A x64 `
    "-DCMAKE_TOOLCHAIN_FILE=$vcpkg\scripts\buildsystems\vcpkg.cmake" `
    "-DVCPKG_TARGET_TRIPLET=x64-windows-release" `
    "-DVCPKG_HOST_TRIPLET=x64-windows-release" `
    "-DVCPKG_OVERLAY_TRIPLETS=$root\triplets" `
    "-DVCPKG_INSTALLED_DIR=$buildRoot\vcpkg_installed" `
    "-DPython3_EXECUTABLE=$python"
if ($LASTEXITCODE -ne 0) { throw "CMake configure failed" }

& $cmake --build $buildDir --config Release --parallel
if ($LASTEXITCODE -ne 0) { throw "Build failed" }

Write-Host "Built. DLLs copied to $root\..\godot-board-racing\addons\holo_forge\bin"
