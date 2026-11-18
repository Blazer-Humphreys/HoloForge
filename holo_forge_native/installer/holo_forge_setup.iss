; Holo Forge Windows installer (Inno Setup 6.3 or newer).
;
; Installs the Holo Forge addon into one Godot project in one go:
;   1. you pick the project (the folder with project.godot) and the Godot editor (4.7 or newer);
;   2. an older addons\holo_forge is moved to <project>\holo_forge_backup\holo_forge-<time>
;      (that folder has a .gdignore, so Godot doesn't load the old copy);
;   3. the addon is copied to <project>\addons\holo_forge;
;   4. Godot imports the project (--import), so it finds the new GDExtension;
;   5. enable_plugin.gd turns the plugin on in project.godot (Godot saves the file itself);
;   6. Godot runs the addon's self-test (addons/holo_forge/self_test.gd) headless, and the result is
;      shown on the "Self-test" page and saved to %LOCALAPPDATA%\Holo Forge\self_test_log.txt.
;
; Built by package_release.py, which passes the version and the staged addon folder:
;   ISCC /DAppVersion=0.1.0 /DAddonSource=<stage>\addons\holo_forge /O<out> holo_forge_setup.iss
;
; Unattended (for tests): setup.exe /VERYSILENT /PROJECT="<project folder>" /GODOT="<godot.exe>" /LOG="<file>"

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef AddonSource
  #error Pass /DAddonSource=<folder of the addons\holo_forge to install> (package_release.py does).
#endif

[Setup]
AppId={{6F1C2B7E-4D3A-4E8B-9C5F-1A2B3C4D5E6F}
AppName=Holo Forge
AppVersion={#AppVersion}
AppVerName=Holo Forge {#AppVersion}
AppPublisher=Holo
AppPublisherURL=https://github.com/Blazer-Humphreys/HoloForge
AppSupportURL=https://discord.gg/vRDFxNvZ77
AppUpdatesURL=https://blazer-mk1.itch.io/holo-forge
VersionInfoVersion={#AppVersion}
VersionInfoDescription=Holo Forge {#AppVersion} setup (Godot editor addon)
; It goes into a Godot project, not Program Files: no app folder, no admin, no uninstaller
; (to remove it, delete the project's addons\holo_forge folder).
CreateAppDir=no
Uninstallable=no
PrivilegesRequired=lowest
DisableProgramGroupPage=yes
LicenseFile={#AddonSource}\LICENSE.md
OutputBaseFilename=holo_forge-{#AppVersion}-windows-setup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
SetupLogging=yes

[Messages]
WelcomeLabel2=This installs Holo Forge [ver], parametric CAD for the Godot editor, into one of your Godot projects. It then turns the plugin on and runs a quick self-test.%n%nYou need the Windows 64-bit Godot editor, version 4.7 or newer.%n%nClose Godot before you continue.
FinishedHeadingLabel=Holo Forge is installed
FinishedLabelNoIcons=Open the project in Godot: the Forge tab is next to 2D, 3D and Script.%n%nYou can run the self-test again any time from Project > Tools > Holo Forge: Run Self-Test.
FinishedLabel=Open the project in Godot: the Forge tab is next to 2D, 3D and Script.%n%nYou can run the self-test again any time from Project > Tools > Holo Forge: Run Self-Test.

[Files]
Source: "{#AddonSource}\*"; DestDir: "{code:AddonDir}"; Flags: recursesubdirs createallsubdirs ignoreversion
Source: "enable_plugin.gd"; Flags: dontcopy

[Run]
Filename: "{code:GodotExe}"; Parameters: "--editor --path ""{code:ProjectDir}"""; Description: "Open the project in Godot"; Flags: postinstall nowait skipifsilent

[Code]
const
  RegKey = 'Software\Holo Forge\Installer';

var
  ProjectPage: TInputDirWizardPage;
  GodotPage: TInputFileWizardPage;
  ResultPage: TOutputMsgMemoWizardPage;
  GodotVersion: String;
  BackupPath: String;
  LogPath: String;
  TestPassed: Boolean;
  ResultText: String;

function ProjectDir(Param: String): String;
begin
  Result := RemoveBackslashUnlessRoot(Trim(ProjectPage.Values[0]));
end;

function AddonDir(Param: String): String;
begin
  Result := AddBackslash(ProjectDir('')) + 'addons\holo_forge';
end;

function GodotExe(Param: String): String;
begin
  Result := Trim(GodotPage.Values[0]);
end;

{ --- Finding and checking Godot ------------------------------------------------------------- }

{ The first Godot 4 editor program in Dir, also looking one folder down (Godot's zip unpacks to a
  folder named like the program). Skips the _console wrapper. }
function GodotIn(Dir: String): String;
var
  FR: TFindRec;
  Name: String;
begin
  Result := '';
  if (Dir = '') or not DirExists(Dir) then
    Exit;
  if FindFirst(AddBackslash(Dir) + 'Godot_v4*', FR) then
  try
    repeat
      Name := AddBackslash(Dir) + FR.Name;
      if (FR.Attributes and FILE_ATTRIBUTE_DIRECTORY) <> 0 then
      begin
        if Result = '' then
          Result := GodotIn(Name);
      end
      else if (Result = '') and (Pos('_console', Lowercase(FR.Name)) = 0) and (CompareText(ExtractFileExt(FR.Name), '.exe') = 0) then
        Result := Name;
    until (Result <> '') or not FindNext(FR);
  finally
    FindClose(FR);
  end;
end;

function GuessGodot(): String;
var
  Saved: String;
begin
  Result := ExpandConstant('{param:GODOT|}');
  if (Result = '') and RegQueryStringValue(HKCU, RegKey, 'GodotPath', Saved) then
    Result := Saved;
  if (Result <> '') and FileExists(Result) then
    Exit;
  Result := GodotIn(ExpandConstant('{userdesktop}'));
  if Result = '' then
    Result := GodotIn(AddBackslash(GetEnv('USERPROFILE')) + 'Downloads');
  if Result = '' then
    Result := GodotIn(ExpandConstant('{localappdata}\Programs\Godot'));
  if (Result = '') and FileExists(ExpandConstant('{commonpf32}\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe')) then
    Result := ExpandConstant('{commonpf32}\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe');
end;

{ The first line of "godot --version" that starts with a digit, like 4.7.1.stable.official.a13da4feb. }
function ReadGodotVersion(Exe: String): String;
var
  OutFile: String;
  Lines: TArrayOfString;
  Code, I: Integer;
  Line: String;
begin
  Result := '';
  OutFile := ExpandConstant('{tmp}\godot_version.txt');
  DeleteFile(OutFile);
  if Exec(ExpandConstant('{cmd}'), '/C ""' + Exe + '" --version > "' + OutFile + '" 2>&1"', '', SW_HIDE, ewWaitUntilTerminated, Code) then
    if LoadStringsFromFile(OutFile, Lines) then
      for I := 0 to GetArrayLength(Lines) - 1 do
      begin
        Line := Trim(Lines[I]);
        if (Result = '') and (Length(Line) > 0) and (Pos(Copy(Line, 1, 1), '0123456789') > 0) then
          Result := Line;
      end;
end;

{ Part Index (0 = major, 1 = minor) of a dotted version, or -1. }
function VersionPart(V: String; Index: Integer): Integer;
var
  I, N: Integer;
  Part: String;
begin
  N := 0;
  Part := '';
  for I := 1 to Length(V) do
  begin
    if V[I] = '.' then
    begin
      if N = Index then
        Break;
      N := N + 1;
      Part := '';
    end
    else
      Part := Part + V[I];
  end;
  if N = Index then
    Result := StrToIntDef(Part, -1)
  else
    Result := -1;
end;

function ProjectError(Dir: String): String;
begin
  Result := '';
  if Dir = '' then
    Result := 'Choose your Godot project''s folder.'
  else if not FileExists(AddBackslash(Dir) + 'project.godot') then
    Result := 'There''s no project.godot in' + #13#10 + Dir + #13#10#13#10 + 'Choose the folder that holds your Godot project''s project.godot file.';
end;

function GodotError(Exe: String; Interactive: Boolean): String;
var
  Major, Minor: Integer;
begin
  Result := '';
  if (Exe = '') or not FileExists(Exe) then
  begin
    Result := 'Choose the Godot editor program, like Godot_v4.7.1-stable_win64.exe.';
    Exit;
  end;
  GodotVersion := ReadGodotVersion(Exe);
  Major := VersionPart(GodotVersion, 0);
  Minor := VersionPart(GodotVersion, 1);
  if Major < 0 then
    Result := 'That program didn''t report a Godot version. Choose the Godot editor program, like Godot_v4.7.1-stable_win64.exe.'
  else if (Major < 4) or ((Major = 4) and (Minor < 7)) then
    Result := 'That''s Godot ' + GodotVersion + '. Holo Forge needs Godot 4.7 or newer.'
  else if (Major > 4) and Interactive then
  begin
    if MsgBox('That''s Godot ' + GodotVersion + '. Holo Forge was made for Godot 4 and hasn''t been tested on Godot ' + IntToStr(Major) + '.' + #13#10#13#10 + 'Install anyway? The self-test will show whether it works.', mbConfirmation, MB_YESNO) = IDNO then
      Result := 'Choose a Godot 4.7 or newer editor.';
  end;
end;

{ --- Wizard -------------------------------------------------------------------------------- }

procedure InitializeWizard();
var
  Saved: String;
begin
  ProjectPage := CreateInputDirPage(wpLicense, 'Godot project', 'Which Godot project should Holo Forge go into?',
    'Choose the folder that holds your project''s project.godot file. Holo Forge goes into its addons\holo_forge folder. ' +
    'If an older Holo Forge is already there, it''s moved to holo_forge_backup first.' + #13#10#13#10 +
    'Close Godot before you continue.', False, '');
  ProjectPage.Add('Project folder:');
  Saved := ExpandConstant('{param:PROJECT|}');
  if Saved = '' then
    RegQueryStringValue(HKCU, RegKey, 'ProjectPath', Saved);
  ProjectPage.Values[0] := Saved;

  GodotPage := CreateInputFilePage(ProjectPage.ID, 'Godot editor', 'Which Godot editor do you use for it?',
    'Holo Forge needs the Windows 64-bit Godot editor, version 4.7 or newer. Setup uses it to import the project, turn the plugin on and run the self-test.');
  GodotPage.Add('Godot editor program:', 'Programs (*.exe)|*.exe|All files|*.*', '.exe');
  GodotPage.Values[0] := GuessGodot();

  ResultPage := CreateOutputMsgMemoPage(wpInfoAfter, 'Self-test', 'Did Holo Forge pass its checks in your project?', '', '');
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  Err: String;
begin
  Result := True;
  Err := '';
  if CurPageID = ProjectPage.ID then
    Err := ProjectError(ProjectDir(''))
  else if CurPageID = GodotPage.ID then
    Err := GodotError(GodotExe(''), True);
  if Err <> '' then
  begin
    MsgBox(Err, mbError, MB_OK);
    Result := False;
  end;
end;

function UpdateReadyMemo(Space, NewLine, MemoUserInfoInfo, MemoDirInfo, MemoTypeInfo, MemoComponentsInfo, MemoGroupInfo, MemoTasksInfo: String): String;
begin
  Result := 'Install Holo Forge {#AppVersion} into:' + NewLine + Space + AddonDir('') + NewLine + NewLine +
    'Set it up with Godot ' + GodotVersion + ':' + NewLine + Space + GodotExe('') + NewLine + NewLine;
  if DirExists(AddonDir('')) then
    Result := Result + 'The Holo Forge that''s there now is moved to:' + NewLine + Space + AddBackslash(ProjectDir('')) + 'holo_forge_backup' + NewLine + NewLine;
  Result := Result + 'Then Godot imports the project, turns the plugin on and runs the self-test. This can take a few minutes the first time.';
end;

{ Checks again (an unattended run skips the pages), and moves an older Holo Forge aside. }
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Backup: String;
begin
  Result := ProjectError(ProjectDir(''));
  if (Result = '') and WizardSilent() then
    Result := GodotError(GodotExe(''), False);
  if Result <> '' then
    Exit;
  BackupPath := '';
  if DirExists(AddonDir('')) then
  begin
    Backup := AddBackslash(ProjectDir('')) + 'holo_forge_backup';
    ForceDirectories(Backup);
    { Godot skips a folder with a .gdignore, so it never loads the old copy's library. }
    SaveStringToFile(Backup + '\.gdignore', '', False);
    BackupPath := Backup + '\holo_forge-' + GetDateTimeString('yyyymmdd-hhnnss', #0, #0);
    if not RenameFile(AddonDir(''), BackupPath) then
    begin
      BackupPath := '';
      Result := 'Setup couldn''t move the Holo Forge that''s already in this project out of the way.' + #13#10#13#10 +
        'Close Godot (it keeps the Holo Forge library open while the project is open), then run Setup again.';
    end
    else
      Log('Moved the old addon to ' + BackupPath);
  end;
end;

function RunGodot(Params, Status: String): Integer;
begin
  WizardForm.StatusLabel.Caption := Status;
  WizardForm.FilenameLabel.Caption := '';
  Log('Running: "' + GodotExe('') + '" ' + Params);
  if not Exec(GodotExe(''), Params, ProjectDir(''), SW_HIDE, ewWaitUntilTerminated, Result) then
    Result := -1;
  Log('Exit code: ' + IntToStr(Result));
end;

procedure RunSetupSteps();
var
  Base: String;
  Code, I: Integer;
  EnableOk: Boolean;
  Lines: TArrayOfString;
  Report: String;
begin
  RegWriteStringValue(HKCU, RegKey, 'GodotPath', GodotExe(''));
  RegWriteStringValue(HKCU, RegKey, 'ProjectPath', ProjectDir(''));
  Base := '--headless --path "' + ProjectDir('') + '"';

  RunGodot(Base + ' --import', 'Godot is importing the project (this can take a few minutes the first time)...');

  ExtractTemporaryFile('enable_plugin.gd');
  Code := RunGodot(Base + ' --script "' + ExpandConstant('{tmp}\enable_plugin.gd') + '"', 'Turning on the Holo Forge plugin...');
  EnableOk := Code = 0;

  LogPath := ExpandConstant('{localappdata}\Holo Forge\self_test_log.txt');
  ForceDirectories(ExtractFileDir(LogPath));
  DeleteFile(LogPath);
  { --quit-after is a safety net: if the plugin doesn't load, nothing else would close the editor.
    The result is read from the log, not the exit code. }
  RunGodot(Base + ' --editor --quit-after 20000 -- --holo-forge-self-test "--holo-forge-self-test-log=' + LogPath + '"',
    'Running the Holo Forge self-test...');

  Report := '';
  if LoadStringsFromFile(LogPath, Lines) then
    for I := 0 to GetArrayLength(Lines) - 1 do
      Report := Report + Lines[I] + #13#10;
  TestPassed := EnableOk and (Pos('ALL CHECKS PASSED', Report) > 0);

  if TestPassed then
    ResultText := 'Holo Forge is installed in ' + ProjectDir('') + ', and it passed every check.' + #13#10#13#10 + Report
  else
  begin
    ResultText := 'Holo Forge was copied into ' + ProjectDir('') + ', but the self-test didn''t pass.' + #13#10#13#10;
    if not EnableOk then
      ResultText := ResultText + 'Setup couldn''t turn the plugin on. In Godot, open Project > Project Settings > Plugins and enable Holo Forge.' + #13#10#13#10;
    if Report = '' then
      ResultText := ResultText + 'Godot didn''t run the self-test, so the plugin probably didn''t load. Open the project in Godot and look at the Output panel for errors.' + #13#10#13#10
    else
      ResultText := ResultText + Report + #13#10;
    ResultText := ResultText + 'Please post this, and the Output panel text, in the #bug-reports forum on the Holo Forge Discord: https://discord.gg/vRDFxNvZ77';
  end;
  if BackupPath <> '' then
    ResultText := ResultText + #13#10#13#10 + 'The Holo Forge that was there before is in ' + BackupPath + '. Delete it once you''re happy with this version.';
  ResultText := ResultText + #13#10#13#10 + 'This report is saved in ' + LogPath + '.';
  { The report is part of ResultText, so the log file is rewritten with the whole summary. }
  SaveStringToFile(LogPath, ResultText + #13#10, False);
  Log(ResultText);
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
    RunSetupSteps();
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  if CurPageID = ResultPage.ID then
  begin
    if TestPassed then
      ResultPage.Description := 'Holo Forge passed its self-test in your project.'
    else
      ResultPage.Description := 'The self-test didn''t pass. Here''s what happened.';
    ResultPage.RichEditViewer.Text := ResultText;
  end;
end;
