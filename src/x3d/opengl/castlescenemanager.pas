{
  Copyright 2009-2011 Michalis Kamburelis.

  This file is part of "Castle Game Engine".

  "Castle Game Engine" is free software; see the file COPYING.txt,
  included in this distribution, for details about the copyright.

  "Castle Game Engine" is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

  ----------------------------------------------------------------------------
}

{ Scene manager (TCastleSceneManager) and viewport (TCastleViewport) classes. }
unit CastleSceneManager;

interface

uses Classes, VectorMath, X3DNodes, CastleScene, CastleSceneCore, Cameras,
  GLShadowVolumeRenderer, GL, UIControls, Base3D,
  KeysMouse, Boxes3D, Background, CastleUtils, CastleClassUtils,
  GLShaders, GLImages, CastleTimeUtils,
  FGL {$ifdef VER2_2}, FGLObjectList22 {$endif};

type
  TCastleAbstractViewport = class;

  TRender3DEvent = procedure (Viewport: TCastleAbstractViewport;
    const Params: TRenderParams) of object;

  { Internal, special TRenderParams descendant that can return different
    set of base lights for some scenes. Used to implement GlobalLights,
    where MainScene and other objects need different lights.
    @exclude. }
  TManagerRenderParams = class(TRenderParams)
  private
    MainScene: T3D;
    FBaseLights: array [boolean { is main scene }] of TLightInstancesList;
  public
    constructor Create;
    destructor Destroy; override;
    function BaseLights(Scene: T3D): TAbstractLightInstancesList; override;
  end;

  { Common abstract class for things that may act as a viewport:
    TCastleSceneManager and TCastleViewport. }
  TCastleAbstractViewport = class(TUIControlPos)
  private
    FWidth, FHeight: Cardinal;
    FFullSize: boolean;
    FCamera: TCamera;
    FPaused: boolean;
    FRenderParams: TManagerRenderParams;

    FShadowVolumesPossible: boolean;
    FShadowVolumes: boolean;
    FShadowVolumesDraw: boolean;

    FBackgroundWireframe: boolean;
    FOnRender3D: TRender3DEvent;
    FHeadlightFromViewport: boolean;
    FAlwaysApplyProjection: boolean;
    FUseGlobalLights: boolean;
    DefaultHeadlightNode: TDirectionalLightNode;

    { If a texture rectangle for screen effects is ready, then
      ScreenEffectTextureDest/Src/Depth are non-zero and ScreenEffectRTT is non-nil.
      Also, ScreenEffectTextureWidth/Height indicate size of the texture,
      as well as ScreenEffectRTT.Width/Height. }
    ScreenEffectTextureDest, ScreenEffectTextureSrc: TGLuint;
    ScreenEffectTextureDepth: TGLuint;
    ScreenEffectTextureWidth: Cardinal;
    ScreenEffectTextureHeight: Cardinal;
    ScreenEffectRTT: TGLRenderToTexture;
    { Saved ScreenEffectsCount/NeedDepth result, during rendering. }
    CurrentScreenEffectsCount: Integer;
    CurrentScreenEffectsNeedDepth: boolean;

    FInput_PointingDeviceActivate: TInputShortcut;
    FOwnsInput_PointingDeviceActivate: boolean;

    procedure ItemsAndCameraCursorChange(Sender: TObject);
    procedure SetInput_PointingDeviceActivate(const Value: TInputShortcut);
  protected
    { These variables are writeable from overridden ApplyProjection. }
    FPerspectiveView: boolean;
    FPerspectiveViewAngles: TVector2Single;
    FOrthoViewDimensions: TVector4Single;
    FProjectionNear: Single;
    FProjectionFar : Single;

    ApplyProjectionNeeded: boolean;

    { Sets OpenGL projection matrix, based on scene manager MainScene's
      currently bound Viewpoint, NavigationInfo and used @link(Camera).
      Viewport's @link(Camera), if not assigned, is automatically created here,
      see @link(Camera) and CreateDefaultCamera.
      If scene manager's MainScene is not assigned, we use some default
      sensible perspective projection.

      Takes care of updating Camera.ProjectionMatrix,
      PerspectiveView, PerspectiveViewAngles, OrthoViewDimensions,
      ProjectionNear, ProjectionFar.

      This is automatically called at the beginning of our Render method,
      if it's needed.

      @seealso TCastleScene.GLProjection }
    procedure ApplyProjection; virtual;

    { Render one pass, with current camera and parameters.
      All current camera settings are saved in RenderingCamera,
      and the camera matrix is already loaded to OpenGL.

      If you want to display something 3D during rendering,
      this is the simplest method to override. (Or you can use OnRender3D
      event, which is called at the end of this method.)
      Alternatively, you can create new T3D descendant and add it to @link(Items)
      list --- but for simple (not collidable) stuff, using this method may
      be simpler.

      @param(Params Parameters specify what lights should be used
        (Params.BaseLights, Params.InShadow), and which parts of the 3D scene
        should be rendered (Params.Transparent, Params.ShadowVolumesReceivers
        --- only matching 3D objects should be rendered by this method).) }
    procedure Render3D(const Params: TRenderParams); virtual;

    { Render shadow quads for all the things rendered by @link(Render3D).
      You can use here ShadowVolumeRenderer instance, which is guaranteed
      to be initialized with TGLShadowVolumeRenderer.InitFrustumAndLight,
      so you can do shadow volumes culling. }
    procedure RenderShadowVolume; virtual;

    { Render everything from current (in RenderingCamera) camera view.
      Current RenderingCamera.Target says to where we generate the image.
      Takes method must take care of making many rendering passes
      for shadow volumes, but doesn't take care of updating generated textures. }
    procedure RenderFromViewEverything; virtual;

    { Prepare lights shining on everything.
      BaseLights contents should be initialized here.

      The implementation in this class adds headlight determined
      by the @link(Headlight) method. By default, this looks at the MainScene,
      and follows NavigationInfo.headlight and
      KambiNavigationInfo.headlightNode properties. }
    procedure InitializeLights(const Lights: TLightInstancesList); virtual;

    { Headlight used to light the scene. Returns if headlight is present,
      and if it has some custom light node. When it returns @true,
      and CustomHeadlight is set to @nil,
      we simply use default directional light for a headlight.

      Default implementation of this method in TCastleAbstractViewport
      looks at the MainScene headlight. We return if MainScene is assigned
      and TCastleSceneCore.HeadlightOn is @true.
      (HeadlightOn in turn looks
      at information in VRML/X3D file (NavigationInfo.headlight)
      and you can also always set HeadlightOn explicitly by code.)
      The custom light node
      is obtained from TCastleSceneCore.CustomHeadlight.

      You can override this method to determine the headlight in any other way. }
    function Headlight(out CustomHeadlight: TAbstractLightNode): boolean; virtual;

    { Render the 3D part of scene. Called by RenderFromViewEverything at the end,
      when everything (clearing, background, headlight, loading camera
      matrix) is done and all that remains is to pass to OpenGL actual 3D world.

      This will change Params.Transparent, Params.InShadow and Params.ShadowVolumesReceivers
      as needed. Their previous values do not matter. }
    procedure RenderFromView3D(const Params: TRenderParams); virtual;

    { Render everything (by RenderFromViewEverything) on the screen.
      Takes care to set RenderingCamera (Target = rtScreen and camera as given),
      and takes care to apply glScissor if not FullSize,
      and calls RenderFromViewEverything.

      Takes care of using ScreenEffects. For this,
      before we render to the actual screen,
      we may render a couple times to a texture by a framebuffer. }
    procedure RenderOnScreen(ACamera: TCamera);

    { The background used during rendering.
      @nil if no background should be rendered.

      The default implementation in this class does what is usually
      most natural: return MainScene.Background, if MainScene assigned. }
    function Background: TBackground; virtual;

    { Detect position/direction of the main light that produces shadows.
      The default implementation in this class looks at
      MainScene.MainLightForShadows.

      @seealso TCastleSceneCore.MainLightForShadows }
    function MainLightForShadows(
      out AMainLightPosition: TVector4Single): boolean; virtual;

    procedure SetCamera(const Value: TCamera); virtual;
    procedure Notification(AComponent: TComponent; Operation: TOperation); override;
    procedure SetContainer(const Value: IUIContainer); override;
    procedure SetShadowVolumesPossible(const Value: boolean); virtual;

    { Information about the 3D world.
      For scene maager, these methods simply return it's own properties.
      For TCastleViewport, these methods refer to scene manager.
      @groupBegin }
    function GetItems: T3D; virtual; abstract;
    function GetMainScene: TCastleScene; virtual; abstract;
    function GetShadowVolumeRenderer: TGLShadowVolumeRenderer; virtual; abstract;
    function GetMouseRayHit3D: T3D; virtual; abstract;
    function GetHeadlightCamera: TCamera; virtual; abstract;
    { @groupEnd }

    { Pass pointing device (mouse) move event to 3D world. }
    procedure PointingDeviceMove(const RayOrigin, RayDirection: TVector3Single); virtual; abstract;
    { Pass pointing device (mouse) activation/deactivation event to 3D world. }
    procedure PointingDeviceActivate(const Active: boolean); virtual; abstract;

    { Handle camera events.

      Scene manager implements collisions by looking at 3D scene,
      custom viewports implements collisions by calling their scene manager.

      @groupBegin }
    function CameraMoveAllowed(ACamera: TWalkCamera;
      const ProposedNewPos: TVector3Single; out NewPos: TVector3Single;
      const BecauseOfGravity: boolean): boolean; virtual; abstract;
    procedure CameraGetHeight(ACamera: TWalkCamera;
      out IsAbove: boolean; out AboveHeight: Single;
      out AboveGround: P3DTriangle); virtual; abstract;
    procedure CameraVisibleChange(ACamera: TObject); virtual; abstract;
    { @groupEnd }

    function GetScreenEffects(const Index: Integer): TGLSLProgram; virtual;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    { Camera projection properties.

      When PerspectiveView is @true, then PerspectiveViewAngles
      specify angles of view (horizontal and vertical), in degrees.
      When PerspectiveView is @false, then OrthoViewDimensions
      specify dimensions of ortho window (in the order: -X, -Y, +X, +Y,
      just like X3D OrthoViewpoint.fieldOfView).

      Set by every ApplyProjection call.

      @groupBegin }
    property PerspectiveView: boolean read FPerspectiveView write FPerspectiveView;
    property PerspectiveViewAngles: TVector2Single read FPerspectiveViewAngles write FPerspectiveViewAngles;
    property OrthoViewDimensions: TVector4Single read FOrthoViewDimensions write FOrthoViewDimensions;
    { @groupEnd }

    { Projection near/far values. ApplyProjection calculates it.

      Note that ProjectionFar may be ZFarInfinity.

      @groupBegin }
    property ProjectionNear: Single read FProjectionNear;
    property ProjectionFar : Single read FProjectionFar ;
    { @groupEnd }

    procedure ContainerResize(const AContainerWidth, AContainerHeight: Cardinal); override;
    function PositionInside(const X, Y: Integer): boolean; override;
    function DrawStyle: TUIControlDrawStyle; override;

    function AllowSuspendForInput: boolean; override;
    function KeyDown(Key: TKey; C: char): boolean; override;
    function KeyUp(Key: TKey; C: char): boolean; override;
    function MouseDown(const Button: TMouseButton): boolean; override;
    function MouseUp(const Button: TMouseButton): boolean; override;
    function MouseWheel(const Scroll: Single; const Vertical: boolean): boolean; override;
    function MouseMove(const OldX, OldY, NewX, NewY: Integer): boolean; override;
    procedure Idle(const CompSpeed: Single;
      const HandleMouseAndKeys: boolean;
      var LetOthersHandleMouseAndKeys: boolean); override;

    { Actual position and size of the viewport. Calculated looking
      at @link(FullSize) value, at the current container sizes
      (when @link(FullSize) is @false), and at the properties
      @link(Left), @link(Bottom), @link(Width), @link(Height)
      (when @link(FullSize) is true).

      @groupBegin }
    function CorrectLeft: Integer;
    function CorrectBottom: Integer;
    function CorrectWidth: Cardinal;
    function CorrectHeight: Cardinal;
    { @groupEnd }

    { Create default TCamera suitable for navigating in this scene.
      This is automatically used to initialize @link(Camera) property
      when @link(Camera) is @nil at ApplyProjection call.

      The implementation in base TCastleSceneManager uses MainScene.CreateCamera
      (so it will follow your VRML/X3D scene Viewpoint, NavigationInfo and such).
      If MainScene is not assigned, we will just create a simple
      TExamineCamera.

      The implementation in TCastleViewport simply calls
      SceneManager.CreateDefaultCamera. So by default all the viewport's
      cameras are created the same way, by refering to the scene manager.
      If you want you can override it to specialize CreateDefaultCamera
      for specific viewport classes.

      Overloaded version without any parameters just uses Self as owner
      of the camera.

      @groupBegin }
    function CreateDefaultCamera(AOwner: TComponent): TCamera; virtual; abstract; overload;
    function CreateDefaultCamera: TCamera; overload;
    { @groupEnd }

    { Smoothly animate current @link(Camera) to a default camera settings.

      Default camera settings are determined by calling CreateDefaultCamera.
      See TCamera.AnimateTo for details what and how is animated.

      Current @link(Camera) is created by CreateDefaultCamera if not assigned
      yet at this point. (And the animation isn't done, since such camera
      already stands at the default position.) This makes this method
      consistent: after calling it, you always know that @link(Camera) is
      assigned and going to the default position. }
    procedure CameraAnimateToDefault(const Time: TFloatTime);

    { Screen effects are shaders that post-process the rendered screen.
      If any screen effects are active, we will automatically render
      screen to a temporary texture rectangle, processing it with
      each shader.

      By default, screen effects come from GetMainScene.ScreenEffects,
      so the effects may be defined by VRML/X3D author using ScreenEffect
      nodes (see docs: [http://castle-engine.sourceforge.net/x3d_extensions_screen_effects.php]).
      Descendants may override GetScreenEffects, ScreenEffectsCount,
      and ScreenEffectsNeedDepth to add screen effects by code.
      Each viewport may have it's own, different screen effects.

      @groupBegin }
    property ScreenEffects [Index: Integer]: TGLSLProgram read GetScreenEffects;
    function ScreenEffectsCount: Integer; virtual;
    function ScreenEffectsNeedDepth: boolean; virtual;
    { @groupEnd }

    procedure GLContextClose; override;

    { Instance for headlight that should be used for this scene.
      Uses @link(Headlight) method, applies appropriate camera position/direction.
      Returns @true only if @link(Headlight) method returned @true
      and a suitable camera was present.

      HeadlightInstance remains unchanged when we return @false. }
    function HeadlightInstance(var Instance: TLightInstance): boolean;

    { Base lights used for rendering. Uses InitializeLights,
      and returns instance owned and managed by this scene manager.
      You can only use this outside PrepareResources or Render,
      as they may change this instance. }
    function BaseLights: TLightInstancesList;

    { Statistics about last rendering frame. See TRenderStatistics docs. }
    function Statistics: TRenderStatistics;
  published
    { Viewport dimensions where the 3D world will be drawn.
      When FullSize is @true (the default), the viewport always fills
      the whole container (OpenGL context area, like a window for TCastleWindowBase),
      and the values of Left, Bottom, Width, Height are ignored here.

      @seealso CorrectLeft
      @seealso CorrectBottom
      @seealso CorrectWidth
      @seealso CorrectHeight

      @groupBegin }
    property FullSize: boolean read FFullSize write FFullSize default true;
    property Width: Cardinal read FWidth write FWidth default 0;
    property Height: Cardinal read FHeight write FHeight default 0;
    { @groupEnd }

    { Camera used to render.

      Cannot be @nil when rendering. If you don't assign anything here,
      we'll create a default camera object at the nearest ApplyProjection
      call (this is the first moment when we really must have some camera).
      This default camera will be created by CreateDefaultCamera.

      This camera @italic(should not) be inside some other container
      (like on TCastleWindowCustom.Controls or TCastleControlCustom.Controls list).
      Scene manager / viewport will handle passing events to the camera on it's own,
      we will also pass our own Container to Camera.Container.
      This is desired, this way events are correctly passed
      and interpreted before passing them to 3D objects.
      And this way we avoid the question whether camera should be before
      or after the scene manager / viewport on the Controls list (as there's really
      no perfect ordering for them).

      Scene manager / viewport will "hijack" some Camera events:
      TCamera.OnVisibleChange, TWalkCamera.OnMoveAllowed,
      TWalkCamera.OnGetHeightAbove, TCamera.OnCursorChange.
      We will handle them in a proper way.

      @italic(For TCastleViewport only:)
      The TCastleViewport's camera is slightly less important than
      TCastleSceneManager.Camera, because TCastleSceneManager.Camera may be treated
      as a "central" camera. Viewport's camera may not (because you may
      have many viewports and they all deserve fair treatment).
      So e.g. headlight is done only from TCastleSceneManager.Camera
      (for mirror textures, there must be one headlight for your 3D world).
      Also VRML/X3D ProximitySensors receive events only from
      TCastleSceneManager.Camera.

      TODO: In the future it should be possible (even encouraged) to assign
      one of your custom viewport cameras also to TCastleSceneManager.Camera.
      It should also be possible to share one camera instance among a couple
      of viewports.
      For now, it doesn't work (last viewport/scene manager will hijack some
      camera events making it not working in other ones).

      @seealso TCastleSceneManager.OnCameraChanged }
    property Camera: TCamera read FCamera write SetCamera;

    { For scene manager: you can pause everything inside your 3D world,
      for viewport: you can make the camera of this viewpoint paused
      (not responsive).

      @italic(For scene manager:)

      "Paused" means that no events (key, mouse, idle) are passed to any
      @link(TCastleSceneManager.Items) or the @link(Camera).
      This is suitable if you really want to totally, unconditionally,
      make your 3D world view temporary still (for example,
      useful when entering some modal dialog box and you want
      3D scene to behave as a still background).

      You can of course still directly change some scene property,
      and then 3D world will change.
      But no change will be initialized automatically by scene manager events.

      @italic(See also): For less drastic pausing methods,
      there are other methods of pausing / disabling
      some events processing for the 3D world:

      @unorderedList(
        @item(You can set TCastleScene.TimePlaying or TCastlePrecalculatedAnimation.TimePlaying
          to @false. This is roughly equivalent to not running their Idle methods.
          This means that time will "stand still" for them,
          so their animations will not play. Although they may
          still react and change in response to mouse clicks / key presses,
          if TCastleScene.ProcessEvents.)

        @item(You can set TCastleScene.ProcessEvents to @false.
          This means that scene will not receive and process any
          key / mouse and other events (through VRML/X3D sensors).
          Some animations (not depending on VRML/X3D events processing)
          may still run, for example MovieTexture will still animate,
          if only TCastleScene.TimePlaying.)

        @item(For cameras, you can set TCamera.IgnoreAllInputs to ignore
          key / mouse clicks.)
      ) }
    property Paused: boolean read FPaused write FPaused default false;

    { See Render3D method. }
    property OnRender3D: TRender3DEvent read FOnRender3D write FOnRender3D;

    { Should we make shadow volumes possible.
      This should indicate if OpenGL context was (possibly) initialized
      with stencil buffer. }
    property ShadowVolumesPossible: boolean read FShadowVolumesPossible write SetShadowVolumesPossible default false;

    { Should we render with shadow volumes.
      You can change this at any time, to switch rendering shadows on/off.

      This works only if ShadowVolumesPossible is @true.

      Note that the shadow volumes algorithm makes some requirements
      about the 3D model: it must be 2-manifold, that is have a correctly
      closed volume. Otherwise, rendering results may be bad. You can check
      Scene.BorderEdges.Count before using this: BorderEdges.Count = 0 means
      that model is Ok, correct manifold.

      For shadows to be actually used you still need a light source
      marked as the main shadows light (kambiShadows = kambiShadowsMain = TRUE),
      see [http://castle-engine.sourceforge.net/x3d_extensions.php#section_ext_shadows]. }
    property ShadowVolumes: boolean read FShadowVolumes write FShadowVolumes default false;

    { Actually draw the shadow volumes to the color buffer, for debugging.
      If shadows are rendered (see ShadowVolumesPossible and ShadowVolumes),
      you can use this to actually see shadow volumes, for debug / demo
      purposes. Shadow volumes will be rendered on top of the scene,
      as yellow blended polygons. }
    property ShadowVolumesDraw: boolean read FShadowVolumesDraw write FShadowVolumesDraw default false;

    { If yes then the scene background will be rendered wireframe,
      over the background filled with glClearColor.

      There's a catch here: this works only if the background is actually
      internally rendered as a geometry. If the background is rendered
      by clearing the screen (this is an optimized case of sky color
      being just one simple color, and no textures),
      then it will just cover the screen as normal, like without wireframe.
      This is uncertain situation anyway (what should the wireframe
      look like in this case anyway?), so I don't consider it a bug.

      Useful especially for debugging when you want to see how your background
      geometry looks like. }
    property BackgroundWireframe: boolean
      read FBackgroundWireframe write FBackgroundWireframe default false;

    { When @true then headlight is always rendered from custom viewport's
      (TCastleViewport) camera, not from central camera (the one in scene manager).
      This is meaningless in TCastleSceneManager.

      By default this is @false, which means that when rendering
      custom viewport (TCastleViewport) we render headlight from
      TCastleViewport.SceneManager.Camera (not from current viewport's
      TCastleViewport.Camera). On one hand, this is sensible: there is exactly one
      headlight in your 3D world, and it shines from a central camera
      in SceneManager.Camera. When SceneManager.Camera is @nil (which
      may happen if you set SceneManager.DefaultViewport := false and you
      didn't assign SceneManager.Camera explicitly) headlight is never done.
      This means that when observing 3D world from other cameras,
      you will see a light shining from SceneManager.Camera.
      This is also the only way to make headlight lighting correctly reflected
      in mirror textures (like GeneratedCubeMapTexture) --- since we render
      to one mirror texture, we need a knowledge of "cental" camera for this.

      When this is @true, then each viewport actually renders headlight
      from it's current camera. This means that actually each viewport
      has it's own, independent headlight (althoug they all follow VRML/X3D
      NavigationInfo.headlight and KambiNavigationInfo settings).
      This may allow you to light your view better (if you only use
      headlight to "just make the view brighter"), but it's not entirely
      correct (in particular, mirror reflections of the headlight are
      undefined then). }
    property HeadlightFromViewport: boolean
      read FHeadlightFromViewport write FHeadlightFromViewport default false;

    { If @false, then we can assume that we're the only thing controlling
      OpenGL projection matrix. This means that we're the only viewport,
      and you do not change OpenGL projection matrix yourself.

      By default for custom viewports this is @true,
      which is safer solution (we always apply
      OpenGL projection matrix in ApplyProjection method), but also may
      be slightly slower.

      Note that for TCastleSceneManager, this is by default @false (that is,
      we assume that scene manager, if used for rendering at all
      (DefaultViewport = @true), is the only viewport). You should change
      AlwaysApplyProjection to @true for TCastleSceneManager, if you have
      both custom viewports and DefaultViewport = @true }
    property AlwaysApplyProjection: boolean
      read FAlwaysApplyProjection write FAlwaysApplyProjection default true;

    { Let MainScene.GlobalLights shine on every 3D object, not only
      MainScene. This is an easy way to lit your whole world with lights
      defined inside MainScene file. Be sure to set lights global=TRUE.

      Note that for now this assumes that MainScene coordinates equal
      world coordinates. This means that you should not transform
      the MainScene, it should be placed inside @link(TCastleSceneManager.Items)
      without wrapping in any T3DTransform. }
    property UseGlobalLights: boolean
      read FUseGlobalLights write FUseGlobalLights default false;

    { Input (mouse / key combination) to make pointing device active
      (that is, to activate VRML/X3D pointing-device sensors like TouchSensor).
      By default this requires left mouse button click.

      You can change it to any other mouse button or even to key combination.
      You can simply change properties of existing
      Input_PointingDeviceActivate value (like TInputShortcut.Key1
      or TInputShortcut.MouseButtonUse).

      Or you can even assign here your own TInputShortcut instance.
      Then you're responsible for freeing it yourself. }
    property Input_PointingDeviceActivate: TInputShortcut
      read FInput_PointingDeviceActivate write SetInput_PointingDeviceActivate;
  end;

  TCastleAbstractViewportList = class(specialize TFPGObjectList<TCastleAbstractViewport>)
  public
    { Does any viewport on the list has shadow volumes all set up? }
    function UsesShadowVolumes: boolean;
  end;

  { Scene manager that knows about all 3D things inside your world.

    Single scenes/models (like TCastleScene or TCastlePrecalculatedAnimation instances)
    can be rendered directly, but it's not always comfortable.
    Scenes have to assume that they are "one of the many" inside your 3D world,
    which means that multi-pass rendering techniques have to be implemented
    at a higher level. This concerns the need for multiple passes from
    the same camera (for shadow volumes) and multiple passes from different
    cameras (for generating textures for shadow maps, cube map environment etc.).

    Scene manager overcomes this limitation. A single SceneManager object
    knows about all 3D things in your world, and renders them all for you,
    taking care of doing multiple rendering passes for particular features.
    Naturally, it also serves as container for all your visible 3D scenes.

    @link(Items) property keeps a tree of T3D objects.
    All our 3D objects, like TCastleSceneCore (and so also TCastleScene)
    and TCastlePrecalculatedAnimationCore (and so also TCastlePrecalculatedAnimation) descend from
    T3D, and you can add them to the scene manager.
    And naturally you can implement your own T3D descendants,
    representing any 3D (possibly dynamic, animated and even interactive) object.

    TCastleSceneManager.Render can assume that it's the @italic(only) manager rendering
    to the screen (although you can safely render more 3D geometry *after*
    calling TCastleSceneManager.Render). So it's Render method takes care of

    @unorderedList(
      @item(clearing the screen,)
      @item(rendering the background of the scene,)
      @item(rendering the headlight,)
      @item(rendering the scene from given camera,)
      @item(and making multiple passes for shadow volumes and generated textures.)
    )

    For some of these features, you'll have to set the @link(MainScene) property.

    This is a TUIControl descendant, which means it's advised usage
    is to add this to TCastleWindowCustom.Controls or TCastleControlCustom.Controls.
    This passes relevant TUIControl events to all the T3D objects inside.
    Note that even when you set DefaultViewport = @false
    (and use custom viewports, by TCastleViewport class, to render your 3D world),
    you still should add scene manager to the controls list
    (this allows e.g. 3D items to receive Idle events). }
  TCastleSceneManager = class(TCastleAbstractViewport)
  private
    FMainScene: TCastleScene;
    FItems: T3DList;
    FDefaultViewport: boolean;
    FViewports: TCastleAbstractViewportList;

    FOnCameraChanged: TNotifyEvent;
    FOnBoundViewpointChanged, FOnBoundNavigationInfoChanged: TNotifyEvent;
    FCameraBox: TBox3D;
    FShadowVolumeRenderer: TGLShadowVolumeRenderer;

    FMouseRayHit: TRayCollision;

    FMouseRayHit3D: T3D;

    { calculated by every PrepareResources }
    ChosenViewport: TCastleAbstractViewport;
    NeedsUpdateGeneratedTextures: boolean;

    { Call at the beginning of Draw (from both scene manager and custom viewport),
      to make sure UpdateGeneratedTextures was done before actual drawing. }
    procedure UpdateGeneratedTexturesIfNeeded;

    procedure SetMainScene(const Value: TCastleScene);
    procedure SetDefaultViewport(const Value: boolean);

    procedure ItemsVisibleChange(Sender: T3D; Changes: TVisibleChanges);

    { scene callbacks }
    procedure SceneBoundViewpointChanged(Scene: TCastleSceneCore);
    procedure SceneBoundViewpointVectorsChanged(Scene: TCastleSceneCore);
    procedure SceneBoundNavigationInfoChanged(Scene: TCastleSceneCore);

    procedure SetMouseRayHit3D(const Value: T3D);
    property MouseRayHit3D: T3D read FMouseRayHit3D write SetMouseRayHit3D;
  protected
    procedure SetCamera(const Value: TCamera); override;

    { Triangles to ignore by all collision detection in scene manager.
      The default implementation in this class resturns always @false,
      so nothing is ignored. You can override it e.g. to ignore your "water"
      material, when you want player to dive under the water. }
    function CollisionIgnoreItem(const Sender: TObject;
      const Triangle: P3DTriangle): boolean; virtual;

    procedure Notification(AComponent: TComponent; Operation: TOperation); override;

    function CameraMoveAllowed(ACamera: TWalkCamera;
      const ProposedNewPos: TVector3Single; out NewPos: TVector3Single;
      const BecauseOfGravity: boolean): boolean; override;
    procedure CameraGetHeight(ACamera: TWalkCamera;
      out IsAbove: boolean; out AboveHeight: Single;
      out AboveGround: P3DTriangle); override;
    procedure CameraVisibleChange(ACamera: TObject); override;

    function GetItems: T3D; override;
    function GetMainScene: TCastleScene; override;
    function GetShadowVolumeRenderer: TGLShadowVolumeRenderer; override;
    function GetMouseRayHit3D: T3D; override;
    function GetHeadlightCamera: TCamera; override;
    procedure PointingDeviceActivate(const Active: boolean); override;
    procedure PointingDeviceMove(const RayOrigin, RayDirection: TVector3Single); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    procedure GLContextOpen; override;
    procedure GLContextClose; override;
    function PositionInside(const X, Y: Integer): boolean; override;

    { Prepare resources, to make various methods (like @link(Draw))
      execute fast.

      If DisplayProgressTitle <> '', we will display progress bar during
      loading. This is especially useful for long precalculated animations
      (TCastlePrecalculatedAnimation with a lot of ScenesCount), they show nice
      linearly increasing progress bar. }
    procedure PrepareResources(const DisplayProgressTitle: string = '');

    procedure BeforeDraw; override;
    procedure Draw; override;

    { What changes happen when camera changes.
      You may want to use it when calling Scene.CameraChanged.

      Implementation in this class is correlated with RenderHeadlight. }
    function CameraToChanges: TVisibleChanges; virtual;

    procedure Idle(const CompSpeed: Single;
      const HandleMouseAndKeys: boolean;
      var LetOthersHandleMouseAndKeys: boolean); override;

    function CreateDefaultCamera(AOwner: TComponent): TCamera; override;

    { If non-empty, then camera position will be limited to this box.

      When this property specifies an EmptyBox3D (the default value),
      camera position is limited to not fall because of gravity
      outside of Items.BoundingBox. That is, camera can freely move
      around in 3D world, only the gravity cannot pull the user outside
      of the box.
      Which means user cannot fall into an infinite abyss of our 3D space,
      and also gravity doesn't work outside of Items.BoundingBox.
      This is usually most natural. }
    property CameraBox: TBox3D read FCameraBox write FCameraBox;

    { Renderer of shadow volumes. You can use this to optimize rendering
      of your shadow quads in RenderShadowVolume, and you can control
      it's statistics (TGLShadowVolumeRenderer.Count and related properties).

      This is internally initialized by scene manager. It's @nil when
      OpenGL context is not yet initialized (or scene manager is not
      added to @code(Controls) list yet). }
    property ShadowVolumeRenderer: TGLShadowVolumeRenderer
      read FShadowVolumeRenderer;

    { Current 3D objects under the mouse cursor.
      Updated in every mouse move. }
    property MouseRayHit: TRayCollision read FMouseRayHit;

    { List of viewports connected to this scene manager.
      This contains all TCastleViewport instances that have
      TCastleViewport.SceneManager set to us. Also it contains Self
      (this very scene manager) if and only if DefaultViewport = @true
      (because when DefaultViewport, scene manager acts as an
      additional viewport too).

      This list is read-only from the outside! It's automatically managed
      in this unit (when you change TCastleViewport.SceneManager
      or TCastleSceneManager.DefaultViewport, we automatically update this list
      as appropriate). }
    property Viewports: TCastleAbstractViewportList read FViewports;
  published
    { Tree of 3D objects within your world. This is the place where you should
      add your scenes to have them handled by scene manager.
      You may also set your main TCastleScene (if you have any) as MainScene.

      T3DList is also T3D instance, so yes --- this may be a tree
      of T3D, not only a flat list.

      Note that scene manager "hijacks" T3D callbacks T3D.OnCursorChange and
      T3D.OnVisibleChange. }
    property Items: T3DList read FItems;

    { The main scene of your 3D world. It's not necessary to set this
      (after all, your 3D world doesn't even need to have any TCastleScene
      instance). This @italic(must be) also added to our @link(Items)
      (otherwise things will work strangely).

      When set, this is used for a couple of things:

      @unorderedList(
        @item Decides what headlight is used (by TCastleScene.Headlight).

        @item(Decides what background is rendered.
          @italic(Notes for implementing descendants of this class:)
          You can change this by overriding Background method.)

        @item(Decides if, and where, the main light casting shadows is.
          @italic(Notes for implementing descendants of this class:)
          You can change this by overriding MainLightForShadows method.)

        @item Determines OpenGL projection for the scene, see ApplyProjection.

        @item(Synchronizes our @link(Camera) with VRML/X3D viewpoints
          and navigation info.
          This means that @link(Camera) will be updated when VRML/X3D events
          change current Viewpoint or NavigationInfo, for example
          you can animate the camera by animating the viewpoint
          (or it's transformation) or bind camera to a viewpoint.

          Note that scene manager "hijacks" some Scene events:
          TCastleSceneCore.OnBoundViewpointVectorsChanged,
          TCastleSceneCore.ViewpointStack.OnBoundChanged,
          TCastleSceneCore.NavigationInfoStack.OnBoundChanged
          for this purpose. If you want to know when viewpoint changes,
          you can use scene manager's event OnBoundViewpointChanged,
          OnBoundNavigationInfoChanged.)
      )

      The above stuff is only sensible when done once per scene manager,
      that's why we need MainScene property to indicate this.
      (We cannot just use every 3D object from @link(Items) for this.)

      Freeing MainScene will automatically set this to @nil. }
    property MainScene: TCastleScene read FMainScene write SetMainScene;

    { Called on any camera change. Exactly when TCamera generates it's
      OnVisibleChange event. }
    property OnCameraChanged: TNotifyEvent read FOnCameraChanged write FOnCameraChanged;

    { Called when bound Viewpoint node changes.
      Called exactly when TCastleSceneCore.ViewpointStack.OnBoundChanged is called. }
    property OnBoundViewpointChanged: TNotifyEvent read FOnBoundViewpointChanged write FOnBoundViewpointChanged;

    { Called when bound NavigationInfo changes (to a different node,
      or just a field changes). }
    property OnBoundNavigationInfoChanged: TNotifyEvent read FOnBoundNavigationInfoChanged write FOnBoundNavigationInfoChanged;

    { Should we render the 3D world in a default viewport that covers
      the whole window. This is usually what you want. For more complicated
      uses, you can turn this off, and use explicit TCastleViewport
      (connected to this scene manager by TCastleViewport.SceneManager property)
      for making your world visible. }
    property DefaultViewport: boolean
      read FDefaultViewport write SetDefaultViewport default true;

    property AlwaysApplyProjection default false;
  end;

  { Custom 2D viewport showing 3D world. This uses assigned SceneManager
    to show 3D world on the screen.

    For simple games, using this is not needed, because TCastleSceneManager
    also acts as a viewport (when TCastleSceneManager.DefaultViewport is @true,
    which is the default).
    Using custom viewports (implemented by this class)
    is useful when you want to have more than one viewport showing
    the same 3D world. Different viewports may have different cameras,
    but they always share the same 3D world (in scene manager).

    You can control the size of this viewport by FullSize, @link(Left),
    @link(Bottom), @link(Width), @link(Height) properties. For custom
    viewports, you often want to set FullSize = @false
    and control viewport's position and size explicitly.

    Example usages:
    in a typical 3D modeling programs, you like to have 4 viewports
    with 4 different cameras (front view, side view, top view,
    and free perspective view). See examples/vrml/multiple_viewports.lpr
    in engine sources for demo of this. Or when you make a split-screen game,
    played by 2 people on a single monitor.

    Viewports may be overlapping, that is one viewport may (partially)
    obscure another viewport. Just like with any other TUIControl,
    position of viewport on the Controls list
    (like TCastleControlCustom.Controls or TCastleWindowCustom.Controls)
    is important: Controls are specified in the front-to-back order.
    That is, if the viewport X may obscure viewport Y,
    then X must be before Y on the Controls list.

    Example usage of overlapping viewports:
    imagine a space shooter, like Epic or Wing Commander.
    You can imagine that a camera is mounted on each rocket fired
    by the player.
    You can display in one viewport (with FullSize = @true) normal
    (first person) view from your space ship.
    And additionally you can place a small viewport
    (with FullSize = @false and small @link(Width) / @link(Height))
    in the upper-right corner that displays view from last fired rocket. }
  TCastleViewport = class(TCastleAbstractViewport)
  private
    FSceneManager: TCastleSceneManager;
    procedure SetSceneManager(const Value: TCastleSceneManager);
  protected
    function GetItems: T3D; override;
    function GetMainScene: TCastleScene; override;
    function GetShadowVolumeRenderer: TGLShadowVolumeRenderer; override;
    function GetMouseRayHit3D: T3D; override;
    function GetHeadlightCamera: TCamera; override;
    procedure PointingDeviceActivate(const Active: boolean); override;
    procedure PointingDeviceMove(const RayOrigin, RayDirection: TVector3Single); override;

    function CameraMoveAllowed(ACamera: TWalkCamera;
      const ProposedNewPos: TVector3Single; out NewPos: TVector3Single;
      const BecauseOfGravity: boolean): boolean; override;
    procedure CameraGetHeight(ACamera: TWalkCamera;
      out IsAbove: boolean; out AboveHeight: Single;
      out AboveGround: P3DTriangle); override;
    procedure CameraVisibleChange(ACamera: TObject); override;
  public
    destructor Destroy; override;

    procedure Draw; override;

    function CreateDefaultCamera(AOwner: TComponent): TCamera; override;
  published
    property SceneManager: TCastleSceneManager read FSceneManager write SetSceneManager;
  end;

procedure Register;

implementation

uses SysUtils, RenderingCameraUnit, CastleGLUtils, ProgressUnit, RaysWindow, GLExt,
  CastleLog, CastleStringUtils, GLRenderer, ALSoundEngine;

procedure Register;
begin
  { For engine 3.0.0, TCastleSceneManager is not registered on palette,
    as the suggested usage for everyone is to take TCastleControl with
    scene manager instance already created.
    See castlecontrol.pas comments in Register. }
  { RegisterComponents('Castle', [TCastleSceneManager]); }
end;

{ TManagerRenderParams ------------------------------------------------------- }

constructor TManagerRenderParams.Create;
begin
  inherited;
  FBaseLights[false] := TLightInstancesList.Create;
  FBaseLights[true ] := TLightInstancesList.Create;
end;

destructor TManagerRenderParams.Destroy;
begin
  FreeAndNil(FBaseLights[false]);
  FreeAndNil(FBaseLights[true ]);
  inherited;
end;

function TManagerRenderParams.BaseLights(Scene: T3D): TAbstractLightInstancesList;
begin
  Result := FBaseLights[Scene = MainScene];
end;

{ TCastleAbstractViewport ------------------------------------------------------- }

constructor TCastleAbstractViewport.Create(AOwner: TComponent);
begin
  inherited;
  FFullSize := true;
  FAlwaysApplyProjection := true;
  FRenderParams := TManagerRenderParams.Create;

  FInput_PointingDeviceActivate := TInputShortcut.Create(K_None, K_None, #0, true, mbLeft);
  FOwnsInput_PointingDeviceActivate := true;
end;

destructor TCastleAbstractViewport.Destroy;
begin
  { unregister self from Camera callbacs, etc.

    This includes setting FCamera to nil.
    Yes, this setting FCamera to nil is needed, it's not just paranoia.

    Consider e.g. when our Camera is owned by Self
    (e.g. because it was created in ApplyProjection by CreateDefaultCamera).
    This means that this camera will be freed in "inherited" destructor call
    below. Since we just did FCamera.RemoveFreeNotification, we would have
    no way to set FCamera to nil, and FCamera would then remain as invalid
    pointer.

    And when SceneManager is freed it sends a free notification
    (this is also done in "inherited" destructor) to TCastleWindowCustom instance,
    which causes removing us from TCastleWindowCustom.Controls list,
    which causes SetContainer(nil) call that tries to access Camera.

    This scenario would cause segfault, as FCamera pointer is invalid
    at this time. }
  Camera := nil;

  FreeAndNil(FRenderParams);
  FreeAndNil(DefaultHeadlightNode);

  if FOwnsInput_PointingDeviceActivate then
    FreeAndNil(FInput_PointingDeviceActivate) else
    FInput_PointingDeviceActivate := nil;

  inherited;
end;

procedure TCastleAbstractViewport.SetCamera(const Value: TCamera);
begin
  if FCamera <> Value then
  begin
    { Check csDestroying, as this may be called from Notification,
      which may be called by camera destructor *after* TUniversalCamera
      after freed it's fields. }
    if (FCamera <> nil) and not (csDestroying in FCamera.ComponentState) then
    begin
      FCamera.OnVisibleChange := nil;
      FCamera.OnCursorChange := nil;
      if FCamera is TWalkCamera then
      begin
        TWalkCamera(FCamera).OnMoveAllowed := nil;
        TWalkCamera(FCamera).OnGetHeightAbove := nil;
      end else
      if FCamera is TUniversalCamera then
      begin
        TUniversalCamera(FCamera).Walk.OnMoveAllowed := nil;
        TUniversalCamera(FCamera).Walk.OnGetHeightAbove := nil;
      end;

      FCamera.RemoveFreeNotification(Self);
      FCamera.Container := nil;
    end;

    FCamera := Value;

    if FCamera <> nil then
    begin
      { Unconditionally change FCamera.OnVisibleChange callback,
        to override TCastleWindowCustom / TCastleControlCustom that also try
        to "hijack" this camera's event. }
      FCamera.OnVisibleChange := @CameraVisibleChange;
      FCamera.OnCursorChange := @ItemsAndCameraCursorChange;
      if FCamera is TWalkCamera then
      begin
        TWalkCamera(FCamera).OnMoveAllowed := @CameraMoveAllowed;
        TWalkCamera(FCamera).OnGetHeightAbove := @CameraGetHeight;
      end else
      if FCamera is TUniversalCamera then
      begin
        TUniversalCamera(FCamera).Walk.OnMoveAllowed := @CameraMoveAllowed;
        TUniversalCamera(FCamera).Walk.OnGetHeightAbove := @CameraGetHeight;
      end;

      FCamera.FreeNotification(Self);
      FCamera.Container := Container;
      if ContainerSizeKnown then
        FCamera.ContainerResize(ContainerWidth, ContainerHeight);
    end;

    ApplyProjectionNeeded := true;
  end;
end;

procedure TCastleAbstractViewport.SetContainer(const Value: IUIContainer);
begin
  inherited;

  { Keep Camera.Container always the same as our Container }
  if Camera <> nil then
    Camera.Container := Container;
end;

procedure TCastleAbstractViewport.Notification(AComponent: TComponent; Operation: TOperation);
begin
  inherited;

  if Operation = opRemove then
  begin
    if AComponent = FCamera then
    begin
      { set to nil by SetCamera, to clean nicely }
      Camera := nil;
      { Need ApplyProjection, to create new default camera before rendering. }
      ApplyProjectionNeeded := true;
    end;
  end;
end;

procedure TCastleAbstractViewport.ContainerResize(const AContainerWidth, AContainerHeight: Cardinal);
begin
  inherited;

  ApplyProjectionNeeded := true;

  if Camera <> nil then
    Camera.ContainerResize(AContainerWidth, AContainerHeight);
end;

procedure TCastleAbstractViewport.SetInput_PointingDeviceActivate(const Value: TInputShortcut);
begin
  if FInput_PointingDeviceActivate <> Value then
  begin
    { first, free the old one }
    if FOwnsInput_PointingDeviceActivate then
      FreeAndNil(FInput_PointingDeviceActivate);

    FInput_PointingDeviceActivate := Value;
    FOwnsInput_PointingDeviceActivate := false;
  end;
end;

function TCastleAbstractViewport.KeyDown(Key: TKey; C: char): boolean;
begin
  Result := inherited;
  if Result or Paused or (not GetExists) then Exit;

  if Camera <> nil then
  begin
    Result := Camera.KeyDown(Key, C);
    if Result then Exit;
  end;

  Result := GetItems.KeyDown(Key, C);

  if Input_PointingDeviceActivate.IsKey(Key, C) then
    PointingDeviceActivate(true);
end;

function TCastleAbstractViewport.KeyUp(Key: TKey; C: char): boolean;
begin
  Result := inherited;
  if Result or Paused or (not GetExists) then Exit;

  if Camera <> nil then
  begin
    Result := Camera.KeyUp(Key, C);
    if Result then Exit;
  end;

  Result := GetItems.KeyUp(Key, C);

  if Input_PointingDeviceActivate.IsKey(Key, C) then
    PointingDeviceActivate(false);
end;

function TCastleAbstractViewport.MouseDown(const Button: TMouseButton): boolean;
begin
  Result := inherited;
  if Result or Paused or (not GetExists) then Exit;

  if Camera <> nil then
  begin
    Result := Camera.MouseDown(Button);
    if Result then Exit;
  end;

  if Input_PointingDeviceActivate.IsMouseButton(Button) then
    PointingDeviceActivate(true);
end;

function TCastleAbstractViewport.MouseUp(const Button: TMouseButton): boolean;
begin
  Result := inherited;
  if Result or Paused or (not GetExists) then Exit;

  if Camera <> nil then
  begin
    Result := Camera.MouseUp(Button);
    if Result then Exit;
  end;

  if Input_PointingDeviceActivate.IsMouseButton(Button) then
    PointingDeviceActivate(false);
end;

function TCastleAbstractViewport.MouseMove(const OldX, OldY, NewX, NewY: Integer): boolean;
var
  RayOrigin, RayDirection: TVector3Single;
begin
  Result := inherited;
  if (not Result) and (not Paused) and GetExists and (Camera <> nil) then
  begin
    Result :=
      (not (Camera.PreventsComfortableDragging and GetItems.Dragging)) and
      Camera.MouseMove(OldX, OldY, NewX, NewY);
    if not Result then
    begin
      Camera.CustomRay(
        CorrectLeft, CorrectBottom, CorrectWidth, CorrectHeight, ContainerHeight,
        NewX, NewY, PerspectiveView, PerspectiveViewAngles, OrthoViewDimensions,
        RayOrigin, RayDirection);
      PointingDeviceMove(RayOrigin, RayDirection);
    end;
  end;

  { update the cursor, since 3D object under the cursor possibly changed.

    Accidentaly, this also workarounds the problem of TCastleViewport:
    when the 3D object stayed the same but it's Cursor value changed,
    Items.OnCursorChange notify only TCastleSceneManager (not custom viewport).
    But thanks to doing ItemsAndCameraCursorChange below, this isn't
    a problem for now, as we'll update cursor anyway, as long as it changes
    only during mouse move. }
  ItemsAndCameraCursorChange(Self);
end;

function TCastleAbstractViewport.MouseWheel(const Scroll: Single; const Vertical: boolean): boolean;
begin
  Result := inherited;
  if Result or Paused or (not GetExists) then Exit;

  if Camera <> nil then
  begin
    Result := Camera.MouseWheel(Scroll, Vertical);
    if Result then Exit;
  end;

  // Implement when needed: Result := GetItems.MouseWheel(Scroll, Vertical);
end;

procedure TCastleAbstractViewport.ItemsAndCameraCursorChange(Sender: TObject);
begin
  { We have to treat Camera.Cursor specially:
    - mcNone because of mouse look means result in unconditionally mcNone.
      Other Items.Cursor, MainScene.Cursor etc. is ignored then.
    - otherwise, Camera.Cursor is ignored, show 3D objects cursor. }
  if (Camera <> nil) and (Camera.Cursor = mcNone) then
  begin
    Cursor := mcNone;
    Exit;
  end;

  { We show mouse cursor from top-most 3D object.
    This is sensible, if multiple 3D scenes obscure each other at the same
    pixel --- the one "on the top" (visible by the player at that pixel)
    determines the mouse cursor. }

  if GetMouseRayHit3D <> nil then
  begin
    Cursor := GetMouseRayHit3D.Cursor;
  end else
    Cursor := mcDefault;
end;

procedure TCastleAbstractViewport.Idle(const CompSpeed: Single;
  const HandleMouseAndKeys: boolean;
  var LetOthersHandleMouseAndKeys: boolean);
begin
  inherited;

  if Paused or (not GetExists) then
  begin
    LetOthersHandleMouseAndKeys := true;
    Exit;
  end;

  { As for LetOthersHandleMouseAndKeys: let Camera decide it.
    By default, camera has ExclusiveEvents = false and will let
    LetOthersHandleMouseAndKeys remain = true, that's Ok.

    Our Items do not have HandleMouseAndKeys or LetOthersHandleMouseAndKeys
    stuff, as it would not be controllable for them: 3D objects do not
    have strict front-to-back order, so we would not know in what order
    call their Idle methods, so we have to let many Items handle keys anyway.
    So, it's consistent to just treat 3D objects as "cannot definitely
    mark keys/mouse as handled". Besides, currently 3D objects do not
    get Pressed information at all. }

  if Camera <> nil then
  begin
    LetOthersHandleMouseAndKeys := not Camera.ExclusiveEvents;
    Camera.Idle(CompSpeed, HandleMouseAndKeys, LetOthersHandleMouseAndKeys);
  end else
    LetOthersHandleMouseAndKeys := true;
end;

function TCastleAbstractViewport.AllowSuspendForInput: boolean;
begin
  Result := (Camera = nil) or Paused or (not GetExists) or Camera.AllowSuspendForInput;
end;

function TCastleAbstractViewport.CorrectLeft: Integer;
begin
  if FullSize then Result := 0 else Result := Left;
end;

function TCastleAbstractViewport.CorrectBottom: Integer;
begin
  if FullSize then Result := 0 else Result := Bottom;
end;

function TCastleAbstractViewport.CorrectWidth: Cardinal;
begin
  if FullSize then Result := ContainerWidth else Result := Width;
end;

function TCastleAbstractViewport.CorrectHeight: Cardinal;
begin
  if FullSize then Result := ContainerHeight else Result := Height;
end;

function TCastleAbstractViewport.PositionInside(const X, Y: Integer): boolean;
begin
  Result :=
    FullSize or
    ( (X >= Left) and
      (X  < Left + Width) and
      (ContainerHeight - Y >= Bottom) and
      (ContainerHeight - Y  < Bottom + Height) );
end;

procedure TCastleAbstractViewport.ApplyProjection;
var
  Box: TBox3D;

  procedure DefaultGLProjection;
  var
    ProjectionMatrix: TMatrix4f;
  begin
    FPerspectiveView := true;
    FPerspectiveViewAngles[1] := 45.0;
    FPerspectiveViewAngles[0] := AdjustViewAngleDegToAspectRatio(
      FPerspectiveViewAngles[1], CorrectWidth / CorrectHeight);

    glViewport(CorrectLeft, CorrectBottom, CorrectWidth, CorrectHeight);
    ProjectionGLPerspective(PerspectiveViewAngles[1], CorrectWidth / CorrectHeight,
      Box.AverageSize(false, 1.0) * 0.01,
      Box.MaxSize(false, 1.0) * 10.0);

    { update Camera.ProjectionMatrix }
    glGetFloatv(GL_PROJECTION_MATRIX, @ProjectionMatrix);
    Camera.ProjectionMatrix := ProjectionMatrix;
  end;

begin
  if Camera = nil then
    Camera := CreateDefaultCamera(Self);

  if AlwaysApplyProjection or ApplyProjectionNeeded then
  begin
    { We need to know container size now.
      This assertion can break only if you misuse UseControls property, setting it
      to false (disallowing ContainerResize), and then trying to use
      PrepareResources or Render (that call ApplyProjection). }
    Assert(ContainerSizeKnown, ClassName + ' did not receive ContainerResize event yet, cannnot apply OpenGL projection');

    Box := GetItems.BoundingBox;

    if GetMainScene <> nil then
      GetMainScene.GLProjection(Camera, Box,
        CorrectLeft, CorrectBottom, CorrectWidth, CorrectHeight, ShadowVolumesPossible,
        FPerspectiveView, FPerspectiveViewAngles, FOrthoViewDimensions,
        FProjectionNear, FProjectionFar) else
      DefaultGLProjection;

    ApplyProjectionNeeded := false;
  end;
end;

procedure TCastleAbstractViewport.SetShadowVolumesPossible(const Value: boolean);
begin
  if ShadowVolumesPossible <> Value then
  begin
    FShadowVolumesPossible := Value;
    ApplyProjectionNeeded := true;
  end;
end;

function TCastleAbstractViewport.Background: TBackground;
begin
  if GetMainScene <> nil then
    Result := GetMainScene.Background else
    Result := nil;
end;

function TCastleAbstractViewport.MainLightForShadows(
  out AMainLightPosition: TVector4Single): boolean;
begin
  if GetMainScene <> nil then
    Result := GetMainScene.MainLightForShadows(AMainLightPosition) else
    Result := false;
end;

procedure TCastleAbstractViewport.Render3D(const Params: TRenderParams);
begin
  GetItems.Render(RenderingCamera.Frustum, Params);
  if Assigned(OnRender3D) then
    OnRender3D(Self, Params);
end;

procedure TCastleAbstractViewport.RenderShadowVolume;
begin
  GetItems.RenderShadowVolume(GetShadowVolumeRenderer, true, IdentityMatrix4Single);
end;

function TCastleAbstractViewport.Headlight(out CustomHeadlight: TAbstractLightNode): boolean;
begin
  Result := (GetMainScene <> nil) and GetMainScene.HeadlightOn;
  if Result then
    CustomHeadlight := GetMainScene.CustomHeadlight else
    CustomHeadlight := nil;
end;

function TCastleAbstractViewport.HeadlightInstance(var Instance: TLightInstance): boolean;
var
  CustomHeadlight: TAbstractLightNode;
  HC: TCamera;

  procedure PrepareInstance;
  var
    Node: TAbstractLightNode;
    Position, Direction, Up: TVector3Single;
  begin
    { calculate Node, for Instance.Node }
    Node := CustomHeadlight;

    if Node = nil then
    begin
      if DefaultHeadlightNode = nil then
        { Nothing more needed, all DirectionalLight default properties
          are suitable for default headlight. }
        DefaultHeadlightNode := TDirectionalLightNode.Create('', '');;
      Node := DefaultHeadlightNode;
    end;

    Assert(Node <> nil);

    HC.GetView(Position, Direction, Up);

    { set location/direction of Node }
    if Node is TAbstractPositionalLightNode then
    begin
      TAbstractPositionalLightNode(Node).FdLocation.Send(Position);
      if Node is TSpotLightNode then
        TSpotLightNode(Node).FdDirection.Send(Direction) else
      if Node is TSpotLightNode_1 then
        TSpotLightNode_1(Node).FdDirection.Send(Direction);
    end else
    if Node is TAbstractDirectionalLightNode then
      TAbstractDirectionalLightNode(Node).FdDirection.Send(Direction);

    Instance.Node := Node;
    Instance.Location := Position;
    Instance.Direction := Direction;
    Instance.Transform := IdentityMatrix4Single;
    Instance.TransformScale := 1;
    Instance.Radius := MaxSingle;
    Instance.WorldCoordinates := true;
  end;

begin
  Result := false;
  if Headlight(CustomHeadlight) then
  begin
    if HeadlightFromViewport then
      HC := Camera else
      HC := GetHeadlightCamera;

    { GetHeadlightCamera (SceneManager.Camera) may be nil here, when
      rendering is done by a custom viewport and HeadlightFromViewport = false.
      So check HC <> nil.
      When nil we have to assume headlight doesn't shine.

      We don't want to use camera settings from current viewport
      (unless HeadlightFromViewport = true, which is a hack).
      This would mean that mirror textures (like GeneratedCubeMapTexture)
      will need to have different contents in different viewpoints,
      which isn't possible. We also want to use scene manager's camera,
      to have it tied with scene manager's CameraToChanges implementation.

      So if you use custom viewports and want headlight Ok,
      be sure to explicitly set TCastleSceneManager.Camera
      (probably, to one of your viewpoints' cameras).
      Or use a hacky HeadlightFromViewport. }

    if HC <> nil then
    begin
      PrepareInstance;
      Result := true;
    end;
  end;
end;

procedure TCastleAbstractViewport.InitializeLights(const Lights: TLightInstancesList);
var
  HI: TLightInstance;
begin
  if HeadlightInstance(HI) then
    Lights.Add(HI);
end;

function TCastleAbstractViewport.BaseLights: TLightInstancesList;
begin
  { We just reuse FRenderParams.FBaseLights[false] below as a temporary
    TLightInstancesList that we already have created. }
  Result := FRenderParams.FBaseLights[false];
  Result.Clear;
  InitializeLights(Result);
end;

procedure TCastleAbstractViewport.RenderFromView3D(const Params: TRenderParams);

  procedure RenderNoShadows;
  begin
    { We must first render all non-transparent objects,
      then all transparent objects. Otherwise transparent objects
      (that must be rendered without updating depth buffer) could get brutally
      covered by non-transparent objects (that are in fact further away from
      the camera). }

    Params.InShadow := false;

    Params.Transparent := false; Params.ShadowVolumesReceivers := false; Render3D(Params);
    Params.Transparent := false; Params.ShadowVolumesReceivers := true ; Render3D(Params);
    Params.Transparent := true ; Params.ShadowVolumesReceivers := false; Render3D(Params);
    Params.Transparent := true ; Params.ShadowVolumesReceivers := true ; Render3D(Params);
  end;

  procedure RenderWithShadows(const MainLightPosition: TVector4Single);
  begin
    GetShadowVolumeRenderer.InitFrustumAndLight(RenderingCamera.Frustum, MainLightPosition);
    GetShadowVolumeRenderer.Render(Params, @Render3D, @RenderShadowVolume, ShadowVolumesDraw);
  end;

var
  MainLightPosition: TVector4Single;
begin
  if ShadowVolumesPossible and
     ShadowVolumes and
     MainLightForShadows(MainLightPosition) then
    RenderWithShadows(MainLightPosition) else
    RenderNoShadows;
end;

procedure TCastleAbstractViewport.RenderFromViewEverything;
var
  ClearBuffers: TGLbitfield;
  UsedBackground: TBackground;
  MainLightPosition: TVector4Single; { ignored }
begin
  ClearBuffers := GL_DEPTH_BUFFER_BIT;

  if RenderingCamera.Target = rtVarianceShadowMap then
  begin
    { When rendering to VSM, we want to clear the screen to max depths (1, 1^2). }
    ClearBuffers := ClearBuffers or GL_COLOR_BUFFER_BIT;
    glPushAttrib(GL_COLOR_BUFFER_BIT);
    glClearColor(1.0, 1.0, 0.0, 1.0); // saved by GL_COLOR_BUFFER_BIT
  end else
  begin
    UsedBackground := Background;
    if UsedBackground <> nil then
    begin
      glLoadMatrix(RenderingCamera.RotationMatrix);

      { The background rendering doesn't like custom OrthoViewDimensions.
        They could make the background sky box very small, such that it
        doesn't fill the screen. See e.g. x3d/empty_with_background_ortho.x3dv
        testcase. So temporary set good perspective projection. }
      if not PerspectiveView then
      begin
        glMatrixMode(GL_PROJECTION);
        glPushMatrix;
        glLoadMatrix(PerspectiveProjMatrixDeg(45, CorrectWidth / CorrectHeight,
          ProjectionNear, ProjectionFar));
        glMatrixMode(GL_MODELVIEW);
      end;

      if BackgroundWireframe then
      begin
        { Color buffer needs clear *now*, before drawing background. }
        glClear(GL_COLOR_BUFFER_BIT);
        glPolygonMode(GL_FRONT_AND_BACK, GL_LINE);
        try
          UsedBackground.Render;
        finally glPolygonMode(GL_FRONT_AND_BACK, GL_FILL); end;
      end else
        UsedBackground.Render;

      if not PerspectiveView then
      begin
        glMatrixMode(GL_PROJECTION);
        glPopMatrix;
        glMatrixMode(GL_MODELVIEW);
      end;
    end else
      ClearBuffers := ClearBuffers or GL_COLOR_BUFFER_BIT;
  end;

  if ShadowVolumesPossible and
     ShadowVolumes and
     MainLightForShadows(MainLightPosition) then
    ClearBuffers := ClearBuffers or GL_STENCIL_BUFFER_BIT;

  glClear(ClearBuffers);

  if RenderingCamera.Target = rtVarianceShadowMap then
    glPopAttrib;

  glLoadMatrix(RenderingCamera.Matrix);

  { clear FRenderParams instance }

  FRenderParams.Pass := 0;

  FillChar(FRenderParams.Statistics, SizeOf(FRenderParams.Statistics), #0);

  FRenderParams.FBaseLights[false].Clear;
  InitializeLights(FRenderParams.FBaseLights[false]);
  if UseGlobalLights and
     (GetMainScene <> nil) and
     (GetMainScene.GlobalLights.Count <> 0) then
  begin
    FRenderParams.MainScene := GetMainScene;
    FRenderParams.FBaseLights[true].Assign(FRenderParams.FBaseLights[false]);
    FRenderParams.FBaseLights[false].AppendInWorldCoordinates(GetMainScene.GlobalLights);
  end else
    { Do not use Params.FBaseLights[true] }
    FRenderParams.MainScene := nil;

  RenderFromView3D(FRenderParams);
end;

procedure RenderScreenEffect(ViewportPtr: Pointer);
var
  Viewport: TCastleAbstractViewport absolute ViewportPtr;

  procedure RenderOneEffect(Shader: TGLSLProgram);
  var
    BoundTextureUnits: Cardinal;
  begin
    with Viewport do
    begin
      glActiveTexture(GL_TEXTURE0); // GLUseMultiTexturing is already checked
      glBindTexture(GL_TEXTURE_RECTANGLE_ARB, ScreenEffectTextureSrc);
      BoundTextureUnits := 1;

      if CurrentScreenEffectsNeedDepth then
      begin
        glActiveTexture(GL_TEXTURE1);
        glBindTexture(GL_TEXTURE_RECTANGLE_ARB, ScreenEffectTextureDepth);
        Inc(BoundTextureUnits);
      end;

      glLoadIdentity();
      { Although shaders will typically ignore glColor, for consistency
        we want to have a fully determined state. That is, this must work
        reliably even if you comment out ScreenEffects[*].Enable/Disable
        commands below. }
      glColor3f(1, 1, 1);
      Shader.Enable;
        Shader.SetUniform('screen', 0);
        if CurrentScreenEffectsNeedDepth then
          Shader.SetUniform('screen_depth', 1);
        Shader.SetUniform('screen_width', TGLint(ScreenEffectTextureWidth));
        Shader.SetUniform('screen_height', TGLint(ScreenEffectTextureHeight));

        { Note that we ignore SetupUniforms result --- if some texture
          could not be bound, it will be undefined for shader.
          I don't see anything much better to do now. }
        Shader.SetupUniforms(BoundTextureUnits);

        { Note that there's no need to worry about CorrectLeft / CorrectBottom,
          here or inside RenderScreenEffect, because we're already within
          glViewport that takes care of this. }

        glBegin(GL_QUADS);
          glTexCoord2i(0, 0);
          glVertex2i(0, 0);
          glTexCoord2i(ScreenEffectTextureWidth, 0);
          glVertex2i(CorrectWidth, 0);
          glTexCoord2i(ScreenEffectTextureWidth, ScreenEffectTextureHeight);
          glVertex2i(CorrectWidth, CorrectHeight);
          glTexCoord2i(0, ScreenEffectTextureHeight);
          glVertex2i(0, CorrectHeight);
        glEnd();
      Shader.Disable;
    end;
  end;

var
  I: Integer;
begin
  with Viewport do
  begin
    { Render all except the last screen effects: from texture
      (ScreenEffectTextureDest/Src) and to texture (using ScreenEffectRTT) }
    for I := 0 to CurrentScreenEffectsCount - 2 do
    begin
      ScreenEffectRTT.RenderBegin;
      ScreenEffectRTT.SetTexture(ScreenEffectTextureDest, GL_TEXTURE_RECTANGLE_ARB);
      RenderOneEffect(ScreenEffects[I]);
      ScreenEffectRTT.RenderEnd;

      SwapValues(ScreenEffectTextureDest, ScreenEffectTextureSrc);
    end;

    { Restore glViewport set by ApplyProjection }
    if not FullSize then
      glViewport(CorrectLeft, CorrectBottom, CorrectWidth, CorrectHeight);

    { the last effect gets a texture, and renders straight into screen }
    RenderOneEffect(ScreenEffects[CurrentScreenEffectsCount - 1]);
  end;
end;

procedure TCastleAbstractViewport.RenderOnScreen(ACamera: TCamera);

  { Create and setup new OpenGL texture rectangle for screen effects.
    Depends on ScreenEffectTextureWidth, ScreenEffectTextureHeight being set. }
  function CreateScreenEffectTexture(const Depth: boolean): TGLuint;
  begin
    { create new texture rectangle. }
    glGenTextures(1, @Result);
    glBindTexture(GL_TEXTURE_RECTANGLE_ARB, Result);
    { TODO: or GL_LINEAR? Allow to config this and eventually change
      before each screen effect? }
    glTexParameteri(GL_TEXTURE_RECTANGLE_ARB, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_RECTANGLE_ARB, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_RECTANGLE_ARB, GL_TEXTURE_WRAP_S, CastleGL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_RECTANGLE_ARB, GL_TEXTURE_WRAP_T, CastleGL_CLAMP_TO_EDGE);
    { We never load image contents, so we also do not have to care about
      pixel packing. }
    if Depth then
    begin
      glTexImage2D(GL_TEXTURE_RECTANGLE_ARB, 0, GL_DEPTH_COMPONENT,
        ScreenEffectTextureWidth,
        ScreenEffectTextureHeight, 0, GL_DEPTH_COMPONENT, GL_UNSIGNED_BYTE, nil);
      //glTexParameteri(GL_TEXTURE_RECTANGLE_ARB, GL_TEXTURE_COMPARE_MODE_ARB, GL_NONE);
      //glTexParameteri(GL_TEXTURE_RECTANGLE_ARB, GL_DEPTH_TEXTURE_MODE_ARB, GL_LUMINANCE);
    end else
      glTexImage2D(GL_TEXTURE_RECTANGLE_ARB, 0, GL_RGB8,
        ScreenEffectTextureWidth,
        ScreenEffectTextureHeight, 0, GL_RGB, GL_UNSIGNED_BYTE, nil);
  end;

begin
  RenderingCamera.Target := rtScreen;
  RenderingCamera.FromCameraObject(ACamera);

  { save ScreenEffectsCount/NeedDepth result, to not recalculate it,
    and also to make the following code stable --- this way we know
    CurrentScreenEffects* values are constant, even if overridden
    ScreenEffects* methods do something weird. }
  CurrentScreenEffectsCount := ScreenEffectsCount;

  if GL_ARB_texture_rectangle and GLUseMultiTexturing and
    (CurrentScreenEffectsCount <> 0) then
  begin
    CurrentScreenEffectsNeedDepth := ScreenEffectsNeedDepth;

    { We need a temporary texture rectangle, for screen effect. }
    if (ScreenEffectTextureDest = 0) or
       (ScreenEffectTextureSrc = 0) or
       (CurrentScreenEffectsNeedDepth and (ScreenEffectTextureDepth = 0)) or
       (ScreenEffectRTT = nil) or
       (ScreenEffectTextureWidth  <> CorrectWidth ) or
       (ScreenEffectTextureHeight <> CorrectHeight) then
    begin
      glFreeTexture(ScreenEffectTextureDest);
      glFreeTexture(ScreenEffectTextureSrc);
      glFreeTexture(ScreenEffectTextureDepth);
      FreeAndNil(ScreenEffectRTT);

      ScreenEffectTextureWidth := CorrectWidth;
      ScreenEffectTextureHeight := CorrectHeight;
      { We use two textures: ScreenEffectTextureDest is the destination
        of framebuffer, ScreenEffectTextureSrc is the source to render.

        Although for some effects one texture (both src and dest) is enough.
        But when you have > 1 effect and one of the effects has non-local
        operations (they read color values that can be modified by operations
        of the same shader, so it's undefined (depends on how shaders are
        executed in parallel) which one is first) then the artifacts are
        visible. For example, use view3dscene "Edge Detect" effect +
        any other effect. }
      ScreenEffectTextureDest := CreateScreenEffectTexture(false);
      ScreenEffectTextureSrc := CreateScreenEffectTexture(false);
      if CurrentScreenEffectsNeedDepth then
        ScreenEffectTextureDepth := CreateScreenEffectTexture(true);

      { create new TGLRenderToTexture (usually, framebuffer object) }
      ScreenEffectRTT := TGLRenderToTexture.Create(
        ScreenEffectTextureWidth, ScreenEffectTextureHeight);
      ScreenEffectRTT.SetTexture(ScreenEffectTextureDest, GL_TEXTURE_RECTANGLE_ARB);
      ScreenEffectRTT.CompleteTextureTarget := GL_TEXTURE_RECTANGLE_ARB;
      if CurrentScreenEffectsNeedDepth then
      begin
        ScreenEffectRTT.Buffer := tbColorAndDepth;
        ScreenEffectRTT.DepthTexture := ScreenEffectTextureDepth;
        ScreenEffectRTT.DepthTextureTarget := GL_TEXTURE_RECTANGLE_ARB;
      end else
        ScreenEffectRTT.Buffer := tbColor;
      { TODO: using stencil buffer with depth texture doesn't work
        on GPUs with packed depth_stencil (most GPUs...).
        Any way to make it working? }
      ScreenEffectRTT.Stencil := not CurrentScreenEffectsNeedDepth;
      ScreenEffectRTT.GLContextOpen;

      if Log then
        WritelnLog('Screen effects', Format('Created texture rectangle for screen effects, with size %d x %d, with depth texture: %s',
          [ ScreenEffectTextureWidth,
            ScreenEffectTextureHeight,
            BoolToStr[CurrentScreenEffectsNeedDepth] ]));
    end;

    { We have to adjust glViewport.
      It will be restored from RenderScreenEffect right before actually
      rendering to screen.  }
    if not FullSize then
      glViewport(0, 0, CorrectWidth, CorrectHeight);

    ScreenEffectRTT.RenderBegin;
    ScreenEffectRTT.SetTexture(ScreenEffectTextureDest, GL_TEXTURE_RECTANGLE_ARB);
    RenderFromViewEverything;
    ScreenEffectRTT.RenderEnd;

    SwapValues(ScreenEffectTextureDest, ScreenEffectTextureSrc);

    glPushAttrib(GL_ENABLE_BIT);
      glDisable(GL_LIGHTING);
      glDisable(GL_DEPTH_TEST);

      glActiveTexture(GL_TEXTURE0);
      glDisable(GL_TEXTURE_2D);
      glEnable(GL_TEXTURE_RECTANGLE_ARB);

      if CurrentScreenEffectsNeedDepth then
      begin
        glActiveTexture(GL_TEXTURE1);
        glDisable(GL_TEXTURE_2D);
        glEnable(GL_TEXTURE_RECTANGLE_ARB);
      end;

      glProjectionPushPopOrtho2D(@RenderScreenEffect, Self, 0, CorrectWidth, 0, CorrectHeight);

      if CurrentScreenEffectsNeedDepth then
      begin
        glActiveTexture(GL_TEXTURE1);
        glDisable(GL_TEXTURE_RECTANGLE_ARB); // TODO: should be done by glPopAttrib, right? enable_bit contains it?
      end;

      glActiveTexture(GL_TEXTURE0);
      glDisable(GL_TEXTURE_RECTANGLE_ARB); // TODO: should be done by glPopAttrib, right? enable_bit contains it?

      { at the end, we left active texture as default GL_TEXTURE0 }
    glPopAttrib;
  end else
  begin
    { Rendering directly to the screen, when no screen effects are used. }
    if not FullSize then
    begin
      glPushAttrib(GL_SCISSOR_BIT);
        { Use Scissor to limit what glClear clears. }
        glScissor(Left, Bottom, Width, Height); // saved by GL_SCISSOR_BIT
        glEnable(GL_SCISSOR_TEST); // saved by GL_SCISSOR_BIT
    end;

    RenderFromViewEverything;

    if not FullSize then
      glPopAttrib;
  end;
end;

function TCastleAbstractViewport.DrawStyle: TUIControlDrawStyle;
begin
  Result := ds3D;
end;

function TCastleAbstractViewport.GetScreenEffects(const Index: Integer): TGLSLProgram;
begin
  if GetMainScene <> nil then
    Result := GetMainScene.ScreenEffects(Index) else
    { no Index is valid, since ScreenEffectsCount = 0 in this class }
    Result := nil;
end;

function TCastleAbstractViewport.ScreenEffectsCount: Integer;
begin
  if GetMainScene <> nil then
    Result := GetMainScene.ScreenEffectsCount else
    Result := 0;
end;

function TCastleAbstractViewport.ScreenEffectsNeedDepth: boolean;
begin
  if GetMainScene <> nil then
    Result := GetMainScene.ScreenEffectsNeedDepth else
    Result := false;
end;

procedure TCastleAbstractViewport.GLContextClose;
begin
  glFreeTexture(ScreenEffectTextureDest);
  glFreeTexture(ScreenEffectTextureSrc);
  glFreeTexture(ScreenEffectTextureDepth);
  FreeAndNil(ScreenEffectRTT);
  inherited;
end;

procedure TCastleAbstractViewport.CameraAnimateToDefault(const Time: TFloatTime);
var
  DefCamera: TCamera;
begin
  if Camera = nil then
    Camera := CreateDefaultCamera(nil) else
  begin
    DefCamera := CreateDefaultCamera(nil);
    try
      Camera.AnimateTo(DefCamera, Time);
    finally FreeAndNil(DefCamera) end;
  end;
end;

function TCastleAbstractViewport.CreateDefaultCamera: TCamera;
begin
  Result := CreateDefaultCamera(Self);
end;

function TCastleAbstractViewport.Statistics: TRenderStatistics;
begin
  Result := FRenderParams.Statistics;
end;

{ TCastleAbstractViewportList -------------------------------------------------- }

function TCastleAbstractViewportList.UsesShadowVolumes: boolean;
var
  I: Integer;
  MainLightPosition: TVector4Single; { ignored }
  V: TCastleAbstractViewport;
begin
  for I := 0 to Count - 1 do
  begin
    V := Items[I];
    if V.ShadowVolumesPossible and
       V.ShadowVolumes and
       V.MainLightForShadows(MainLightPosition) then
      Exit(true);
  end;
  Result := false;
end;

{ TCastleSceneManager ----------------------------------------------------------- }

constructor TCastleSceneManager.Create(AOwner: TComponent);
begin
  inherited;

  FItems := T3DList.Create(Self);
  FItems.OnVisibleChangeHere := @ItemsVisibleChange;
  FItems.OnCursorChange := @ItemsAndCameraCursorChange;
  { Items is displayed and streamed with TCastleSceneManager
    (and in the future this should allow design Items.List by IDE),
    so make it a correct sub-component. }
  FItems.SetSubComponent(true);
  FItems.Name := 'Items';

  FCameraBox := EmptyBox3D;

  FDefaultViewport := true;
  FAlwaysApplyProjection := false;

  FViewports := TCastleAbstractViewportList.Create(false);
  if DefaultViewport then FViewports.Add(Self);
end;

destructor TCastleSceneManager.Destroy;
var
  I: Integer;
begin
  FreeAndNil(FMouseRayHit);

  { unregister self from MainScene callbacs,
    make MainScene.RemoveFreeNotification(Self)... this is all
    done by SetMainScene(nil) already. }
  MainScene := nil;

  { unregister free notification from MouseRayHit3D }
  MouseRayHit3D := nil;

  if FViewports <> nil then
  begin
    for I := 0 to FViewports.Count - 1 do
      if FViewports[I] is TCastleViewport then
      begin
        Assert(TCastleViewport(FViewports[I]).SceneManager = Self);
        { Set SceneManager by direct field (FSceneManager),
          otherwise TCastleViewport.SetSceneManager would try to update
          our Viewports list, that we iterate over right now... }
        TCastleViewport(FViewports[I]).FSceneManager := nil;
      end;
    FreeAndNil(FViewports);
  end;

  inherited;
end;

procedure TCastleSceneManager.ItemsVisibleChange(Sender: T3D; Changes: TVisibleChanges);
begin
  { pass visible change notification "upward" (as a TUIControl, to container) }
  VisibleChange;
  { pass visible change notification "downward", to all children T3D }
  Items.VisibleChangeNotification(Changes);
end;

procedure TCastleSceneManager.GLContextOpen;
begin
  inherited;

  { We actually need to do it only if ShadowVolumesPossible for any viewport.
    But we can as well do it always, it's harmless (just checks some GL
    extensions). (Otherwise we'd have to handle SetShadowVolumesPossible.) }
  if ShadowVolumeRenderer = nil then
  begin
    FShadowVolumeRenderer := TGLShadowVolumeRenderer.Create;
    ShadowVolumeRenderer.GLContextOpen;
  end;
end;

procedure TCastleSceneManager.GLContextClose;
begin
  Items.GLContextClose;

  FreeAndNil(FShadowVolumeRenderer);

  inherited;
end;

function TCastleSceneManager.CreateDefaultCamera(AOwner: TComponent): TCamera;
var
  Box: TBox3D;
begin
  Box := Items.BoundingBox;
  if MainScene <> nil then
    Result := MainScene.CreateCamera(AOwner, Box) else
  begin
    Result := TExamineCamera.Create(AOwner);
    (Result as TExamineCamera).Init(Box,
      { CameraRadius = } Box.AverageSize(false, 1.0) * 0.005);
  end;
end;

procedure TCastleSceneManager.SetMainScene(const Value: TCastleScene);
begin
  if FMainScene <> Value then
  begin
    if FMainScene <> nil then
    begin
      { When FMainScene = FMouseRayHit3D, leave free notification for FMouseRayHit3D }
      if FMainScene <> FMouseRayHit3D then
        FMainScene.RemoveFreeNotification(Self);
      FMainScene.OnBoundViewpointVectorsChanged := nil;
      FMainScene.OnBoundNavigationInfoFieldsChanged := nil;
      { this SetMainScene may happen from MainScene destruction notification,
        when *Stack is already freed. }
      if FMainScene.ViewpointStack <> nil then
        FMainScene.ViewpointStack.OnBoundChanged := nil;
      if FMainScene.NavigationInfoStack <> nil then
        FMainScene.NavigationInfoStack.OnBoundChanged := nil;
    end;

    FMainScene := Value;

    if FMainScene <> nil then
    begin
      FMainScene.FreeNotification(Self);
      FMainScene.OnBoundViewpointVectorsChanged := @SceneBoundViewpointVectorsChanged;
      FMainScene.OnBoundNavigationInfoFieldsChanged := @SceneBoundNavigationInfoChanged;
      FMainScene.ViewpointStack.OnBoundChanged := @SceneBoundViewpointChanged;
      FMainScene.NavigationInfoStack.OnBoundChanged := @SceneBoundNavigationInfoChanged;

      { Call initial CameraChanged (this allows ProximitySensors to work
        as soon as ProcessEvents becomes true). }
      if Camera <> nil then
        MainScene.CameraChanged(Camera, CameraToChanges);
    end;

    ApplyProjectionNeeded := true;
  end;
end;

procedure TCastleSceneManager.SetMouseRayHit3D(const Value: T3D);
begin
  if FMouseRayHit3D <> Value then
  begin
    { Always keep FreeNotification on FMouseRayHit3D.
      When it's destroyed, our FMouseRayHit3D must be freed too,
      it cannot be used in subsequent ItemsAndCameraCursorChange. }

    if FMouseRayHit3D <> nil then
    begin
      { When FMainScene = FMouseRayHit3D, leave free notification for FMouseRayHit3D }
      if FMainScene <> FMouseRayHit3D then
        FMouseRayHit3D.RemoveFreeNotification(Self);
    end;

    FMouseRayHit3D := Value;

    if FMouseRayHit3D <> nil then
      FMouseRayHit3D.FreeNotification(Self);
  end;
end;

procedure TCastleSceneManager.SetCamera(const Value: TCamera);
begin
  if FCamera <> Value then
  begin
    inherited;

    if FCamera <> nil then
    begin
      { Call initial CameraChanged (this allows ProximitySensors to work
        as soon as ProcessEvents becomes true). }
      if MainScene <> nil then
        MainScene.CameraChanged(Camera, CameraToChanges);
    end;

    { Changing camera changes also the view rapidly. }
    if MainScene <> nil then
      MainScene.ViewChangedSuddenly;
  end else
    inherited; { not really needed for now, but for safety --- always call inherited }
end;

procedure TCastleSceneManager.Notification(AComponent: TComponent; Operation: TOperation);
begin
  inherited;

  if Operation = opRemove then
  begin
    { set to nil by methods (like SetMainScene), to clean nicely }
    if AComponent = FMainScene then
      MainScene := nil;

    if AComponent = FMouseRayHit3D then
    begin
      MouseRayHit3D := nil;
      { When FMouseRayHit3D is destroyed, our MouseRayHit must be freed too,
        it cannot be used in subsequent ItemsAndCameraCursorChange. }
      FreeAndNil(FMouseRayHit);
    end;

    { Maybe ApplyProjectionNeeded := true also for MainScene cleaning?
      But ApplyProjection doesn't set projection now, when MainScene is @nil. }
  end;
end;

function TCastleSceneManager.PositionInside(const X, Y: Integer): boolean;
begin
  { When not DefaultViewport, then scene manager is not visible. }
  Result := DefaultViewport and (inherited PositionInside(X, Y));
end;

procedure TCastleSceneManager.PrepareResources(const DisplayProgressTitle: string);
var
  Options: TPrepareResourcesOptions;
begin
  ChosenViewport := nil;
  NeedsUpdateGeneratedTextures := false;

  { This preparation is done only once, before rendering all viewports.
    No point in doing this when no viewport is configured.
    Also, we'll need to use one of viewport's projection here. }
  if Viewports.Count <> 0 then
  begin
    Options := [prRender, prBackground, prBoundingBox, prScreenEffects];

    if Viewports.UsesShadowVolumes then
      Options := Options + prShadowVolume;

    { We need one viewport, to setup it's projection and to setup it's camera.
      There really no perfect choice, although in practice any viewport
      should do just fine. For now: use the 1st one on the list.
      Maybe in the future we'll need more intelligent method of choosing. }
    ChosenViewport := Viewports[0];

    { Apply projection now, as TCastleScene.GLProjection calculates
      BackgroundSkySphereRadius, which is used by MainScene.Background.
      Otherwise our preparations of "prBackground" here would be useless,
      as BackgroundSkySphereRadius will change later, and MainScene.Background
      will have to be recreated. }
    ChosenViewport.ApplyProjection;

    { RenderingCamera properties must be already set,
      since PrepareResources may do some operations on texture gen modes
      in WORLDSPACE*. }
    RenderingCamera.FromCameraObject(ChosenViewport.Camera);

    if DisplayProgressTitle <> '' then
    begin
      Progress.Init(Items.PrepareResourcesSteps, DisplayProgressTitle, true);
      try
        Items.PrepareResources(Options, true, BaseLights);
      finally Progress.Fini end;
    end else
      Items.PrepareResources(Options, false, BaseLights);

    NeedsUpdateGeneratedTextures := true;
  end;
end;

procedure TCastleSceneManager.BeforeDraw;
begin
  inherited;
  if not GetExists then Exit;
  PrepareResources;
end;

function TCastleSceneManager.CameraToChanges: TVisibleChanges;
begin
  if (MainScene <> nil) and MainScene.HeadlightOn then
    Result := [vcVisibleNonGeometry] else
    Result := [];
end;

procedure TCastleSceneManager.UpdateGeneratedTexturesIfNeeded;
begin
  if NeedsUpdateGeneratedTextures then
  begin
    NeedsUpdateGeneratedTextures := false;

    { We depend here that right before Draw, BeforeDraw was called.
      We depend on BeforeDraw (actually PrepareResources) to set
      ChosenViewport and make ChosenViewport.ApplyProjection.

      This way below we can use sensible projection near/far calculated
      by previous ChosenViewport.ApplyProjection,
      and restore viewport used by previous ChosenViewport.ApplyProjection.

      This could be moved to PrepareResources without problems, but we want
      time needed to render textures be summed into "FPS frame time". }
    Items.UpdateGeneratedTextures(@RenderFromViewEverything,
      ChosenViewport.ProjectionNear,
      ChosenViewport.ProjectionFar,
      ChosenViewport.CorrectLeft,
      ChosenViewport.CorrectBottom,
      ChosenViewport.CorrectWidth,
      ChosenViewport.CorrectHeight);
  end;
end;

procedure TCastleSceneManager.Draw;
begin
  if not GetExists then Exit;

  UpdateGeneratedTexturesIfNeeded;

  inherited;
  if not DefaultViewport then Exit;
  ApplyProjection;
  RenderOnScreen(Camera);
end;

procedure TCastleSceneManager.PointingDeviceActivate(const Active: boolean);
var
  PassToMainScene: boolean;

  function PassTo(const Node: TRayCollisionNode): boolean;
  begin
    Result := Node.Item.PointingDeviceActivate(Active);
    if Result or (Node.Item = MainScene) then
      PassToMainScene := false;
  end;

var
  I: Integer;
begin
  PassToMainScene := true;
  if MouseRayHit <> nil then
    for I := 0 to MouseRayHit.Count - 1 do
      if PassTo(MouseRayHit[I]) then Break;
  if PassToMainScene and (MainScene <> nil) then
    MainScene.PointingDeviceActivate(Active);
end;

procedure TCastleSceneManager.PointingDeviceMove(const RayOrigin, RayDirection: TVector3Single);
var
  PassToMainScene: boolean;

  function PassTo(const Node: TRayCollisionNode): boolean;
  begin
    Result := Node.Item.PointingDeviceMove(Node.RayOrigin, Node.RayDirection, Node.Point, Node.Triangle);
    if Result or (Node.Item = MainScene) then
      PassToMainScene := false;
  end;

var
  I: Integer;
begin
  { update FMouseRayHit }
  FreeAndNil(FMouseRayHit);
  FMouseRayHit := Items.RayCollision(RayOrigin, RayDirection,
    { Do not use CollisionIgnoreItem here,
      as this is not camera<->3d world collision? } nil);

  { calculate MouseRayHit3D }
  if MouseRayHit <> nil then
    MouseRayHit3D := MouseRayHit.First.Item else
    MouseRayHit3D := nil;

  PassToMainScene := true;
  if MouseRayHit <> nil then
    for I := 0 to MouseRayHit.Count - 1 do
      if PassTo(MouseRayHit[I]) then Break;
  if PassToMainScene and (MainScene <> nil) then
    MainScene.PointingDeviceMove(RayOrigin, RayDirection, ZeroVector3Single, nil);
end;

procedure TCastleSceneManager.Idle(const CompSpeed: Single;
  const HandleMouseAndKeys: boolean;
  var LetOthersHandleMouseAndKeys: boolean);
begin
  inherited;

  if (not Paused) and GetExists then
    Items.Idle(CompSpeed);
end;

procedure TCastleSceneManager.CameraVisibleChange(ACamera: TObject);
begin
  if (MainScene <> nil) and (ACamera = Camera) then
    { MainScene.CameraChanged will cause MainScene.[On]VisibleChangeHere,
      that (assuming here that MainScene is also on Items) will cause
      ItemsVisibleChange that will cause our own VisibleChange.
      So this way MainScene.CameraChanged will also cause our VisibleChange. }
    MainScene.CameraChanged(Camera, CameraToChanges) else
    VisibleChange;

  SoundEngine.UpdateListener(ACamera as TCamera);

  if Assigned(OnCameraChanged) then
    OnCameraChanged(ACamera);
end;

function TCastleSceneManager.CollisionIgnoreItem(const Sender: TObject;
  const Triangle: P3DTriangle): boolean;
begin
  Result := false;
end;

function TCastleSceneManager.CameraMoveAllowed(ACamera: TWalkCamera;
  const ProposedNewPos: TVector3Single; out NewPos: TVector3Single;
  const BecauseOfGravity: boolean): boolean;
begin
  Result := Items.MoveAllowed(ACamera.Position, ProposedNewPos, NewPos,
    ACamera.CameraRadius, @CollisionIgnoreItem);

  if Result then
  begin
    if FCameraBox.IsEmpty then
    begin
      { Don't let user to fall outside of the box because of gravity. }
      if BecauseOfGravity then
        Result := Items.BoundingBox.PointInside(NewPos);
    end else
      Result := FCameraBox.PointInside(NewPos);
  end;
end;

procedure TCastleSceneManager.CameraGetHeight(ACamera: TWalkCamera;
  out IsAbove: boolean; out AboveHeight: Single;
  out AboveGround: P3DTriangle);
begin
  Items.GetHeightAbove(ACamera.Position, ACamera.GravityUp,
    @CollisionIgnoreItem,
    IsAbove, AboveHeight, AboveGround);
end;

procedure TCastleSceneManager.SceneBoundViewpointChanged(Scene: TCastleSceneCore);
begin
  if Camera <> nil then
    Scene.CameraFromViewpoint(Camera, false);

  { bound Viewpoint.fieldOfView changed, so update projection }
  ApplyProjectionNeeded := true;

  if Assigned(OnBoundViewpointChanged) then
    OnBoundViewpointChanged(Self);
end;

procedure TCastleSceneManager.SceneBoundNavigationInfoChanged(Scene: TCastleSceneCore);
begin
  if Camera <> nil then
    Scene.CameraFromNavigationInfo(Camera, Items.BoundingBox);

  if Assigned(OnBoundNavigationInfoChanged) then
    OnBoundNavigationInfoChanged(Self);
end;

procedure TCastleSceneManager.SceneBoundViewpointVectorsChanged(Scene: TCastleSceneCore);
begin
  if Camera <> nil then
    Scene.CameraFromViewpoint(Camera, true);
end;

function TCastleSceneManager.GetItems: T3D;
begin
  Result := Items;
end;

function TCastleSceneManager.GetMainScene: TCastleScene;
begin
  Result := MainScene;
end;

function TCastleSceneManager.GetShadowVolumeRenderer: TGLShadowVolumeRenderer;
begin
  Result := ShadowVolumeRenderer;
end;

function TCastleSceneManager.GetMouseRayHit3D: T3D;
begin
  Result := MouseRayHit3D;
end;

function TCastleSceneManager.GetHeadlightCamera: TCamera;
begin
  Result := Camera;
end;

procedure TCastleSceneManager.SetDefaultViewport(const Value: boolean);
begin
  if Value <> FDefaultViewport then
  begin
    FDefaultViewport := Value;
    if DefaultViewport then
      Viewports.Add(Self) else
      Viewports.Remove(Self);
  end;
end;

{ TCastleViewport --------------------------------------------------------------- }

destructor TCastleViewport.Destroy;
begin
  SceneManager := nil; { remove Self from SceneManager.Viewports }
  inherited;
end;

procedure TCastleViewport.CameraVisibleChange(ACamera: TObject);
begin
  VisibleChange;
end;

function TCastleViewport.CameraMoveAllowed(ACamera: TWalkCamera;
  const ProposedNewPos: TVector3Single; out NewPos: TVector3Single;
  const BecauseOfGravity: boolean): boolean;
begin
  if SceneManager <> nil then
    Result := SceneManager.CameraMoveAllowed(
      ACamera, ProposedNewPos, NewPos, BecauseOfGravity) else
  begin
    Result := true;
    NewPos := ProposedNewPos;
  end;
end;

procedure TCastleViewport.CameraGetHeight(ACamera: TWalkCamera;
  out IsAbove: boolean; out AboveHeight: Single;
  out AboveGround: P3DTriangle);
begin
  if SceneManager <> nil then
    SceneManager.CameraGetHeight(
      ACamera, IsAbove, AboveHeight, AboveGround) else
  begin
    IsAbove := false;
    AboveHeight := MaxSingle;
    AboveGround := nil;
  end;
end;

function TCastleViewport.CreateDefaultCamera(AOwner: TComponent): TCamera;
begin
  Result := SceneManager.CreateDefaultCamera(AOwner);
end;

function TCastleViewport.GetItems: T3D;
begin
  Result := SceneManager.Items;
end;

function TCastleViewport.GetMainScene: TCastleScene;
begin
  Result := SceneManager.MainScene;
end;

function TCastleViewport.GetShadowVolumeRenderer: TGLShadowVolumeRenderer;
begin
  Result := SceneManager.ShadowVolumeRenderer;
end;

function TCastleViewport.GetMouseRayHit3D: T3D;
begin
  Result := SceneManager.MouseRayHit3D;
end;

function TCastleViewport.GetHeadlightCamera: TCamera;
begin
  Result := SceneManager.Camera;
end;

procedure TCastleViewport.Draw;
begin
  if not GetExists then Exit;

  SceneManager.UpdateGeneratedTexturesIfNeeded;

  inherited;
  ApplyProjection;
  RenderOnScreen(Camera);
end;

procedure TCastleViewport.PointingDeviceActivate(const Active: boolean);
begin
  if SceneManager <> nil then
    SceneManager.PointingDeviceActivate(Active);
end;

procedure TCastleViewport.PointingDeviceMove(const RayOrigin, RayDirection: TVector3Single);
begin
  if SceneManager <> nil then
    SceneManager.PointingDeviceMove(RayOrigin, RayDirection);
end;

procedure TCastleViewport.SetSceneManager(const Value: TCastleSceneManager);
begin
  if Value <> FSceneManager then
  begin
    if SceneManager <> nil then
      SceneManager.Viewports.Remove(Self);
    FSceneManager := Value;
    if SceneManager <> nil then
      SceneManager.Viewports.Add(Self);
  end;
end;

end.
