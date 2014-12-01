{
  Copyright 2014-2014 Michalis Kamburelis.

  This file is part of "Castle Game Engine".

  "Castle Game Engine" is free software; see the file COPYING.txt,
  included in this distribution, for details about the copyright.

  "Castle Game Engine" is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

  ----------------------------------------------------------------------------
}

{ Creating Android package. }
unit ToolAndroidPackage;

interface

uses CastleUtils, CastleStringUtils,
  ToolUtils, ToolArchitectures;

procedure CreateAndroidPackage(const ProjectName: string;
  const ReplaceMacros: TReplaceMacros;
  const Icons: TIconFileNames; const DataPath: string;
  const Files: TCastleStringList;
  const AndroidLibrarySubdir, AndroidLibrary, OutputPath: string);

implementation

uses SysUtils,
  CastleURIUtils, CastleWarnings, CastleFilesUtils, CastleImages,
  ToolEmbeddedImages;

procedure CreateAndroidPackage(const ProjectName: string;
  const ReplaceMacros: TReplaceMacros;
  const Icons: TIconFileNames; const DataPath: string;
  const Files: TCastleStringList;
  const AndroidLibrarySubdir, AndroidLibrary, OutputPath: string);
var
  AndroidProjectPath: string;

  { Generate simple text stuff for Android project from templates. }
  procedure GenerateFromTemplates;
  const
    AndroidManifestTemplate = {$I templates/android/AndroidManifest.xml.inc};
    StringsTemplate = {$I templates/android/res/values/strings.xml.inc};
    AndroidMkTemplate = {$I templates/android/jni/Android.mk.inc};
  begin
    StringToFile(AndroidProjectPath + 'AndroidManifest.xml',
      ReplaceMacros(AndroidManifestTemplate));

    CheckForceDirectories(AndroidProjectPath + 'res' + PathDelim + 'values');
    StringToFile(AndroidProjectPath +
      'res' + PathDelim + 'values' + PathDelim + 'strings.xml',
      ReplaceMacros(StringsTemplate));

    CheckForceDirectories(AndroidProjectPath + 'jni');
    StringToFile(AndroidProjectPath + 'jni' + PathDelim + 'Android.mk',
      ReplaceMacros(AndroidMkTemplate));
  end;

  procedure GenerateIcons;
  var
    Icon: TCastleImage;

    procedure SaveResized(const Size: Integer; const S: string);
    var
      R: TCastleImage;
      Dir: string;
    begin
      R := Icon.MakeResized(Size, Size, riBilinear);
      try
        Dir := AndroidProjectPath + 'res' + PathDelim + 'drawable-' + S + 'dpi';
        CheckForceDirectories(Dir);
        SaveImage(R, FilenameToURISafe(Dir + PathDelim + 'ic_launcher.png'));
      finally FreeAndNil(R) end;
    end;

  begin
    Icon := Icons.FindReadable;
    if Icon = nil then
    begin
      OnWarning(wtMinor, 'Icon', 'No icon in a format readable by our engine (for example, png or jpg) is specified in CastleEngineManifest.xml. Using default icon.');
      Icon := DefaultIcon;
    end;
    try
      SaveResized(36, 'l');
      SaveResized(48, 'm');
      SaveResized(72, 'h');
      SaveResized(96, 'xh');
      SaveResized(144, 'xxh');
    finally
      if Icon = DefaultIcon then
        Icon := nil else
        FreeAndNil(Icon);
    end;
  end;

  procedure GenerateAssets;
  var
    I: Integer;
    FileFrom, FileTo: string;
  begin
    CheckForceDirectories(AndroidProjectPath + 'assets');
    for I := 0 to Files.Count - 1 do
    begin
      FileFrom := DataPath + Files[I];
      FileTo := AndroidProjectPath + 'assets' + PathDelim + Files[I];
      SmartCopyFile(FileFrom, FileTo);
      if Verbose then
        Writeln('Package file: ' + Files[I]);
    end;
  end;

  procedure GenerateLibrary;
  begin
    SmartCopyFile(AndroidLibrarySubdir,
      AndroidProjectPath + 'jni' + PathDelim + AndroidLibrary);
  end;

const
  AndroidTarget = 'android-19';
var
  ProcessOutput, AndroidExe: string;
  ProcessStatus: Integer;
begin
  AndroidProjectPath := InclPathDelim(CreateTemporaryDir);

  GenerateFromTemplates;
  GenerateIcons;
  GenerateAssets;
  GenerateLibrary;

  { try to find "android" tool in $ANDROID_HOME }
  AndroidExe := InclPathDelim(GetEnvironmentVariable('ANDROID_HOME')) +
    'tools' + PathDelim + 'android'  + ExeExtension;
  { try to find "android" tool on $PATH }
  if not FileExists(AndroidExe) then
    AndroidExe := PathFileSearch('android'  + ExeExtension, false);
  if AndroidExe = '' then
    raise Exception.Create('Cannot find "android" executable on $PATH, or within $ANDROID_HOME. Install Android SDK and make sure that "android" executable is on $PATH, or that $ANDROID_HOME environment variable is set correctly.');
  RunCommandIndirPassthrough(AndroidProjectPath, AndroidExe,
    ['update', 'project', '--name', ProjectName, '--path', '.', '--target', AndroidTarget],
    ProcessOutput, ProcessStatus);
  if ProcessStatus <> 0 then
    raise Exception.Create('"android" call failed, cannot create Android apk. Inspect above error messages, and make sure Android SDK is installed correctly. Make sure that target "' + AndroidTarget + '" is installed.');

  RunCommandIndirPassthrough(AndroidProjectPath, 'ndk-build', [],
    ProcessOutput, ProcessStatus, 'NDK_DEBUG', '1');
  if ProcessStatus <> 0 then
    raise Exception.Create('"ndk-build" call failed, cannot create Android apk');

  RunCommandIndirPassthrough(AndroidProjectPath, 'ant', ['debug'],
    ProcessOutput, ProcessStatus);
  if ProcessStatus <> 0 then
    raise Exception.Create('"ant" call failed, cannot create Android apk');

  CheckRenameFile(AndroidProjectPath +
    'bin' + PathDelim + 'NativeActivity-debug.apk',
    OutputPath + PathDelim + 'NativeActivity-debug.apk');

  if not LeaveTemp then
    RemoveNonEmptyDir(AndroidProjectPath);
end;

end.
