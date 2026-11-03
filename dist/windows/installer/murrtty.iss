; murrtty's per-user installer (WINDOWS_ROADMAP.md 7.4), for Inno Setup 7.
; make-installer.ps1 compiles it from an unpacked release zip:
;   ISCC /DVersion=X.Y.Z /DArch=x64|arm64 /DSource=<folder> /DOutDir=<folder> murrtty.iss
; It installs for the current user only (no administrator), into
; %LOCALAPPDATA%\Programs\murrtty, with a Start menu shortcut carrying
; murrtty's AppUserModelID and, as a task, "Open in murrtty" on folders,
; folder backgrounds and drives. Uninstalling keeps the user's files
; (%LOCALAPPDATA%\murrtty: config, session, crash reports).

#ifndef Version
  #error Pass /DVersion=X.Y.Z
#endif
#ifndef Source
  #error Pass /DSource=<the unpacked release folder>
#endif
#ifndef OutDir
  #define OutDir "."
#endif
#ifndef Arch
  #error Pass /DArch=x64 or /DArch=arm64
#endif
#if Arch == "x64"
  #define ArchName "x86_64"
  #define Allowed "x64compatible"
#elif Arch == "arm64"
  #define ArchName "aarch64"
  #define Allowed "arm64"
#else
  #error Arch must be x64 or arm64
#endif

[Setup]
; Never change the AppId: upgrades and the uninstaller find murrtty by it.
AppId={{CF44D64F-C2EA-4A32-A936-08DA32432785}
AppName=murrtty
AppVersion={#Version}
AppPublisher=Murray Kopit
AppPublisherURL=https://murrtty.org
AppSupportURL=https://github.com/murr2k/murrtty/issues
AppUpdatesURL=https://github.com/murr2k/murrtty/releases
AppCopyright=Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors; copyright (c) 2026 Murray Kopit
DefaultDirName={autopf}\murrtty
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed={#Allowed}
ArchitecturesInstallIn64BitMode={#Allowed}
; Windows 10 1809, as murrtty itself.
MinVersion=10.0.17763
OutputDir={#OutDir}
OutputBaseFilename=murrtty-{#Version}-windows-{#ArchName}-setup
SetupIconFile=..\murrtty.ico
UninstallDisplayIcon={app}\bin\murrtty.exe
UninstallDisplayName=murrtty
WizardStyle=modern
Compression=lzma2/max
SolidCompression=yes
VersionInfoVersion={#Version}
VersionInfoProductName=murrtty
VersionInfoProductVersion={#Version}
VersionInfoDescription=murrtty setup
; A running murrtty holds murrtty.exe, conpty.dll and OpenConsole.exe:
; Restart Manager closes it (murrtty quits at a session end without
; asking, and keeps its session for the next start).
CloseApplications=yes
RestartApplications=no
ChangesAssociations=yes
SetupLogging=yes

[Languages]
Name: "en"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "openhere"; Description: "Add ""Open in murrtty"" to the right-click menu of folders and drives"
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[InstallDelete]
; An upgrade replaces bin\ and share\ whole, so no file a release dropped
; stays behind.
Type: filesandordirs; Name: "{app}\bin"
Type: filesandordirs; Name: "{app}\share"

[Files]
Source: "{#Source}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
; As GTK's desktop file starts Ghostty: one instance, which a second launch
; brings forward. The AppUserModelID is the one murrtty sets for its
; windows, so the shortcut and the windows share a taskbar button.
Name: "{autoprograms}\murrtty"; Filename: "{app}\bin\murrtty.exe"; Parameters: "--gtk-single-instance=true"; WorkingDir: "{%USERPROFILE}"; AppUserModelID: "murrtty.murrtty"; Comment: "A native Windows terminal forked from Ghostty"
Name: "{autodesktop}\murrtty"; Filename: "{app}\bin\murrtty.exe"; Parameters: "--gtk-single-instance=true"; WorkingDir: "{%USERPROFILE}"; AppUserModelID: "murrtty.murrtty"; Comment: "A native Windows terminal forked from Ghostty"; Tasks: desktopicon

[Registry]
; "Open in murrtty" (Nautilus's wording), as Dolphin's action does: a new
; window in the folder, in the running murrtty if there is one. %V. as Git
; Bash's: a drive root's quoted "C:\" would end in \", which escapes the
; quote; murrtty drops the dot (Windows' own rule for a name's trailing dots).
Root: HKCU; Subkey: "Software\Classes\Directory\shell\murrtty"; ValueType: string; ValueName: ""; ValueData: "Open in murrtty"; Flags: uninsdeletekey; Tasks: openhere
Root: HKCU; Subkey: "Software\Classes\Directory\shell\murrtty"; ValueType: string; ValueName: "Icon"; ValueData: """{app}\bin\murrtty.exe"",0"; Tasks: openhere
Root: HKCU; Subkey: "Software\Classes\Directory\shell\murrtty\command"; ValueType: string; ValueName: ""; ValueData: """{app}\bin\murrtty.exe"" +new-window ""--working-directory=%V."""; Tasks: openhere
Root: HKCU; Subkey: "Software\Classes\Directory\Background\shell\murrtty"; ValueType: string; ValueName: ""; ValueData: "Open in murrtty"; Flags: uninsdeletekey; Tasks: openhere
Root: HKCU; Subkey: "Software\Classes\Directory\Background\shell\murrtty"; ValueType: string; ValueName: "Icon"; ValueData: """{app}\bin\murrtty.exe"",0"; Tasks: openhere
Root: HKCU; Subkey: "Software\Classes\Directory\Background\shell\murrtty\command"; ValueType: string; ValueName: ""; ValueData: """{app}\bin\murrtty.exe"" +new-window ""--working-directory=%V."""; Tasks: openhere
Root: HKCU; Subkey: "Software\Classes\Drive\shell\murrtty"; ValueType: string; ValueName: ""; ValueData: "Open in murrtty"; Flags: uninsdeletekey; Tasks: openhere
Root: HKCU; Subkey: "Software\Classes\Drive\shell\murrtty"; ValueType: string; ValueName: "Icon"; ValueData: """{app}\bin\murrtty.exe"",0"; Tasks: openhere
Root: HKCU; Subkey: "Software\Classes\Drive\shell\murrtty\command"; ValueType: string; ValueName: ""; ValueData: """{app}\bin\murrtty.exe"" +new-window ""--working-directory=%V."""; Tasks: openhere
; Unchecked on an upgrade: the earlier install's verbs go.
Root: HKCU; Subkey: "Software\Classes\Directory\shell\murrtty"; ValueType: none; Flags: deletekey; Tasks: not openhere
Root: HKCU; Subkey: "Software\Classes\Directory\Background\shell\murrtty"; ValueType: none; Flags: deletekey; Tasks: not openhere
Root: HKCU; Subkey: "Software\Classes\Drive\shell\murrtty"; ValueType: none; Flags: deletekey; Tasks: not openhere
; murrtty registers its name and icon for its toasts here at its first
; notification (roadmap 5.2b); the uninstaller takes it away.
Root: HKCU; Subkey: "Software\Classes\AppUserModelId\murrtty.murrtty"; Flags: uninsdeletekey dontcreatekey

[Run]
Filename: "{app}\bin\murrtty.exe"; Parameters: "--gtk-single-instance=true"; WorkingDir: "{%USERPROFILE}"; Description: "{cm:LaunchProgram,murrtty}"; Flags: nowait postinstall skipifsilent
