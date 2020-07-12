{ Main "playing game" state, where most of the game logic takes place.

  Feel free to use this code as a starting point for your own projects.
  (This code is in public domain, unlike most other CGE code which
  is covered by the LGPL license variant, see the COPYING.txt file.) }
unit GameStatePlay;

interface

uses Classes,
  CastleUIState, CastleComponentSerialize, CastleUIControls, CastleControls,
  CastleKeysMouse, CastleViewport, CastleScene, CastleVectors;

type
  { Main "playing game" state, where most of the game logic takes place. }
  TStatePlay = class(TUIState)
  private
    { DragonFlying and DragonFlyingTarget manage currect dragon (SceneDragon)
      animation and it's movement. }
    DragonFlying: Boolean;
    DragonFlyingTarget: TVector2;

    { Components designed using CGE editor, loaded from state_play.castle-user-interface. }
    LabelFps: TCastleLabel;
    MainViewport: TCastleViewport;
    SceneDragon: TCastleScene;
    CheckboxCameraFollow: TCastleCheckbox;
  public
    procedure Start; override;
    procedure Update(const SecondsPassed: Single; var HandleInput: Boolean); override;
    function Press(const Event: TInputPressRelease): Boolean; override;
  end;

var
  StatePlay: TStatePlay;

implementation

uses SysUtils, Math,
  GameStateMenu;

{ TStatePlay ----------------------------------------------------------------- }

procedure TStatePlay.Start;
var
  UiOwner: TComponent;
begin
  inherited;

  { Load designed user interface }
  InsertUserInterface('castle-data:/state_play.castle-user-interface', FreeAtStop, UiOwner);

  { Find components, by name, that we need to access from code }
  LabelFps := UiOwner.FindRequiredComponent('LabelFps') as TCastleLabel;
  MainViewport := UiOwner.FindRequiredComponent('MainViewport') as TCastleViewport;
  SceneDragon := UiOwner.FindRequiredComponent('SceneDragon') as TCastleScene;
  CheckboxCameraFollow := UiOwner.FindRequiredComponent('CheckboxCameraFollow') as TCastleCheckbox;
end;

procedure TStatePlay.Update(const SecondsPassed: Single; var HandleInput: Boolean);
const
  DragonSpeed: TVector2 = (Data: (3000, 1500));
var
  T: TVector2;
  CamPos: TVector3;
begin
  inherited;
  { This virtual method is executed every frame.}

  LabelFps.Caption := 'FPS: ' + Container.Fps.ToString;

  if DragonFlying then
  begin
    { Update SceneDragon.TranslationXY to reach DragonFlyingTarget. }
    T := SceneDragon.TranslationXY;
    if T.X < DragonFlyingTarget.X then
      T.X := Min(DragonFlyingTarget.X, T.X + DragonSpeed.X * SecondsPassed)
    else
      T.X := Max(DragonFlyingTarget.X, T.X - DragonSpeed.X * SecondsPassed);
    if T.Y < DragonFlyingTarget.Y then
      T.Y := Min(DragonFlyingTarget.Y, T.Y + DragonSpeed.Y * SecondsPassed)
    else
      T.Y := Max(DragonFlyingTarget.Y, T.Y - DragonSpeed.Y * SecondsPassed);
    SceneDragon.TranslationXY := T;

    { Check did we reach the DragonFlyingTarget. Note that we can compare floats
      using exact "=" operator (no need to use SameValue), because
      our Min/Maxes above make sure that we will reach the *exact* DragonFlyingTarget
      value. }
    if (T.X = DragonFlyingTarget.X) and
       (T.Y = DragonFlyingTarget.Y) then
    begin
      DragonFlying := false;
      SceneDragon.PlayAnimation('idle', true);
    end else
    { If we're still flying then
      update SceneDragon.Scale to reflect direction we're flying to.
      Flipping Scale.X is an easy way to flip 2D objects. }
    if DragonFlyingTarget.X > SceneDragon.Translation.X then
      SceneDragon.Scale := Vector3(-1, 1, 1)
    else
      SceneDragon.Scale := Vector3(1, 1, 1);
  end;

  if CheckboxCameraFollow.Checked then
  begin
    CamPos := MainViewport.Camera.Position;
    CamPos.X := SceneDragon.Translation.X;
    MainViewport.Camera.Position := CamPos;
  end;
end;

function TStatePlay.Press(const Event: TInputPressRelease): Boolean;
begin
  Result := inherited;
  if Result then Exit; // allow the ancestor to handle keys

  { This virtual method is executed when user presses
    a key, a mouse button, or touches a touch-screen.

    Note that each UI control has also events like OnPress and OnClick.
    These events can be used to handle the "press", if it should do something
    specific when used in that UI control.
    The TStatePlay.Press method should be used to handle keys
    not handled in children controls.
  }

  if Event.IsMouseButton(mbLeft) then
  begin
    DragonFlyingTarget := MainViewport.PositionTo2DWorld(Event.Position, true);
    if not DragonFlying then
    begin
      SceneDragon.PlayAnimation('flying', true);
      DragonFlying := true;
    end;

    Exit(true); // click was handled
  end;

  if Event.IsKey(keyF5) then
  begin
    Container.SaveScreenToDefaultFile;
    Exit(true);
  end;

  if Event.IsKey(keyEscape) then
  begin
    TUIState.Current := StateMenu;
    Exit(true);
  end;
end;

end.
