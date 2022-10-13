# Get CI parameter -- will be $True if running in CI
param(
    [Parameter()]
    [Switch]$ci
)

# Self-elevate the script if required
# from: https://blog.expta.com/2017/03/how-to-self-elevate-powershell-script.html
if (-Not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] 'Administrator')) {
   if ([int](Get-CimInstance -Class Win32_OperatingSystem | Select-Object -ExpandProperty BuildNumber) -ge 6000) {
      $CommandLine = "-File `"" + $MyInvocation.MyCommand.Path + "`" " + $MyInvocation.UnboundArguments

      try {
         Start-Process -FilePath PowerShell.exe -Verb RunAs -ArgumentList $CommandLine
      } catch {
         Write-Host "@

ERROR:

Setup MUST be run elevated to set up the environment
This includes installing dependencies and setting environment variables.

The source code for this script is available at '.github/scripts/setup-system.ps1'.

@" -ForegroundColor Red
      }

      Exit
   }
}

# Get temp folder
$temp = [System.IO.Path]::GetTempPath()
$cwd = $((Get-Location).path)

function CheckCommand {
   # Checks to see if a command exists in PATH
   param ($command)

   # Store user's existing ErrorActionPreference so we can restore it later.
   $oldPreference = $ErrorActionPreference

   $ErrorActionPreference = 'stop'

   try {
      if (Get-Command $command) {
         return $true
      } else {
         return $false
      }
   } catch {
      return $false
   } finally {
      # Restore user's ErrorActionPreference now that we're done.
      $ErrorActionPreference = $oldPreference
   }

}

Write-Host "Spacedrive Development Environment Setup" -ForegroundColor Magenta
Write-Host @"

To set up your machine for Spacedrive development, this script will check for and install the following:



- Install required build tools (MSVC, LLVM Clang, and Windows 10 SDK) (if not found)
- Install Cargo (if not found)
- Install pnpm (if not found)
- Install latest Node.js using pnpm
- Install Strawberry Perl (if no Perl executable found)
- Install vcpkg (if no VCPKG_ROOT found)
- Install ffmpeg and openssl with vcpkg

"@ 

Write-Host "Checking for Visual Studio Build Tools..." -ForegroundColor Yellow

function Install-Build-Tools {
   $downloadUri = "https://aka.ms/vs/17/release/vs_buildtools.exe"

   Read-Host @"

We'd like to run the Visual Studio Build Tools installer.

This package comes from the internet:
Source: $downloadUri

Press ENTER to run
"@

   # Download and run VS Build Tools installer. Install MSVC, Clang, and Windows 10 SDK (requried by Cargo)
   Start-BitsTransfer -Source $downloadUri -Destination "$temp\vs_buildtools.exe"
   & "$temp\vs_buildtools.exe" --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 --add Microsoft.VisualStudio.Component.VC.Llvm.Clang --add Microsoft.VisualStudio.Component.Windows10SDK.19041 --passive | Out-Null

   Write-Host "Installed build tools. Please restart this setup script once Visual Studio Installer installation completes."
   Read-Host "Press ENTER to exit"

   Exit
}

$vswherePath = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$hasVSInstaller = Test-Path -Path $vswherePath

if ($hasVSInstaller -eq $false) {
   Write-Host "Couldn't find VS Installer."

   Install-Build-Tools
}

$VSINSTALLDIR = $(& $vswherePath -latest -property installationPath -products 'Microsoft.VisualStudio.Product.BuildTools')
$VCINSTALLDIR = "$VSINSTALLDIR\VC\Tools"

$hasMSVC = Test-Path -Path "$VCINSTALLDIR\MSVC"
$hasClang = Test-Path -Path "$VCINSTALLDIR\Llvm\x64\bin"
$hasWin10SDK = Test-Path -Path "${env:ProgramFiles(x86)}\Windows Kits\10"

if (($hasMSVC -eq $false) -or ($hasClang -eq $false) -or ($hasWin10SDK -eq $false)) {
   Write-Host "Couldn't find the required build tools. Installing."

   Install-Build-Tools
}



Write-Host "Checking for Rust and Cargo..." -ForegroundColor Yellow

function Install-Rustup {
   $downloadUri = "https://win.rustup.rs/"

   Read-Host @"

We'd like to run the Cargo installer (rustup-init).

This package comes from the internet:
Source: $downloadUri

Press ENTER to run
"@

   Start-BitsTransfer -Source $downloadUri -Destination "$temp\rustup-init.exe"
   Start-Process -FilePath "$temp\rustup-init.exe" -PassThru -Wait -NoNewWindow

   Write-Host "Installed Cargo. Please restart this setup script."
   Read-Host "Press ENTER to exit"

   Exit
}

$hasCargo = CheckCommand cargo

if ($hasCargo -eq $false) {
   Write-Host "Couldn't find Cargo. Installing."

   Install-Rustup
} else {
   Write-Host "Cargo is installed."
}



Write-Host
Write-Host "Checking for pnpm..." -ForegroundColor Yellow

$hasPnpm = CheckCommand pnpm

if ($hasPnpm -eq $false) {
   Write-Host "pnpm is not installed. Installing."

   $scriptUri = "https://get.pnpm.io/install.ps1"

   Read-Host @"

We'd like to run the pnpm setup script.

This script comes from the internet:
Source: $scriptUri

Press ENTER to run
"@

   # Download and run the pnpm installer.
   Invoke-WebRequest $scriptUri -useb | Invoke-Expression

   # Set environment variables to ensure pnpm is accessible.
   $env:PNPM_HOME = [System.Environment]::GetEnvironmentVariable("PNPM_HOME", [System.EnvironmentVariableTarget]::User)
   [System.Environment]::SetEnvironmentVariable(
      "Path",
      [System.Environment]::ExpandEnvironmentVariables(
         [System.Environment]::GetEnvironmentVariable("Path", [System.EnvironmentVariableTarget]::User)
      ),
      [System.EnvironmentVariableTarget]::User
   );

} else {
   Write-Host "pnpm is installed."
}



if ($ci -eq $True) {
   # Skip Node install; CI setup takes care of installing Node for us.
   Write-Host
   Write-Host "We're in CI. Skipping Node install"
} else {
   Write-Host
   Write-Host "Using pnpm to install the latest version of Node..."
   Write-Host "This will set your Node installation to the latest stable version."

   Start-Process -FilePath "pnpm" -ArgumentList "env","use","--global","latest" -Wait -PassThru -NoNewWindow
}



$ClangPath = "$VCINSTALLDIR\Llvm\x64\bin"

# The CI has LLVM installed already, so just set the env variables.
if ($ci -eq $True) {
   Write-Host
   Write-Host "We're in CI. Skipping LLVM Clang install." -ForegroundColor Yellow

   Add-Content $env:GITHUB_ENV "LIBCLANG_PATH=$ClangPath`n"
} else {
   [System.Environment]::SetEnvironmentVariable("LIBCLANG_PATH", $ClangPath, [System.EnvironmentVariableTarget]::Machine)
}

# perl check

Write-Host
Write-Host "Checking for perl (required to build openssl, a Spacedrive dependency)..." -ForegroundColor Yellow

$hasPerl = CheckCommand perl

if ($hasPerl -eq $false) {
   Write-Host "`perl` executable not found in PATH. Downloading and installing Strawberry Perl..."

   $releasesUri = "https://strawberryperl.com/releases.json"
   # fetch most recent Stretbarry Perl release
   $downloadUri = ((Invoke-RestMethod -Method GET -Uri $releasesUri) | Where-Object archname -Contains 'MSWin32-x64-multi-thread' | Select-Object -First 1 ).edition.msi.url

   # Download and run Strawberry Perl installer. Install MSVC, Clang, and Windows 10 SDK (requried by Cargo)
   Start-BitsTransfer -Source $downloadUri -Destination "$temp\strawberry.msi"
   Start-Process -FilePath "$temp\strawberry.msi" -ArgumentList "/quiet","/passive" -Wait -PassThru

   Write-Host @"
   
Installed Strawberry Perl.
Please REBOOT YOUR SYSTEM and then rerun this script.

"@ -ForegroundColor Magenta
   Read-Host "Press ENTER to exit"

   Exit
} else {
   Write-Host "`perl` executable was found in PATH!" -ForegroundColor Green
}



Write-Host
Write-Host "Checking for vcpkg..." -ForegroundColor Yellow

if ($ci -eq $True) {
   # NOTE (8 Oct 2022, maxichrome): Not sure how to update this / CI to use new vcpkg based linking system.
   # Contributions / suggestions welcome for this!

   # If running in ci, we need to use GITHUB_ENV and GITHUB_PATH instead of the normal PATH env variables, so we set them here
   Add-Content $env:GITHUB_ENV "FFMPEG_DIR=$HOME\$foldername`n"
   Add-Content $env:GITHUB_PATH "$HOME\$foldername\bin`n" 
} else {
   $vcpkgRoot = [System.Environment]::GetEnvironmentVariable("VCPKG_ROOT")
   $vcpkgExec = "$vcpkgRoot\vcpkg"
   $hasVcpkg =  If ($vcpkgRoot -ne $null) { $true } Else { CheckCommand vcpkg -or CheckCommand $vcpkgExec }

   if ($hasVcpkg -ne $true) {
      $vcpkgRoot = "C:\vcpkg"

      Start-Process -FilePath "git" -ArgumentList 'clone','https://github.com/Microsoft/vcpkg.git',"$vcpkgRoot" -Wait -PassThru -NoNewWindow

      [System.Environment]::SetEnvironmentVariable("VCPKG_ROOT", $vcpkgRoot, [System.EnvironmentVariableTarget]::Machine)
      $vcpkgExec = "$vcpkgRoot\vcpkg.exe"
      Start-Process -FilePath "$vcpkgRoot\bootstrap-vcpkg.bat" -Wait -PassThru -NoNewWindow
   }

   Start-Process -FilePath $vcpkgExec -ArgumentList 'integrate','install' -Wait -PassThru -NoNewWindow
   Start-Process -FilePath $vcpkgExec -ArgumentList 'install','ffmpeg:x64-windows','openssl:x64-windows-static' -Wait -PassThru -NoNewWindow

   Write-Host "Copying FFmpeg DLL files to lib directory..."
   Copy-Item "$vcpkgRoot\packages\ffmpeg_x64-windows\bin\*.dll" "$cwd\apps\desktop\src-tauri\lib\"
}

# Finished!

Write-Host
Write-Host "Your machine has been set up for Spacedrive development!"
Read-Host "Press ENTER to exit"
