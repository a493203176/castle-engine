{
  Copyright 2020-2020 Michalis Kamburelis.

  This file is part of "Castle Game Engine".

  "Castle Game Engine" is free software; see the file COPYING.txt,
  included in this distribution, for details about the copyright.

  "Castle Game Engine" is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

  ----------------------------------------------------------------------------
}

{ Game initialization. }
unit GameInitialize;

interface

implementation

uses SysUtils, Classes,
  CastleWindow, CastleLog, CastleApplicationProperties, CastleDownload, CastleClassUtils,
  CastleControls, CastleUIControls, CastleColors, CastleUnicode, CastleUtils;

var
  Window: TCastleWindowBase;

{ One-time initialization of resources. }
procedure ApplicationInitialize;

  procedure TestLocalChars;

    procedure AssertEquals(const Expected, Actual: String);
    begin
      if Expected <> Actual then
        raise Exception.CreateFmt('Expected "%s", actual "%s"', [Expected, Actual]);
    end;

    { Test reading filenames using FPC RTL, without any CGE functions in the middle. }
    procedure TestReadingRtl(const FileName: String);
    var
      F: TextFile;
      S: String;
    begin
      try
        AssignFile(F, UTF8ToSystemFileName(FileName));
        Reset(F);
        try
          Readln(F, S);
          AssertEquals('Testing.', Trim(S));
        finally CloseFile(F) end;
      except
        // catch EInOutError and raise our own exception that shows a FileName
        on E: EInOutError do
          raise Exception.CreateFmt('EInOutError when reading file "%s"', [FileName]);
      end;
    end;

    { Test reading file using URL (through CGE function). }
    procedure TestReading(const URL: String);
    var
      Stream: TStream;
      S: String;
    begin
      Stream := Download(URL);
      try
        S := StreamToString(Stream);
        AssertEquals('Testing.', Trim(S));
      finally FreeAndNil(Stream) end;
    end;

    { Test reading file, whose URL is written inside another file, in UTF-8 encoding. }
    procedure TestReadingThroughReference(const URL: String);
    var
      Stream: TStream;
      ReferredURL: String;
    begin
      Stream := Download(URL);
      try
        ReferredURL := Trim(StreamToString(Stream));
        TestReading(ReferredURL);
      finally FreeAndNil(Stream) end;
    end;

  var
    DataPath: String;
  begin
    {$ifdef MSWINDOWS}
    if not FileExists(ExeNameFromGetModule) then
      raise Exception.CreateFmt('Cannot find own exe file "%s"', [ExeNameFromGetModule]);
    {$endif}

    { This is an *extremely* simplified (only correct in simplest cases) implementation
      of determining application data directory
      ( https://castle-engine.io/manual_data_directory.php ).
      We do it only for TestReadingRtl test here.
      In real CGE applications, you should always use 'castle-data:/'
      URL instead of doing it like this! }
    DataPath :=
      {$ifdef MSWINDOWS} ExtractFilePath(ExeNameFromGetModule)
      {$else} InclPathDelim(GetCurrentDir)
      {$endif} + 'data/';

    if not DirectoryExists(DataPath) then
      raise Exception.CreateFmt('Cannot find directory "%s"', [DataPath]);

    TestReadingRtl(DataPath + 'ascii_name.txt');
    TestReadingRtl(DataPath + 'name with Polish chars ćma źrebak żmija wąż królik.txt');
    TestReadingRtl(DataPath + 'name with Chinese chars 样例中文文本.txt');
    TestReadingRtl(DataPath + '样例中文文本/name with Chinese chars 样例中文文本.txt');
    TestReadingRtl(DataPath + 'name with Russian chars образец русского текста.txt');
    TestReadingRtl(DataPath + 'образец русского текста/name with Russian chars образец русского текста.txt');

    TestReading('castle-data:/ascii_name.txt');
    TestReading('castle-data:/name with Polish chars ćma źrebak żmija wąż królik.txt');
    TestReading('castle-data:/name with Chinese chars 样例中文文本.txt');
    TestReading('castle-data:/样例中文文本/name with Chinese chars 样例中文文本.txt');
    TestReading('castle-data:/name with Russian chars образец русского текста.txt');
    TestReading('castle-data:/образец русского текста/name with Russian chars образец русского текста.txt');

    TestReadingThroughReference('castle-data:/reference to file with Chinese chars.txt');
    TestReadingThroughReference('castle-data:/reference to file with Russian chars.txt');
    TestReadingThroughReference('castle-data:/reference to file with Polish chars.txt');

    // TODO: test saving too
  end;

var
  L: TCastleLabel;
begin
  TestLocalChars;

  L := TCastleLabel.Create(Application);
  L.Color := Yellow;
  L.Caption := 'All tests executed OK :)';
  L.Anchor(hpMiddle);
  L.Anchor(vpMiddle);
  Window.Controls.InsertFront(L);
end;

initialization
  ApplicationProperties.ApplicationName := 'test_local_filename_chars';

  { Start logging.
    For programs, InitializeLog is done by the program main file,
    after command-line parameters are parsed. }
  if IsLibrary then
    InitializeLog;

  { Initialize Application.OnInitialize. }
  Application.OnInitialize := @ApplicationInitialize;

  { Create and assign Application.MainWindow. }
  Window := TCastleWindowBase.Create(Application);
  Application.MainWindow := Window;
end.
