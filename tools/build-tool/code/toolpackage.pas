{
  Copyright 2014-2018 Michalis Kamburelis.

  This file is part of "Castle Game Engine".

  "Castle Game Engine" is free software; see the file COPYING.txt,
  included in this distribution, for details about the copyright.

  "Castle Game Engine" is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

  ----------------------------------------------------------------------------
}

{ Packaging data in archives. }
unit ToolPackage;

{$I castleconf.inc}

interface

type
  TPackageFormat = (
    pfDefault,
    pfDirectory,
    pfZip,
    pfTarGz,
    pfIosArchiveDevelopment,
    pfIosArchiveAdHoc,
    pfIosArchiveAppStore
  );
  TPackageFormatNoDefault = pfDirectory..High(TPackageFormat);

  TPackageDirectory = class
  private
    TemporaryDir: string;
    FPath: string;
    FTopDirectoryName: string;

    { Absolute path (ends with path delimiter) under which you should
      store your files. They will end up being packaged,
      under TopDirectoryName. }
    property Path: string read FPath;
    property TopDirectoryName: string read FTopDirectoryName;
  public
    constructor Create(const ATopDirectoryName: string);
    destructor Destroy; override;

    { Create final archive. It will be placed within OutputProjectPath.
      PackageName should contain only the base name, without extension. }
    procedure Make(const OutputProjectPath: string; const PackageFileName: string;
      const PackageFormat: TPackageFormatNoDefault);

    { Add file to the package. SourceFileName must be an absolute filename,
      DestinationFileName must be relative within package. }
    procedure Add(const SourceFileName, DestinationFileName: string);

    { Set the Unix executable bit on given file. Name is relative to package path,
      just like DestinationFileName for @link(Add). }
    procedure MakeExecutable(const Name: string);

    { Generate auto_generated/CastleDataInformation.xml file inside
      DataName subdirectory of the archive. }
    procedure AddDataInformation(const DataName: String);
  end;

{ Generate auto_generated/CastleDataInformation.xml file inside
  CurrentDataPath, if it exists.
  CurrentDataPath may but doesn't have to end with PathDelim. }
procedure GenerateDataInformation(const CurrentDataPath: String);

function PackageFormatToString(const O: TPackageFormat): string;
function StringToPackageFormat(const S: string): TPackageFormat;

implementation

uses SysUtils, Process, {$ifdef UNIX} BaseUnix, {$endif}
  CastleUtils, CastleFilesUtils, CastleLog, CastleFindFiles, CastleURIUtils,
  CastleStringUtils, CastleInternalDirectoryInformation,
  ToolCommonUtils, ToolUtils;

{ TPackageDirectory ---------------------------------------------------------- }

constructor TPackageDirectory.Create(const ATopDirectoryName: string);
begin
  inherited Create;
  FTopDirectoryName := ATopDirectoryName;

  TemporaryDir := CreateTemporaryDir;

  FPath := InclPathDelim(TemporaryDir) + TopDirectoryName;
  CheckForceDirectories(FPath);
  FPath += PathDelim;
end;

destructor TPackageDirectory.Destroy;
begin
  RemoveNonEmptyDir(TemporaryDir, true);
  inherited;
end;

procedure TPackageDirectory.Make(const OutputProjectPath: string;
  const PackageFileName: string; const PackageFormat: TPackageFormatNoDefault);

  procedure PackageCommand(const PackagingExeName: String; const PackagingParameters: array of String);
  var
    FullPackageFileName, ProcessOutput, CommandExe: string;
    ProcessExitStatus: Integer;
  begin
    CommandExe := FindExe(PackagingExeName);
    if CommandExe = '' then
      raise Exception.CreateFmt('Cannot find "%s" program on $PATH. Make sure it is installed, and available on $PATH', [
        PackagingExeName
      ]);
    MyRunCommandIndir(TemporaryDir, CommandExe,
      PackagingParameters,
      ProcessOutput, ProcessExitStatus);

    if Verbose then
    begin
      Writeln('Executed package process, output:');
      Writeln(ProcessOutput);
    end;

    if ProcessExitStatus <> 0 then
      raise Exception.CreateFmt('Package process exited with error, status %d', [ProcessExitStatus]);

    FullPackageFileName := CombinePaths(OutputProjectPath, PackageFileName);
    DeleteFile(FullPackageFileName);
    CheckRenameFile(InclPathDelim(TemporaryDir) + PackageFileName, FullPackageFileName);
    Writeln('Created package ' + PackageFileName + ', size: ', SizeToStr(FileSize(FullPackageFileName)));
  end;

begin
  case PackageFormat of
    pfZip      : PackageCommand('zip', ['-q', '-r', PackageFileName, TopDirectoryName]);
    pfTarGz    : PackageCommand('tar', ['czf', PackageFileName, TopDirectoryName]);
    pfDirectory:
      begin
        if DirectoryExists(PackageFileName) then
          RemoveNonEmptyDir(PackageFileName);
        CopyDirectory(Path, PackageFileName);
        Writeln('Created directory ' + PackageFileName);
      end;
    {$ifndef COMPILER_CASE_ANALYSIS}
    else raise EInternalError.Create('TPackageDirectory.Make PackageFormat?');
    {$endif}
  end;
end;

procedure TPackageDirectory.Add(const SourceFileName, DestinationFileName: string);
begin
  SmartCopyFile(SourceFileName, Path + DestinationFileName);
  if Verbose then
    Writeln('Package file: ' + DestinationFileName);
end;

procedure TPackageDirectory.MakeExecutable(const Name: string);
begin
  {$ifdef UNIX}
  FpChmod(Path + Name,
    S_IRUSR or S_IWUSR or S_IXUSR or
    S_IRGRP or            S_IXGRP or
    S_IROTH or            S_IXOTH);
  {$else}
  WritelnWarning('Package', 'Packaging for a platform where UNIX permissions matter, but we cannot set "chmod" on this platform. This usually means that you package for Unix from Windows, and means that "executable" bit inside binary in tar.gz archive may not be set --- archive may not be 100% comfortable for Unix users');
  {$endif}
end;

procedure TPackageDirectory.AddDataInformation(const DataName: String);
begin
  GenerateDataInformation(Path + DataName);
end;

{ global --------------------------------------------------------------------- }

procedure GenerateDataInformation(const CurrentDataPath: String);
var
  DataInformationDir, DataInformationFileName: String;
  DataInformation: TDirectoryInformation;
  DirsCount, FilesCount, FilesSize: QWord;
begin
  if DirectoryExists(CurrentDataPath) then
  begin
    DataInformationDir := InclPathDelim(CurrentDataPath) + 'auto_generated';
    CheckForceDirectories(DataInformationDir);
    DataInformationFileName := DataInformationDir + PathDelim + 'CastleDataInformation.xml';
    { Do not include CastleDataInformation.xml itself on a list of existing files,
      since we don't know it's size yet. }
    DeleteFile(DataInformationFileName);

    DataInformation := TDirectoryInformation.Create;
    try
      DataInformation.Generate(FilenameToURISafe(CurrentDataPath));
      DataInformation.SaveToFile(FilenameToURISafe(DataInformationFileName));

      DataInformation.Sum(DirsCount, FilesCount, FilesSize);
      Writeln('Generated CastleDataInformation.xml.');
      Writeln(Format('Project data contains %d directories, %d files, total (uncompressed) size %s.',
        [DirsCount, FilesCount, SizeToStr(FilesSize)]));
    finally FreeAndNil(DataInformation) end;
  end;
end;

const
  PackageFormatNames: array [TPackageFormat] of string = (
    'default',
    'directory',
    'zip',
    'targz',
    'ios-archive-development',
    'ios-archive-ad-hoc',
    'ios-archive-app-store'
  );

function PackageFormatToString(const O: TPackageFormat): string;
begin
  Result := PackageFormatNames[O];
end;

function StringToPackageFormat(const S: string): TPackageFormat;
begin
  for Result in TPackageFormat do
    if AnsiSameText(PackageFormatNames[Result], S) then
      Exit;
  raise Exception.CreateFmt('Invalid package-format name "%s"', [S]);
end;

end.
