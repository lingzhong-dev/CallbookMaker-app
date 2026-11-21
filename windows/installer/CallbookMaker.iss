#ifndef MyAppVersion
  #define MyAppVersion "1.0.0"
#endif
#ifndef MyAppVersionTag
  #define MyAppVersionTag "v" + MyAppVersion
#endif
#ifndef ReleaseDir
  #define ReleaseDir "..\..\build\windows\x64\runner\Release"
#endif
#define MyAppName "CallbookMaker"
#define MyAppPublisher "Lingzhong-dev"
#define MyAppURL "https://github.com/lingzhong-dev/CallbookMaker-app"
#define MyAppExeName "CallbookMaker.exe"

[Setup]
AppId={{B4A8D2F0-7E3A-4E1B-9F72-41C98C5E7B10}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
AllowNoIcons=yes
LicenseFile=..\..\LICENSE
OutputDir=..\..\dist\windows
OutputBaseFilename=CallbookMaker-{#MyAppVersionTag}-windows-x64-setup
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequiredOverridesAllowed=dialog

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#ReleaseDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[InstallDelete]
Type: files; Name: "{app}\live_call_studio.exe"

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent
