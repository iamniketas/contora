[Setup]
AppId={{7BC8DB04-8A03-4E8F-AF4E-1D3E4FC2B8A1}
AppName=Contora
AppVersion=0.4.0
AppPublisher=iamniketas
DefaultDirName={autopf}\Contora
DefaultGroupName=Contora
DisableDirPage=no
DisableProgramGroupPage=yes
OutputDir=C:\\Users\\Niketas\\projects\\contora\\.claude\\worktrees\\nifty-morse\\artifacts\\releases\\0.4.0
OutputBaseFilename=Setup
Compression=lzma
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\Contora.exe

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional icons:"

[Files]
Source: "C:\\Users\\Niketas\\projects\\contora\\.claude\\worktrees\\nifty-morse\\artifacts\\publish\\0.4.0\\win-x64\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Contora"; Filename: "{app}\Contora.exe"
Name: "{autodesktop}\Contora"; Filename: "{app}\Contora.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\Contora.exe"; Description: "Launch Contora"; Flags: nowait postinstall skipifsilent
