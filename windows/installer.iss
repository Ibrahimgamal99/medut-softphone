; Medut for Windows: a per-user installer (no administrator needed) for the
; release bundle. Built by .github/workflows/desktop.yml:
;
;   iscc /DAppVersion=0.1.2 /DSourceDir=build\windows\x64\runner\Release windows\installer.iss
;
; It adds Medut to the Start menu, can start it at login, and registers the
; tel:, sip:, sips: and callto: links the way the app's Settings does
; (lib/desktop/call_links.dart), so it is listed in Settings › Default apps.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\build\windows\x64\runner\Release"
#endif
#define ProgId "Medut.CallLink"

[Setup]
AppId={{6B9A2E4C-3F1D-4C55-9E2A-6D0B7C1F8A31}
AppName=Medut
AppVersion={#AppVersion}
AppPublisher=Medut
AppPublisherURL=https://github.com/Ibrahimgamal99/medut-softphone
DefaultDirName={localappdata}\Programs\Medut
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\dist
OutputBaseFilename=medut-{#AppVersion}-windows-x64-setup
SetupIconFile=runner\resources\app_icon.ico
UninstallDisplayIcon={app}\medut.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
; An update replaces the files of a Medut that is running in the tray.
CloseApplications=force
RestartApplications=no

[Tasks]
Name: "startup"; Description: "Start Medut when I sign in to Windows"
Name: "links"; Description: "Open tel: and sip: links with Medut"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{userprograms}\Medut"; Filename: "{app}\medut.exe"

[Registry]
; Start at login, minimised to the tray (launch_at_startup writes the same value).
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "Medut"; \
  ValueData: """{app}\medut.exe"" --minimized"; Tasks: startup; Flags: uninsdeletevalue

; The link handler, by ProgId, and the Capabilities that list it in Default apps.
Root: HKCU; Subkey: "Software\Classes\{#ProgId}"; ValueType: string; ValueData: "Medut call link"; Tasks: links; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\{#ProgId}"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""; Tasks: links
Root: HKCU; Subkey: "Software\Classes\{#ProgId}\DefaultIcon"; ValueType: string; ValueData: """{app}\medut.exe"",0"; Tasks: links
Root: HKCU; Subkey: "Software\Classes\{#ProgId}\shell\open\command"; ValueType: string; ValueData: """{app}\medut.exe"" ""%1"""; Tasks: links
Root: HKCU; Subkey: "Software\Medut\Capabilities"; ValueType: string; ValueName: "ApplicationName"; ValueData: "Medut"; Tasks: links; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Medut\Capabilities"; ValueType: string; ValueName: "ApplicationDescription"; ValueData: "Calls over your SIP PBX"; Tasks: links
Root: HKCU; Subkey: "Software\Medut\Capabilities\URLAssociations"; ValueType: string; ValueName: "tel"; ValueData: "{#ProgId}"; Tasks: links
Root: HKCU; Subkey: "Software\Medut\Capabilities\URLAssociations"; ValueType: string; ValueName: "sip"; ValueData: "{#ProgId}"; Tasks: links
Root: HKCU; Subkey: "Software\Medut\Capabilities\URLAssociations"; ValueType: string; ValueName: "sips"; ValueData: "{#ProgId}"; Tasks: links
Root: HKCU; Subkey: "Software\Medut\Capabilities\URLAssociations"; ValueType: string; ValueName: "callto"; ValueData: "{#ProgId}"; Tasks: links
Root: HKCU; Subkey: "Software\RegisteredApplications"; ValueType: string; ValueName: "Medut"; ValueData: "Software\Medut\Capabilities"; Tasks: links; Flags: uninsdeletevalue

; Each scheme, for browsers that look it up directly.
Root: HKCU; Subkey: "Software\Classes\tel"; ValueType: string; ValueData: "URL:tel"; Tasks: links; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\tel"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""; Tasks: links
Root: HKCU; Subkey: "Software\Classes\tel\DefaultIcon"; ValueType: string; ValueData: """{app}\medut.exe"",0"; Tasks: links
Root: HKCU; Subkey: "Software\Classes\tel\shell\open\command"; ValueType: string; ValueData: """{app}\medut.exe"" ""%1"""; Tasks: links
Root: HKCU; Subkey: "Software\Classes\sip"; ValueType: string; ValueData: "URL:sip"; Tasks: links; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\sip"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""; Tasks: links
Root: HKCU; Subkey: "Software\Classes\sip\DefaultIcon"; ValueType: string; ValueData: """{app}\medut.exe"",0"; Tasks: links
Root: HKCU; Subkey: "Software\Classes\sip\shell\open\command"; ValueType: string; ValueData: """{app}\medut.exe"" ""%1"""; Tasks: links
Root: HKCU; Subkey: "Software\Classes\sips"; ValueType: string; ValueData: "URL:sips"; Tasks: links; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\sips"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""; Tasks: links
Root: HKCU; Subkey: "Software\Classes\sips\DefaultIcon"; ValueType: string; ValueData: """{app}\medut.exe"",0"; Tasks: links
Root: HKCU; Subkey: "Software\Classes\sips\shell\open\command"; ValueType: string; ValueData: """{app}\medut.exe"" ""%1"""; Tasks: links
Root: HKCU; Subkey: "Software\Classes\callto"; ValueType: string; ValueData: "URL:callto"; Tasks: links; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\callto"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""; Tasks: links
Root: HKCU; Subkey: "Software\Classes\callto\DefaultIcon"; ValueType: string; ValueData: """{app}\medut.exe"",0"; Tasks: links
Root: HKCU; Subkey: "Software\Classes\callto\shell\open\command"; ValueType: string; ValueData: """{app}\medut.exe"" ""%1"""; Tasks: links

[Run]
Filename: "{app}\medut.exe"; Description: "Open Medut"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; Quit the copy in the tray so its files can go.
Filename: "{sys}\taskkill.exe"; Parameters: "/IM medut.exe /F"; Flags: runhidden; RunOnceId: "QuitMedut"
