{
  Copyright 2022-2022 Michalis Kamburelis.

  This file is part of "Castle Game Engine".

  "Castle Game Engine" is free software; see the file COPYING.txt,
  included in this distribution, for details about the copyright.

  "Castle Game Engine" is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

  ----------------------------------------------------------------------------
}

{ Playing the game. }
unit GameStatePlay;

interface

uses Classes, CastleCameras,
  CastleVectors, CastleUIState, CastleUIControls, CastleControls, CastleKeysMouse,
  CastleViewport, CastleSceneCore, X3DNodes, CastleScene, CastleSoundEngine,
  CastleBehaviors, CastleNotifications, CastleTransform,
  GameEnemy;

type
  TStatePlay = class(TUIState)
  private
    PersistentMouseLook: Boolean;
    Enemies: TEnemyList;
    procedure UpdateMouseLook;
    procedure WeaponShootAnimationStop(const Scene: TCastleSceneCore;
      const Animation: TTimeSensorNode);
  public
    constructor Create(AOwner: TComponent); override;
    procedure Start; override;
    procedure Stop; override;
    procedure Update(const SecondsPassed: Single; var HandleInput: Boolean); override;
    function Press(const Event: TInputPressRelease): Boolean; override;
  published
    { Components designed using CGE editor.
      These fields will be automatically initialized at Start. }
    WalkNavigation: TCastleWalkNavigation;
    LabelFps: TCastleLabel;
    MainViewport, MapViewport: TCastleViewport;
    SceneGun: TCastleScene;
    SoundSourceFootsteps: TCastleSoundSource;
    SoundShoot: TCastleSound;
    MainNotifications: TCastleNotifications;
    BoxDieDetect, BoxWinDetect: TCastleTransform;
  end;

var
  StatePlay: TStatePlay;

implementation

uses SysUtils, Math,
  CastleComponentSerialize, CastleLog,
  GameStateWin, GameStateDeath, GameStateOptions;

constructor TStatePlay.Create(AOwner: TComponent);
begin
  inherited;
  DesignUrl := 'castle-data:/gamestateplay.castle-user-interface';
end;

procedure TStatePlay.Start;
var
  SceneName: String;
  SceneEnemy: TCastleScene;
  Enemy: TEnemy;
  I: Integer;
begin
  inherited;

  Enemies := TEnemyList.Create(true);

  for I := 1 to 7 do
  begin
    SceneName := 'SceneKnight' + IntToStr(I);
    try
      SceneEnemy := DesignedComponent(SceneName) as TCastleScene;
      Enemy := TEnemy.Create(FreeAtStop);
      SceneEnemy.AddBehavior(Enemy);
    except
      on EComponentNotFound do
        WritelnWarning('Cannot find "%s"', [SceneName]);
    end;
  end;

  MapViewport.Items := MainViewport.Items;
end;

procedure TStatePlay.Stop;
begin
  FreeAndNil(Enemies);
  inherited;
end;

procedure TStatePlay.Update(const SecondsPassed: Single; var HandleInput: Boolean);
var
  DirectionHorizontal: TVector3;
  GameActive: Boolean;
begin
  inherited;
  LabelFps.Caption := Container.Fps.ToString;
  UpdateMouseLook;

  GameActive := Container.FrontView = Self;

  SoundSourceFootsteps.Volume := IfThen(WalkNavigation.IsWalkingOnTheGround and GameActive, 1, 0);

  MainViewport.Items.Paused := not GameActive;

  if GameActive then
  begin
    DirectionHorizontal := MainViewport.Camera.Direction;
    if not VectorsParallel(DirectionHorizontal, MainViewport.Camera.GravityUp) then
      MakeVectorsOrthoOnTheirPlane(DirectionHorizontal, MainViewport.Camera.GravityUp);

    MapViewport.Camera.SetView(
      MainViewport.Camera.WorldTranslation + Vector3(0, 30, 0),
      Vector3(0, -1, 0),
      DirectionHorizontal
    );

    if BoxWinDetect.WorldBoundingBox.Contains(MainViewport.Camera.WorldTranslation) then
    begin
      Container.PushView(StateWin);
      Exit;
    end;

    if BoxDieDetect.WorldBoundingBox.Contains(MainViewport.Camera.WorldTranslation) then
    begin
      Container.PushView(StateDeath);
      Exit;
    end;
  end;
end;

procedure TStatePlay.UpdateMouseLook;
begin
  WalkNavigation.MouseLook := (Container.FrontView = Self) and
    ( PersistentMouseLook or
      (buttonRight in Container.MousePressed) );
end;

procedure TStatePlay.WeaponShootAnimationStop(const Scene: TCastleSceneCore;
  const Animation: TTimeSensorNode);
begin
  Scene.PlayAnimation('idle', true);
end;

function TStatePlay.Press(const Event: TInputPressRelease): Boolean;
var
  HitEnemy: TEnemy;
  PlayAnimationParams: TPlayAnimationParameters;
begin
  Result := inherited;
  if Result then Exit; // allow the ancestor to handle keys

  if Container.FrontView = Self then
  begin
    if Event.IsKey(keyF4) then
    begin
      PersistentMouseLook := not PersistentMouseLook;
      UpdateMouseLook;
      Exit(true);
    end;

    if Event.IsMouseButton(buttonLeft) then
    begin
      if MainViewport.TransformUnderMouse <> nil then
        WritelnLog('Clicked on ' + MainViewport.TransformUnderMouse.Name);

      PlayAnimationParams := TPlayAnimationParameters.Create;
      try
        PlayAnimationParams.Name := 'primary';
        PlayAnimationParams.StopNotification := {$ifdef FPC}@{$endif} WeaponShootAnimationStop;
        PlayAnimationParams.Loop := false;
        SceneGun.PlayAnimation(PlayAnimationParams);
      finally FreeAndNil(PlayAnimationParams) end;

      SoundEngine.Play(SoundShoot);

      { We clicked on enemy if
        - TransformUnderMouse indicates we hit something
        - It has a behavior of TEnemy. }
      if (MainViewport.TransformUnderMouse <> nil) and
         (MainViewport.TransformUnderMouse.FindBehavior(TEnemy) <> nil) then
      begin
        HitEnemy := MainViewport.TransformUnderMouse.FindBehavior(TEnemy) as TEnemy;
        HitEnemy.Hurt;
        MainNotifications.Show('Killed ' + HitEnemy.Parent.Name);
      end;

      Exit(true);
    end;

    if Event.IsKey(keyEscape) then
    begin
      StateOptions.OverGame := true;
      Container.PushView(StateOptions);
      Exit(true);
    end;

    if Event.IsKey(keyP) then
    begin
      Container.PushView(StateWin);
      Exit(true);
    end;

    if Event.IsKey(keyO) then
    begin
      Container.PushView(StateDeath);
      Exit(true);
    end;
  end;

  if Event.IsKey(keyF5) then
  begin
    MainNotifications.Show('Saved screenshot to ' + Container.SaveScreenToDefaultFile);
    Exit(true);
  end;
end;

end.
