{
  Copyright 2018-2019 Michalis Kamburelis.

  This file is part of "Castle Game Engine".

  "Castle Game Engine" is free software; see the file COPYING.txt,
  included in this distribution, for details about the copyright.

  "Castle Game Engine" is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

  ----------------------------------------------------------------------------
}

{ Load 3D models in the glTF 2.0 format (@link(LoadGltf)). }
unit X3DLoadInternalGltf;

{$I castleconf.inc}

interface

uses Classes,
  X3DNodes, X3DFields;

{ Load 3D model in the Gltf format, converting it to an X3D nodes graph.
  This routine is internally used by the @link(LoadNode) to load an Gltf file.

  The overloaded version without an explicit Stream will open the URL
  using @link(Download). }
function LoadGltf(const URL: string): TX3DRootNode;
function LoadGltf(const Stream: TStream; const URL: string): TX3DRootNode;

implementation

uses SysUtils, TypInfo, Math, PasGLTF, PasJSON, Generics.Collections,
  CastleClassUtils, CastleDownload, CastleUtils, CastleURIUtils, CastleLog,
  CastleVectors, CastleStringUtils, CastleTextureImages, CastleQuaternions,
  CastleImages, CastleVideos, CastleTimeUtils, CastleTransform, CastleRendererBaseTypes,
  CastleLoadGltf, X3DLoadInternalUtils, CastleBoxes;

{ This unit implements reading glTF into X3D.
  We're using PasGLTF from Bero: https://github.com/BeRo1985/pasgltf/

  Docs:

  - To understand glTF, and PasGLTF API, see the glTF specification:
    https://github.com/KhronosGroup/glTF/tree/master/specification/2.0

  - This unit converts glTF to an X3D scene graph,
    so you should be familiar with X3D as well:
    https://castle-engine.io/vrml_x3d.php .

  - See https://castle-engine.io/creating_data_model_formats.php .

  TODOs:

  - In the future, we would like to avoid using
    Accessor.DecodeAsXxx. Instead we should load binary data straight to GPU,
    looking at buffers, already exposed by PasGLTF.
    New X3D node, like BufferGeometry (same as X3DOM) will need to be
    invented for this, and CastleGeometryArrays will need to be rearranged.

  - Morph targets, or their animations, are not supported yet.

  - Skin animation is done by calculating CoordinateInterpolator at loading.
    At runtime we merely animate using CoordinateInterpolator.
    While this is simple, it has disadvantages:

    - Loading time is longer, as we need to calculate CoordinateInterpolator.
    - At runtime, interpolation and animation blending can only interpolate
      sets of positions (not bones) so:
      - They are not as accurate,
      - CoordinateInterpolator interpolation is done on CPU,
        it processes all mesh positions each frame.
        This is unoptimal, as glTF skinning can be done on GPU, with much smaller runtime cost.

  - See https://castle-engine.io/planned_features.php .
}

{ Convert simple types ------------------------------------------------------- }

function Vector3FromGltf(const V: TPasGLTF.TVector3): TVector3;
begin
  // as it happens, both structures have the same memory layout, so copy by a fast Move
  Assert(SizeOf(V) = SizeOf(Result));
  Move(V, Result, SizeOf(Result));
end;

function Vector4FromGltf(const V: TPasGLTF.TVector4): TVector4;
begin
  // as it happens, both structures have the same memory layout, so copy by a fast Move
  Assert(SizeOf(V) = SizeOf(Result));
  Move(V, Result, SizeOf(Result));
end;

function Matrix4FromGltf(const M: TPasGLTF.TMatrix4x4): TMatrix4;
begin
  // as it happens, both structures have the same memory layout, so copy by a fast Move
  Assert(SizeOf(M) = SizeOf(Result));
  Move(M, Result, SizeOf(Result));
end;

{ Convert glTF rotation (quaternion) to X3D (axis-angle). }
function RotationFromGltf(const V: TPasGLTF.TVector4): TVector4;
var
  RotationQuaternion: TQuaternion;
begin
  RotationQuaternion.Data.Vector4 := Vector4FromGltf(V);
  Result := RotationQuaternion.ToAxisAngle;
end;

{ TMyGltfDocument ------------------------------------------------------------ }

type
  { Descendant of TPasGLTF.TDocument that changes URI loading,
    to load URI using our CastleDownload, thus supporting all our URLs. }
  TMyGltfDocument = class(TPasGLTF.TDocument)
  strict private
    function CastleGetUri(const aURI: TPasGLTFUTF8String): TStream;
  public
    constructor Create(const Stream: TStream; const BaseUrl: String); reintroduce;
  end;

constructor TMyGltfDocument.Create(const Stream: TStream; const BaseUrl: String);
begin
  inherited Create;

  { The interpretation of RootPath lies on our side, in GetUri implementation.
    Just use it to store BaseUrl then. }
  RootPath := BaseUrl;
  GetURI := @CastleGetUri;

  LoadFromStream(Stream);
end;

function TMyGltfDocument.CastleGetUri(const aURI: TPasGLTFUTF8String): TStream;
begin
  { Resolve and open URI using our CGE functions.
    Without this, TPasGLTF.TDocument.DefaultGetURI would always use TFileStream.Create,
    and not work e.g. with Android assets. }
  Result := Download(CombineURI(RootPath, aURI));
end;

{ TGltfAppearanceNode -------------------------------------------------------- }

type
  { X3D Appearance node extended to carry some additional information specified
    in glTF materials. }
  TGltfAppearanceNode = class(TAppearanceNode)
  public
    DoubleSided: Boolean;
  end;

{ TSkinToInitialize ---------------------------------------------------------- }

type
  { Information about skin, to be used later. }
  TSkinToInitialize = class
    Skin: TPasGLTF.TSkin;
    { Direct children of this grouping node that are TShapeNode should have skinning applied. }
    Shapes: TAbstractX3DGroupingNode;
    { Immediate parent of the Shapes node (it always has only one parent). }
    ShapesParent: TAbstractX3DGroupingNode;
  end;

  TSkinToInitializeList = {$ifdef CASTLE_OBJFPC}specialize{$endif} TObjectList<TSkinToInitialize>;

{ TAnimation ----------------------------------------------------------------- }

type
  // Which TTransformNode field is animated
  TGltfSamplerPath = (
    gsTranslation,
    gsRotation,
    gsScale
  );

  TInterpolator = record
    Node: TAbstractInterpolatorNode;
    Target: TTransformNode;
    Path: TGltfSamplerPath;
  end;

  TInterpolatorList = specialize TList<TInterpolator>;

  { Information about created animation. }
  TAnimation = class
    TimeSensor: TTimeSensorNode;
    Interpolators: TInterpolatorList; //< Only TTransformNode instances
    constructor Create;
    destructor Destroy; override;
  end;

  TAnimationList = {$ifdef CASTLE_OBJFPC}specialize{$endif} TObjectList<TAnimation>;

constructor TAnimation.Create;
begin
  inherited;
  Interpolators := TInterpolatorList.Create;
end;

destructor TAnimation.Destroy;
begin
  FreeAndNil(Interpolators);
  inherited;
end;

{ TAnimationSampler --------------------------------------------------------------- }

type
  TAnimationSampler = class
  strict private
    { Internal in SetTime. }
    CurrentTranslation: TVector3List;
    CurrentRotation: TVector4List;
    CurrentScale: TVector3List;
  public
    { Set this before @link(SetTime).
      List of TTransformNode nodes, ordered just list glTF nodes.
      Only initialized (non-nil and enough Count) for nodes that we created in ReadNode. }
    TransformNodes: TX3DNodeList;
    { Set this before @link(SetTime).
      Current animation applied by @link(SetTime). }
    Animation: TAnimation;
    { Owned by this object, calculated by @link(SetTime).
      Has the same size as TransformNodes, contains accumulated transformation matrix
      for each node.
      Contains undefined value for nodes that are @nil. }
    TransformMatrix, TransformMatrixInverse: TMatrix4List;
    TransformNodesRoots: TPasGLTF.TScene.TNodes;
    TransformNodesGltf: TPasGLTF.TNodes;
    constructor Create;
    destructor Destroy; override;
    procedure SetTime(const Time: TFloatTime);
  end;

constructor TAnimationSampler.Create;
begin
  inherited;
  TransformMatrix := TMatrix4List.Create;
  TransformMatrixInverse := TMatrix4List.Create;
  CurrentTranslation := TVector3List.Create;
  CurrentRotation := TVector4List.Create;
  CurrentScale := TVector3List.Create;
end;

destructor TAnimationSampler.Destroy;
begin
  FreeAndNil(TransformMatrix);
  FreeAndNil(TransformMatrixInverse);
  FreeAndNil(CurrentTranslation);
  FreeAndNil(CurrentRotation);
  FreeAndNil(CurrentScale);
  inherited;
end;

procedure TAnimationSampler.SetTime(const Time: TFloatTime);

{ The implementation of this somewhat duplicates the logic
  of the animation and transformation at runtime,
  done by TTransformNode in CastleShapes, CastleSceneCore units.
  At one point I considered just using TTimeSensor.FakeTime
  or even TCastleSceneCore.ForceAnimationPose to set scene
  to given state in each SetTime, and then read resulting transformations
  from Scene.Shapes.

  However, this causes new complications:
  It would modify the nodes hierarchy, which means we should save/restore it.

  And it's not really much simpler, since the transformation hierarchy is quite simple.
}

  { Set all CurrentXxx values to reflect initial transformations of TransformNodes }
  procedure ResetCurrentTransformation;
  var
    I: Integer;
    Transform: TTransformNode;
  begin
    // initialize CurrentXxx lists
    for I := 0 to TransformNodes.Count - 1 do
      if TransformNodes[I] <> nil then
      begin
        Transform := TransformNodes[I] as TTransformNode;
        CurrentTranslation[I] := Transform.FdTranslation.Value;
        CurrentRotation   [I] := Transform.FdRotation   .Value;
        CurrentScale      [I] := Transform.FdScale      .Value;
      end;
  end;

  { Perform PositionInterpolator interpolation.
    Range and T are like results of KeyRange call. }
  function InterpolatePosition(const Interpolator: TPositionInterpolatorNode;
    const Range: Integer; const T: Single): TVector3;
  var
    KeyValue: TVector3List;
  begin
    KeyValue := Interpolator.FdKeyValue.Items;
    if Range = 0 then
      Result := KeyValue[0]
    else
    if Range = KeyValue.Count then
      Result := KeyValue[KeyValue.Count - 1]
    else
      Result := TVector3.Lerp(T, KeyValue[Range - 1], KeyValue[Range]);
  end;

  { Perform OrientationInterpolator interpolation.
    Range and T are like results of KeyRange call. }
  function InterpolateOrientation(const Interpolator: TOrientationInterpolatorNode;
    const Range: Integer; const T: Single): TVector4;
  var
    KeyValue: TVector4List;
  begin
    KeyValue := Interpolator.FdKeyValue.Items;
    if Range = 0 then
      Result := KeyValue[0]
    else
    if Range = KeyValue.Count then
      Result := KeyValue[KeyValue.Count - 1]
    else
      // SLerp, like TOrientationInterpolatorNode.InterpolatorLerp
      Result := SLerp(T, KeyValue[Range - 1], KeyValue[Range]);
  end;

  { Update all CurrentXxx values affected by this animation. }
  procedure UpdateCurrentTransformation;
  var
    Interpolator: TInterpolator;
    T: Single;
    Range, TargetIndex: Integer;
    Key: TSingleList;
  begin
    for Interpolator in Animation.Interpolators do
    begin
      TargetIndex := TransformNodes.IndexOf(Interpolator.Target);
      if TargetIndex = -1 then
        raise EInternalError.Create('Interpolator.Target not on Nodes list');

      { Below we process time,
        similar to TAbstractSingleInterpolatorNode.EventSet_FractionReceive. }

      Key := Interpolator.Node.FdKey.Items;
      if Key.Count = 0 then
        // Interpolator nodes containing no keys in the key field shall not produce any events.
        Exit;

      Range := KeyRange(Key, Time, T);

      case Interpolator.Path of
        gsTranslation: CurrentTranslation[TargetIndex] :=
          InterpolatePosition(Interpolator.Node as TPositionInterpolatorNode, Range, T);
        gsRotation: CurrentRotation[TargetIndex] :=
          InterpolateOrientation(Interpolator.Node as TOrientationInterpolatorNode, Range, T);
        gsScale: CurrentScale[TargetIndex] :=
          InterpolatePosition(Interpolator.Node as TPositionInterpolatorNode, Range, T);
        {$ifndef COMPILER_CASE_ANALYSIS}
        else raise EInternalError.Create('Unexpected glTF Interpolator.Path value');
        {$endif}
      end;
    end;
  end;

  { Calculate contents of TransformMatrix, based on CurrentXxx and parent-child relationships. }
  procedure UpdateMatrix;

    procedure UpdateChildMatrix(const NodeIndex: Integer;
      const ParentT, ParentTInv: TMatrix4);
    var
      T, TInv: PMatrix4;
      ChildNodeIndex: Integer;
    begin
      if not Between(NodeIndex, 0, TransformMatrix.Count - 1) then
        Exit; // warning about it was already done by ReadNodes

      T := TransformMatrix.Ptr(NodeIndex);
      TInv := TransformMatrixInverse.Ptr(NodeIndex);
      T^ := ParentT;
      TInv^ := ParentTInv;
      { TODO: is it efficient to use TransformMatricesMult?
        We could instead have simplified TransformMatrix,
        that ignores center/scaleOrientation,
        and doesn't calculate inverse (would have to be calculated later once for skeleton root).
        Test is this faster? }
      TransformMatricesMult(T^, TInv^, TVector3.Zero,
        CurrentRotation[NodeIndex],
        CurrentScale[NodeIndex],
        TVector4.Zero,
        CurrentTranslation[NodeIndex]);

      for ChildNodeIndex in TransformNodesGltf[NodeIndex].Children do
        UpdateChildMatrix(ChildNodeIndex, T^, TInv^);
    end;

  var
    T, TInv: PMatrix4;
    RootNodeIndex, ChildNodeIndex: Integer;
  begin
    for RootNodeIndex in TransformNodesRoots do
    begin
      if not Between(RootNodeIndex, 0, TransformMatrix.Count - 1) then
        Continue; // warning about it was already done by ReadScene

      T := TransformMatrix.Ptr(RootNodeIndex);
      TInv := TransformMatrixInverse.Ptr(RootNodeIndex);
      T^ := TMatrix4.Identity;
      TInv^ := TMatrix4.Identity;
      TransformMatricesMult(T^, TInv^, TVector3.Zero,
        CurrentRotation[RootNodeIndex],
        CurrentScale[RootNodeIndex],
        TVector4.Zero,
        CurrentTranslation[RootNodeIndex]);

      for ChildNodeIndex in TransformNodesGltf[RootNodeIndex].Children do
        UpdateChildMatrix(ChildNodeIndex, T^, TInv^);
    end;
  end;

begin
  { Since in practice TransformNodes.Count is constant during glTF file reading,
    this sets the size only at first SetTime call (for this glTF model). }
  TransformMatrix.Count := TransformNodes.Count;
  TransformMatrixInverse.Count := TransformNodes.Count;
  CurrentTranslation.Count := TransformNodes.Count;
  CurrentRotation.Count := TransformNodes.Count;
  CurrentScale.Count := TransformNodes.Count;

  ResetCurrentTransformation;
  UpdateCurrentTransformation;
  UpdateMatrix;
end;

{ TTexture ------------------------------------------------------------------- }

type
  { Texture from glTF information.
    Simpler to initialize than TPasGLTF.TMaterial.TTexture.
    ( https://github.com/BeRo1985/pasgltf/blob/master/src/viewer/UnitGLTFOpenGL.pas
    also does it like this, with TTexture record to handle PBRSpecularGlossiness. ) }
  TTexture = record
    Index: TPasGLTFSizeInt;
    TexCoord: TPasGLTFSizeInt;
    procedure Init;
    function Empty: Boolean;
  end;

procedure TTexture.Init;
begin
  Index := -1;
  TexCoord := 0;
end;

function TTexture.Empty: Boolean;
begin
  Result := Index < 0;
end;

{ TPbrMetallicRoughness ------------------------------------------------------ }

type
  TPbrMetallicRoughness = record
    BaseColorFactor: TVector4;
    BaseColorTexture: TTexture;
    MetallicFactor, RoughnessFactor: Single;
    MetallicRoughnessTexture: TTexture;
    { Read glTF material parameters into PBR metallic-roughness model.

      This internally handles PBR specular-glossiness model, converting
      it into metallic-roughness. See
      https://github.com/KhronosGroup/glTF/tree/master/extensions/2.0/Khronos/KHR_materials_pbrSpecularGlossiness
      https://github.com/KhronosGroup/glTF/blob/master/extensions/2.0/Khronos/KHR_materials_pbrSpecularGlossiness/examples/convert-between-workflows/js/three.pbrUtilities.js
    }
    procedure Read(const Material: TPasGLTF.TMaterial);
  end;

procedure TPbrMetallicRoughness.Read(const Material: TPasGLTF.TMaterial);
var
  JsonSpecGlossItem, JSONItem: TPasJSONItem;
  JsonSpecGloss: TPasJSONItemObject;
begin
  BaseColorTexture.Init;
  MetallicRoughnessTexture.Init;

  BaseColorFactor := Vector4FromGltf(Material.PBRMetallicRoughness.BaseColorFactor);
  BaseColorTexture.Index := Material.PBRMetallicRoughness.BaseColorTexture.Index;
  BaseColorTexture.TexCoord := Material.PBRMetallicRoughness.BaseColorTexture.TexCoord;
  MetallicFactor := Material.PBRMetallicRoughness.MetallicFactor;
  RoughnessFactor := Material.PBRMetallicRoughness.RoughnessFactor;
  MetallicRoughnessTexture.Index := Material.PBRMetallicRoughness.MetallicRoughnessTexture.Index;
  MetallicRoughnessTexture.TexCoord := Material.PBRMetallicRoughness.MetallicRoughnessTexture.TexCoord;

  { Read PBR specular-glossiness }

  JsonSpecGlossItem := Material.Extensions.Properties['KHR_materials_pbrSpecularGlossiness'];
  if Material.PBRMetallicRoughness.Empty and
     (JsonSpecGlossItem is TPasJSONItemObject) then
  begin
    WritelnWarning('Material "%s" has only PBR specular-glossiness parameters. We support it only partially (diffuseFactor, diffuseTexture are just used for baseFactor, baseTexture). Better use metallic-roughness model.', [
      Material.Name
    ]);

    { Read PBR specular-glossiness subset.
      As we only read subset, we use it only when
      Material.PBRMetallicRoughness is empty, despite
      https://github.com/KhronosGroup/glTF/tree/master/extensions/2.0/Khronos/KHR_materials_pbrSpecularGlossiness
      advising to use specular-glossiness if you can.

      Code below, to read specular-glossiness from JSON, is based on PasGLTF UnitGLTFOpenGL. }
    JsonSpecGloss := TPasJSONItemObject(JsonSpecGlossItem);

    JSONItem := JsonSpecGloss.Properties['diffuseFactor'];
    if Assigned(JSONItem) and
       (JSONItem is TPasJSONItemArray) and
       (TPasJSONItemArray(JSONItem).Count = 4) then
    begin
      BaseColorFactor[0] := TPasJSON.GetNumber(TPasJSONItemArray(JSONItem).Items[0], TPasGLTF.TDefaults.IdentityVector4[0]);
      BaseColorFactor[1] := TPasJSON.GetNumber(TPasJSONItemArray(JSONItem).Items[1], TPasGLTF.TDefaults.IdentityVector4[1]);
      BaseColorFactor[2] := TPasJSON.GetNumber(TPasJSONItemArray(JSONItem).Items[2], TPasGLTF.TDefaults.IdentityVector4[2]);
      BaseColorFactor[3] := TPasJSON.GetNumber(TPasJSONItemArray(JSONItem).Items[3], TPasGLTF.TDefaults.IdentityVector4[3]);
    end;

    JSONItem := JsonSpecGloss.Properties['diffuseTexture'];
    if Assigned(JSONItem) and
       (JSONItem is TPasJSONItemObject) then
    begin
      BaseColorTexture.Index := TPasJSON.GetInt64(TPasJSONItemObject(JSONItem).Properties['index'], -1);
      BaseColorTexture.TexCoord := TPasJSON.GetInt64(TPasJSONItemObject(JSONItem).Properties['texCoord'], 0);
      // TODO: LoadTextureTransform(TPasJSONItemObject(JSONItem).Properties['extensions']);
    end;
  end;
end;

{ LoadGltf ------------------------------------------------------------------- }

{ Main routine that converts glTF -> X3D nodes, doing most of the work. }
function LoadGltf(const Stream: TStream; const URL: string): TX3DRootNode;
var
  BaseUrl: String;
  Document: TPasGLTF.TDocument;
  // List of TGltfAppearanceNode nodes, ordered just list glTF materials
  Appearances: TX3DNodeList;
  { List of TTransformNode nodes, ordered just list glTF nodes.
    Only initialized (non-nil and enough Count) for nodes that we created in ReadNode. }
  Nodes: TX3DNodeList;
  DefaultAppearance: TGltfAppearanceNode;
  SkinsToInitialize: TSkinToInitializeList;
  Animations: TAnimationList;
  AnimationSampler: TAnimationSampler;
  JointMatrix: TMatrix4List; //< local for SampleSkinAnimation, but created once to avoid wasting time on allocation

  procedure ReadHeader;
  begin
    WritelnLogMultiline('glTF', Format(
      'Asset.Copyright: %s' + NL +
      'Asset.Generator: %s' + NL +
      'Asset.MinVersion: %s' + NL +
      'Asset.Version: %s' + NL +
      'Asset.Empty: %s' + NL +
      'Accessors: %d' + NL +
      'Animations: %d' + NL +
      'Buffers: %d' + NL +
      'BufferViews: %d' + NL +
      'Cameras: %d' + NL +
      'Images: %d' + NL +
      'Materials: %d' + NL +
      'Meshes: %d' + NL +
      'Nodes: %d' + NL +
      'Samplers: %d' + NL +
      'Scenes: %d' + NL +
      'Skins: %d' + NL +
      'Textures: %d' + NL +
      'ExtensionsUsed: %s' + NL +
      'ExtensionsRequired: %s' + NL +
      '', [
        Document.Asset.Copyright,
        Document.Asset.Generator,
        Document.Asset.MinVersion,
        Document.Asset.Version,
        BoolToStr(Document.Asset.Empty, true),

        Document.Accessors.Count,
        Document.Animations.Count,
        Document.Buffers.Count,
        Document.BufferViews.Count,
        Document.Cameras.Count,
        Document.Images.Count,
        Document.Materials.Count,
        Document.Meshes.Count,
        Document.Nodes.Count,
        Document.Samplers.Count,
        Document.Scenes.Count,
        Document.Skins.Count,
        Document.Textures.Count,
        Document.ExtensionsUsed.Text,
        Document.ExtensionsRequired.Text
      ])
    );
    if Document.ExtensionsRequired.IndexOf('KHR_draco_mesh_compression') <> -1 then
      WritelnWarning('Required extension KHR_draco_mesh_compression not supported by glTF reader');
  end;

  function ReadTextureRepeat(const Wrap: TPasGLTF.TSampler.TWrappingMode): Boolean;
  begin
    Result :=
      (Wrap = TPasGLTF.TSampler.TWrappingMode.Repeat_) or
      (Wrap = TPasGLTF.TSampler.TWrappingMode.MirroredRepeat);
    if Wrap = TPasGLTF.TSampler.TWrappingMode.MirroredRepeat then
      WritelnWarning('glTF', 'MirroredRepeat wrap mode not supported, using simple Repeat');
  end;

  function ReadMinificationFilter(const Filter: TPasGLTF.TSampler.TMinFilter): TAutoMinificationFilter;
  begin
    case Filter of
      TPasGLTF.TSampler.TMinFilter.None                : Result := minDefault;
      TPasGLTF.TSampler.TMinFilter.Nearest             : Result := minNearest;
      TPasGLTF.TSampler.TMinFilter.Linear              : Result := minLinear;
      TPasGLTF.TSampler.TMinFilter.NearestMipMapNearest: Result := minNearestMipmapNearest;
      TPasGLTF.TSampler.TMinFilter.LinearMipMapNearest : Result := minLinearMipmapNearest;
      TPasGLTF.TSampler.TMinFilter.NearestMipMapLinear : Result := minNearestMipmapLinear;
      TPasGLTF.TSampler.TMinFilter.LinearMipMapLinear  : Result := minLinearMipmapLinear;
      else raise EInternalError.Create('Unexpected glTF minification filter');
    end;
  end;

  function ReadMagnificationFilter(const Filter: TPasGLTF.TSampler.TMagFilter): TAutoMagnificationFilter;
  begin
    case Filter of
      TPasGLTF.TSampler.TMagFilter.None   : Result := magDefault;
      TPasGLTF.TSampler.TMagFilter.Nearest: Result := magNearest;
      TPasGLTF.TSampler.TMagFilter.Linear : Result := magLinear;
      else raise EInternalError.Create('Unexpected glTF magnification filter');
    end;
  end;

  procedure ReadTexture(const GltfTextureAtMaterial: TTexture;
    out Texture: TAbstractX3DTexture2DNode; out TexChannel: Integer);
  var
    GltfTexture: TPasGLTF.TTexture;
    GltfImage: TPasGLTF.TImage;
    GltfSampler: TPasGLTF.TSampler;
    TextureProperties: TTexturePropertiesNode;
    Stream: TMemoryStream;
  begin
    Texture := nil;
    TexChannel := GltfTextureAtMaterial.TexCoord;

    if not GltfTextureAtMaterial.Empty then
    begin
      if GltfTextureAtMaterial.Index < Document.Textures.Count then
      begin
        GltfTexture := Document.Textures[GltfTextureAtMaterial.Index];

        if Between(GltfTexture.Source, 0, Document.Images.Count - 1) then
        begin
          GltfImage := Document.Images[GltfTexture.Source];
          if GltfImage.URI <> '' then
          begin
            if FfmpegVideoMimeType(URIMimeType(GltfImage.URI), false) then
            begin
              Texture := TMovieTextureNode.Create('', BaseUrl);
              TMovieTextureNode(Texture).SetUrl([GltfImage.URI]);
              TMovieTextureNode(Texture).FlipVertically := true;
              TMovieTextureNode(Texture).Loop := true;
            end else
            begin
              Texture := TImageTextureNode.Create('', BaseUrl);
              TImageTextureNode(Texture).SetUrl([GltfImage.URI]);

              { glTF specification defines (0,0) texture coord to be
                at top-left corner, while X3D and OpenGL and OpenGLES expect it be
                at bottom-left corner.
                See
                https://castle-engine.io/x3d_implementation_texturing_extensions.php#section_flip_vertically
                for a detailed discussion.

                So we flip the textures.
                This way we can use original texture coordinates from glTF
                file (no need to process them, by doing "y := 1 - y"). }
              TImageTextureNode(Texture).FlipVertically := true;
            end;
          end else
          if GltfImage.BufferView >= 0 then
          begin
            { Use GltfImage.GetResourceData to load from buffer
              (instead of an external file). In particular, this is necessary to
              support GLB format with textures.

              Note that we use GltfImage.GetResourceData only when
              GltfImage.BufferView was set. Otherwise, we want to interpret URI
              by CGE code, thus allowing to read files using our Download()
              that understands also http/https, castle-data, castle-android-assets etc.
            }
            Stream := TMemoryStream.Create;
            try
              GltfImage.GetResourceData(Stream);
              Stream.Position := 0;

              { TODO: In case this is a DDS/KTX file, by using LoadImage
                we lose information about additional mipmaps,
                cubemap faces etc. }

              Texture := TPixelTextureNode.Create;
              try
                TPixelTextureNode(Texture).FdImage.Value :=
                  LoadImage(Stream, GltfImage.MimeType, []);
              except
                on E: Exception do
                  WritelnWarning('glTF', 'Cannot load the texture from glTF binary buffer with mime type %s: %s',
                    [GltfImage.MimeType, ExceptMessage(E)]);
              end;

              { Same reason as for TImageTextureNode.FlipVertically above:
                glTF specification defines (0,0) texture coord to be
                at top-left corner. }
              TPixelTextureNode(Texture).FdImage.Value.FlipVertical;
            finally FreeAndNil(Stream) end;
          end;
        end;

        if Between(GltfTexture.Sampler, 0, Document.Samplers.Count - 1) then
        begin
          GltfSampler := Document.Samplers[GltfTexture.Sampler];

          Texture.RepeatS := ReadTextureRepeat(GltfSampler.WrapS);
          Texture.RepeatT := ReadTextureRepeat(GltfSampler.WrapT);

          if (GltfSampler.MinFilter <> TPasGLTF.TSampler.TMinFilter.None) or
             (GltfSampler.MagFilter <> TPasGLTF.TSampler.TMagFilter.None) then
          begin
            TextureProperties := TTexturePropertiesNode.Create;
            TextureProperties.MinificationFilter := ReadMinificationFilter(GltfSampler.MinFilter);
            TextureProperties.MagnificationFilter := ReadMagnificationFilter(GltfSampler.MagFilter);
            Texture.TextureProperties := TextureProperties;
          end;
        end;
      end;
    end;
  end;

  procedure ReadTexture(const GltfTextureAtMaterial: TPasGLTF.TMaterial.TTexture;
    out Texture: TAbstractX3DTexture2DNode; out TexChannel: Integer);
  var
    TextureRec: TTexture;
  begin
    TextureRec.Init;
    TextureRec.Index := GltfTextureAtMaterial.Index;
    TextureRec.TexCoord := GltfTextureAtMaterial.TexCoord;
    ReadTexture(TextureRec, Texture, TexChannel);
  end;

  function ReadPhongMaterial(const Material: TPasGLTF.TMaterial): TMaterialNode;
  var
    PbrMetallicRoughness: TPbrMetallicRoughness;
    BaseColorTexture, NormalTexture, EmissiveTexture: TAbstractX3DTexture2DNode;
    BaseColorTextureChannel, NormalTextureChannel, EmissiveTextureChannel: Integer;
    // MetallicFactor, RoughnessFactor: Single;
  begin
    PbrMetallicRoughness.Read(Material);

    Result := TMaterialNode.Create;
    Result.DiffuseColor := PbrMetallicRoughness.BaseColorFactor.XYZ;
    Result.Transparency := 1 - PbrMetallicRoughness.BaseColorFactor.W;
    Result.EmissiveColor := Vector3FromGltf(Material.EmissiveFactor);

    // Metallic/roughness conversion idea from X3DOM.
    // Gives weird artifacts on some samples (Duck, FlightHelmet) so not used now.
    (*
    MetallicFactor := PbrMetallicRoughness.MetallicFactor;
    RoughnessFactor := PbrMetallicRoughness.RoughnessFactor;
    Result.SpecularColor := Vector3(
      Lerp(MetallicFactor, 0.04, BaseColorFactor.X),
      Lerp(MetallicFactor, 0.04, BaseColorFactor.Y),
      Lerp(MetallicFactor, 0.04, BaseColorFactor.Z)
    );
    Result.Shininess := 1 - RoughnessFactor;
    *)

    ReadTexture(PbrMetallicRoughness.BaseColorTexture, BaseColorTexture, BaseColorTextureChannel);
    Result.DiffuseTexture := BaseColorTexture;
    Result.DiffuseTextureChannel := BaseColorTextureChannel;

    ReadTexture(Material.NormalTexture,
      NormalTexture, NormalTextureChannel);
    Result.NormalTexture := NormalTexture;
    Result.NormalTextureChannel := NormalTextureChannel;

    ReadTexture(Material.EmissiveTexture,
      EmissiveTexture, EmissiveTextureChannel);
    Result.EmissiveTexture := EmissiveTexture;
    Result.EmissiveTextureChannel := EmissiveTextureChannel;
  end;

  function ReadPhysicalMaterial(const Material: TPasGLTF.TMaterial): TPhysicalMaterialNode;
  var
    PbrMetallicRoughness: TPbrMetallicRoughness;
    BaseColorTexture, NormalTexture, EmissiveTexture, MetallicRoughnessTexture: TAbstractX3DTexture2DNode;
    BaseColorTextureChannel, NormalTextureChannel, EmissiveTextureChannel, MetallicRoughnessTextureChannel: Integer;
  begin
    PbrMetallicRoughness.Read(Material);

    Result := TPhysicalMaterialNode.Create;
    Result.BaseColor := PbrMetallicRoughness.BaseColorFactor.XYZ;
    Result.Transparency := 1 - PbrMetallicRoughness.BaseColorFactor.W;
    Result.Metallic := PbrMetallicRoughness.MetallicFactor;
    Result.Roughness := PbrMetallicRoughness.RoughnessFactor;
    Result.EmissiveColor := Vector3FromGltf(Material.EmissiveFactor);

    ReadTexture(PbrMetallicRoughness.BaseColorTexture,
      BaseColorTexture, BaseColorTextureChannel);
    Result.BaseTexture := BaseColorTexture;
    Result.BaseTextureChannel := BaseColorTextureChannel;

    ReadTexture(Material.NormalTexture,
      NormalTexture, NormalTextureChannel);
    Result.NormalTexture := NormalTexture;
    Result.NormalTextureChannel := NormalTextureChannel;

    ReadTexture(Material.EmissiveTexture,
      EmissiveTexture, EmissiveTextureChannel);
    Result.EmissiveTexture := EmissiveTexture;
    Result.EmissiveTextureChannel := EmissiveTextureChannel;

    ReadTexture(PbrMetallicRoughness.MetallicRoughnessTexture,
      MetallicRoughnessTexture, MetallicRoughnessTextureChannel);
    Result.MetallicRoughnessTexture := MetallicRoughnessTexture;
    Result.MetallicRoughnessTextureChannel := MetallicRoughnessTextureChannel;
  end;

  { Read glTF unlit material, see
    https://github.com/KhronosGroup/glTF/tree/master/extensions/2.0/Khronos/KHR_materials_unlit .
    Note that baseColor/Texture is converted to X3D emissiveColor/Texture. }
  function ReadUnlitMaterial(const Material: TPasGLTF.TMaterial): TUnlitMaterialNode;
  var
    BaseColorFactor: TVector4;
    BaseColorTexture, NormalTexture: TAbstractX3DTexture2DNode;
    BaseColorTextureChannel, NormalTextureChannel: Integer;
  begin
    BaseColorFactor := Vector4FromGltf(Material.PBRMetallicRoughness.BaseColorFactor);

    Result := TUnlitMaterialNode.Create;
    Result.EmissiveColor := BaseColorFactor.XYZ;
    Result.Transparency := 1 - BaseColorFactor.W;

    ReadTexture(Material.PBRMetallicRoughness.BaseColorTexture,
      BaseColorTexture, BaseColorTextureChannel);
    Result.EmissiveTexture := BaseColorTexture;
    Result.EmissiveTextureChannel := BaseColorTextureChannel;

    { We read normal texture, even though it isn't *usually* useful for UnlitMaterial.
      But it makes sense when geometry has TextureCoordinateGenerator
      that depends on normal info.
      And both glTF and X3Dv4 allow normal texture even in case of unlit materials. }
    ReadTexture(Material.NormalTexture,
      NormalTexture, NormalTextureChannel);
    Result.NormalTexture := NormalTexture;
    Result.NormalTextureChannel := NormalTextureChannel;
  end;

  function ReadAppearance(const Material: TPasGLTF.TMaterial): TGltfAppearanceNode;
  var
    AlphaChannel: TAutoAlphaChannel;
  begin
    Result := TGltfAppearanceNode.Create(Material.Name);

    if Material.Extensions.Properties['KHR_materials_unlit'] <> nil then
      Result.Material := ReadUnlitMaterial(Material)
    else
    if GltfForcePhongMaterials then
      Result.Material := ReadPhongMaterial(Material)
    else
      Result.Material := ReadPhysicalMaterial(Material);

    // read common material properties, that make sense in case of all material type
    Result.DoubleSided := Material.DoubleSided;

    // read alpha channel treatment
    case Material.AlphaMode of
      TPasGLTF.TMaterial.TAlphaMode.Opaque: AlphaChannel := acNone;
      TPasGLTF.TMaterial.TAlphaMode.Blend : AlphaChannel := acBlending;
      TPasGLTF.TMaterial.TAlphaMode.Mask  : AlphaChannel := acTest;
      {$ifndef COMPILER_CASE_ANALYSIS}
      else raise EInternalError.Create('Unexpected glTF Material.AlphaMode value');
      {$endif}
    end;
    Result.AlphaChannel := AlphaChannel;

    // TODO: ignored for now:
    // Result.AlphaClipThreshold := Material.AlphaCutOff;
    // Implement AlphaClipThreshold from X3DOM / InstantReality:
    // https://doc.x3dom.org/author/Shape/Appearance.html
    // https://www.x3dom.org/news/
    // (our default 0.5?)
  end;

  function AccessorTypeToStr(const AccessorType: TPasGLTF.TAccessor.TType): String;
  begin
    Result := GetEnumName(TypeInfo(TPasGLTF.TAccessor.TType), Ord(AccessorType));
  end;

  function PrimitiveModeToStr(const Mode: TPasGLTF.TMesh.TPrimitive.TMode): String;
  begin
    Result := GetEnumName(TypeInfo(TPasGLTF.TMesh.TPrimitive.TMode), Ord(Mode));
  end;

  function GetAccessor(const AccessorIndex: Integer): TPasGLTF.TAccessor;
  begin
    if AccessorIndex < Document.Accessors.Count then
      Result := Document.Accessors[AccessorIndex]
    else
    begin
      Result := nil;
      WritelnWarning('glTF', 'Missing glTF accessor (index %d, but we only have %d accessors)',
        [AccessorIndex, Document.Accessors.Count]);
    end;
  end;

  { The argument ForVertex addresses this statement of the glTF spec:
    """
    For performance and compatibility reasons, each element of
    a vertex attribute must be aligned to 4-byte boundaries
    inside bufferView
    """ }

  procedure AccessorToInt32(const AccessorIndex: Integer; const Field: TMFLong; const ForVertex: Boolean);
  var
    Accessor: TPasGLTF.TAccessor;
    A: TPasGLTFInt32DynamicArray;
    Len: Integer;
  begin
    Accessor := GetAccessor(AccessorIndex);
    if Accessor <> nil then
    begin
      A := Accessor.DecodeAsInt32Array(ForVertex);
      Len := Length(A);
      Field.Count := Len;
      if Len <> 0 then
        Move(A[0], Field.Items.List^[0], SizeOf(LongInt) * Len);
    end;
  end;

  procedure AccessorToFloat(const AccessorIndex: Integer; const Field: TMFFloat; const ForVertex: Boolean);
  var
    Accessor: TPasGLTF.TAccessor;
    A: TPasGLTFFloatDynamicArray;
    Len: Integer;
  begin
    Accessor := GetAccessor(AccessorIndex);
    if Accessor <> nil then
    begin
      A := Accessor.DecodeAsFloatArray(ForVertex);
      Len := Length(A);
      Field.Count := Len;
      if Len <> 0 then
        // Both glTF and X3D call it "Float", it is "Single" in Pascal
        Move(A[0], Field.Items.List^[0], SizeOf(Single) * Len);
    end;
  end;

  procedure AccessorToVector2(const AccessorIndex: Integer; const Field: TMFVec2f; const ForVertex: Boolean);
  var
    Accessor: TPasGLTF.TAccessor;
    A: TPasGLTF.TVector2DynamicArray;
    Len: Integer;
  begin
    Accessor := GetAccessor(AccessorIndex);
    if Accessor <> nil then
    begin
      A := Accessor.DecodeAsVector2Array(ForVertex);
      Len := Length(A);
      Field.Count := Len;
      if Len <> 0 then
        Move(A[0], Field.Items.List^[0], SizeOf(TVector2) * Len);
    end;
  end;

  procedure AccessorToVector3(const AccessorIndex: Integer; const Field: TMFVec3f; const ForVertex: Boolean);
  var
    Accessor: TPasGLTF.TAccessor;
    A: TPasGLTF.TVector3DynamicArray;
    Len: Integer;
  begin
    Accessor := GetAccessor(AccessorIndex);
    if Accessor <> nil then
    begin
      A := Accessor.DecodeAsVector3Array(ForVertex);
      Len := Length(A);
      Field.Count := Len;
      if Len <> 0 then
        Move(A[0], Field.Items.List^[0], SizeOf(TVector3) * Len);
    end;
  end;

  procedure AccessorToVector4(const AccessorIndex: Integer; const Field: TVector4List; const ForVertex: Boolean);
  var
    Accessor: TPasGLTF.TAccessor;
    A: TPasGLTF.TVector4DynamicArray;
    Len: Integer;
  begin
    Accessor := GetAccessor(AccessorIndex);
    if Accessor <> nil then
    begin
      A := Accessor.DecodeAsVector4Array(ForVertex);
      Len := Length(A);
      Field.Count := Len;
      if Len <> 0 then
        Move(A[0], Field.List^[0], SizeOf(TVector4) * Len);
    end;
  end;

  procedure AccessorToVector4(const AccessorIndex: Integer; const Field: TMFVec4f; const ForVertex: Boolean);
  begin
    AccessorToVector4(AccessorIndex, Field.Items, ForVertex);
  end;

  procedure AccessorToVector4Integer(const AccessorIndex: Integer; const Field: TVector4IntegerList; const ForVertex: Boolean);
  var
    Accessor: TPasGLTF.TAccessor;
    A: TPasGLTF.TInt32Vector4DynamicArray;
    Len: Integer;
  begin
    Accessor := GetAccessor(AccessorIndex);
    if Accessor <> nil then
    begin
      A := Accessor.DecodeAsInt32Vector4Array(ForVertex);
      Len := Length(A);
      Field.Count := Len;
      if Len <> 0 then
        Move(A[0], Field.List^[0], SizeOf(TVector4Integer) * Len);
    end;
  end;

  procedure AccessorToMatrix4(const AccessorIndex: Integer; const List: TMatrix4List; const ForVertex: Boolean);
  var
    Accessor: TPasGLTF.TAccessor;
    A: TPasGLTF.TMatrix4x4DynamicArray;
    Len: Integer;
  begin
    Accessor := GetAccessor(AccessorIndex);
    if Accessor <> nil then
    begin
      A := Accessor.DecodeAsMatrix4x4Array(ForVertex);
      Len := Length(A);
      List.Count := Len;
      if Len <> 0 then
        Move(A[0], List.List^[0], SizeOf(TMatrix4) * Len);
    end;
  end;

  procedure AccessorToRotation(const AccessorIndex: Integer; const Field: TMFRotation; const ForVertex: Boolean);
  var
    Accessor: TPasGLTF.TAccessor;
    A: TPasGLTF.TVector4DynamicArray;
    Len, I: Integer;
  begin
    Accessor := GetAccessor(AccessorIndex);
    if Accessor <> nil then
    begin
      A := Accessor.DecodeAsVector4Array(ForVertex);
      Len := Length(A);
      Field.Count := Len;
      // convert glTF rotation to X3D
      for I := 0 to Len - 1 do
        Field.Items.List^[I] := RotationFromGltf(A[I]);
    end;
  end;

  { Set SingleTexCoord as a texture coordinate.
    Sets up TexCoordField as a TMultiTextureCoordinateNode instance,
    in case we have multiple texture coordinates. }
  procedure SetMultiTextureCoordinate(const TexCoordField: TSFNode;
    const SingleTexCoord: TTextureCoordinateNode;
    const SingleTexCoordIndex: Integer);
  var
    MultiTexCoord: TMultiTextureCoordinateNode;
  begin
    if TexCoordField.Value <> nil then
      { only this procedure modifies this field,
        so it has to be TMultiTextureCoordinateNode if assigned. }
      MultiTexCoord := TexCoordField.Value as TMultiTextureCoordinateNode
    else
    begin
      MultiTexCoord := TMultiTextureCoordinateNode.Create;
      TexCoordField.Value := MultiTexCoord;
    end;

    MultiTexCoord.FdTexCoord.Count := Max(MultiTexCoord.FdTexCoord.Count, SingleTexCoordIndex + 1);
    MultiTexCoord.FdTexCoord.Items[SingleTexCoordIndex] := SingleTexCoord;
  end;

  procedure ReadPrimitive(const Primitive: TPasGLTF.TMesh.TPrimitive;
    const ParentGroup: TGroupNode);
  var
    AttributeName: TPasGLTFUTF8String;
    Shape: TShapeNode;
    Geometry: TAbstractGeometryNode;
    Coord: TCoordinateNode;
    TexCoord: TTextureCoordinateNode;
    Normal: TNormalNode;
    Color: TColorNode;
    ColorRGBA: TColorRGBANode;
    ColorAccessor: TPasGLTF.TAccessor;
    IndexField: TMFLong;
    TexCoordIndex: LongInt;
    Appearance: TGltfAppearanceNode;
  begin
    // create X3D geometry and shape nodes
    if Primitive.Indices <> -1 then
    begin
      case Primitive.Mode of
        TPasGLTF.TMesh.TPrimitive.TMode.Lines        : Geometry := TIndexedLineSetNode.CreateWithShape(Shape);
        // TODO: these will require unpacking and expressing as TIndexedLineSetNode
        //TPasGLTF.TMesh.TPrimitive.TMode.LineLoop     : Geometry := TIndexedLineSetNode.CreateWithShape(Shape);
        //TPasGLTF.TMesh.TPrimitive.TMode.LineStrip    : Geometry := TIndexedLineSetNode.CreateWithShape(Shape);
        TPasGLTF.TMesh.TPrimitive.TMode.Triangles    : Geometry := TIndexedTriangleSetNode.CreateWithShape(Shape);
        TPasGLTF.TMesh.TPrimitive.TMode.TriangleStrip: Geometry := TIndexedTriangleStripSetNode.CreateWithShape(Shape);
        TPasGLTF.TMesh.TPrimitive.TMode.TriangleFan  : Geometry := TIndexedTriangleFanSetNode.CreateWithShape(Shape);
        else
          begin
            WritelnWarning('glTF', 'Primitive mode not implemented (in indexed mode): ' + PrimitiveModeToStr(Primitive.Mode));
            Exit;
          end;
      end;
    end else
    begin
      case Primitive.Mode of
        TPasGLTF.TMesh.TPrimitive.TMode.Lines        : Geometry := TLineSetNode.CreateWithShape(Shape);
        // TODO: these will require unpacking and expressing as TIndexedLineSetNode
        //TPasGLTF.TMesh.TPrimitive.TMode.LineLoop     : Geometry := TIndexedLineSetNode.CreateWithShape(Shape);
        //TPasGLTF.TMesh.TPrimitive.TMode.LineStrip    : Geometry := TIndexedLineSetNode.CreateWithShape(Shape);
        TPasGLTF.TMesh.TPrimitive.TMode.Triangles    : Geometry := TTriangleSetNode.CreateWithShape(Shape);
        TPasGLTF.TMesh.TPrimitive.TMode.TriangleStrip: Geometry := TTriangleStripSetNode.CreateWithShape(Shape);
        TPasGLTF.TMesh.TPrimitive.TMode.TriangleFan  : Geometry := TTriangleFanSetNode.CreateWithShape(Shape);
        else
          begin
            WritelnWarning('glTF', 'Primitive mode not implemented (in non-indexed) mode: ' + PrimitiveModeToStr(Primitive.Mode));
            Exit;
          end;
      end;
    end;

    // read indexes
    IndexField := Geometry.CoordIndexField;
    if IndexField <> nil then
    begin
      Assert(Primitive.Indices <> -1);
      AccessorToInt32(Primitive.Indices, IndexField, false);
    end;

    // parse attributes (initializing Coord, TexCoord and other such nodes)
    // TODO: ForVertex true for all, or just for POSITION?
    for AttributeName in Primitive.Attributes.Keys do
    begin
      if (AttributeName = 'POSITION') and (Geometry.CoordField <> nil) then
      begin
        Coord := TCoordinateNode.Create;
        AccessorToVector3(Primitive.Attributes[AttributeName], Coord.FdPoint, true);
        Geometry.CoordField.Value := Coord;
        Shape.BBox := TBox3D.FromPoints(Coord.FdPoint.Items);
      end else
      if IsPrefix('TEXCOORD_', AttributeName, false) and (Geometry.TexCoordField <> nil) then
      begin
        TexCoordIndex := StrToInt(PrefixRemove('TEXCOORD_', AttributeName, false));
        TexCoord := TTextureCoordinateNode.Create;
        AccessorToVector2(Primitive.Attributes[AttributeName], TexCoord.FdPoint, false);
        SetMultiTextureCoordinate(Geometry.TexCoordField, TexCoord, TexCoordIndex);
      end else
      if (AttributeName = 'NORMAL') and (Geometry is TAbstractComposedGeometryNode) then
      begin
        Normal := TNormalNode.Create;
        AccessorToVector3(Primitive.Attributes[AttributeName], Normal.FdVector, false);
        TAbstractComposedGeometryNode(Geometry).FdNormal.Value := Normal;
      end else
      if (AttributeName = 'COLOR_0') and (Geometry.ColorField <> nil) then
      begin
        ColorAccessor := GetAccessor(Primitive.Attributes[AttributeName]);
        if ColorAccessor.Type_ = TPasGLTF.TAccessor.TType.Vec4 then
        begin
          ColorRGBA := TColorRGBANode.Create;
          ColorRGBA.Mode := cmModulate;
          AccessorToVector4(Primitive.Attributes[AttributeName], ColorRGBA.FdColor, false);
          Geometry.ColorField.Value := ColorRGBA;
        end else
        begin
          Color := TColorNode.Create;
          Color.Mode := cmModulate;
          AccessorToVector3(Primitive.Attributes[AttributeName], Color.FdColor, false);
          Geometry.ColorField.Value := Color;
        end;
      end else
      if (AttributeName = 'TANGENT') then
      begin
        { Don't do anything -- we don't store tangents now,
          but we can reliably calculate them when needed,
          so don't warn about them being unimplemented. }
      end else
      if (AttributeName = 'JOINTS_0') then
      begin
        Geometry.InternalSkinJoints := TVector4IntegerList.Create;
        AccessorToVector4Integer(Primitive.Attributes[AttributeName], Geometry.InternalSkinJoints, false);
      end else
      if (AttributeName = 'WEIGHTS_0') then
      begin
        Geometry.InternalSkinWeights := TVector4List.Create;
        AccessorToVector4(Primitive.Attributes[AttributeName], Geometry.InternalSkinWeights, false);
      end else
        WritelnLog('glTF', 'Ignoring vertex attribute ' + AttributeName + ', not implemented (for this primitive mode)');
    end;

    // determine Apperance
    if Between(Primitive.Material, 0, Appearances.Count - 1) then
      Appearance := Appearances[Primitive.Material] as TGltfAppearanceNode
    else
    begin
      Appearance := DefaultAppearance;
      if Primitive.Material <> -1 then
        WritelnWarning('glTF', 'Primitive specifies invalid material index %d',
          [Primitive.Material]);
    end;
    Shape.Appearance := Appearance;

    // apply additional TGltfAppearanceNode parameters, specified in X3D at geometry
    Geometry.Solid := not Appearance.DoubleSided;

    // add to X3D
    ParentGroup.AddChildren(Shape);
  end;

  procedure ReadMesh(const Mesh: TPasGLTF.TMesh; const ParentGroup: TAbstractX3DGroupingNode);
  var
    Primitive: TPasGLTF.TMesh.TPrimitive;
    Group: TGroupNode;
  begin
    Group := TGroupNode.Create;
    Group.X3DName := Mesh.Name;
    ParentGroup.AddChildren(Group);

    for Primitive in Mesh.Primitives do
      ReadPrimitive(Primitive, Group);
  end;

  procedure ReadMesh(const MeshIndex: Integer; const ParentGroup: TAbstractX3DGroupingNode);
  begin
    if Between(MeshIndex, 0, Document.Meshes.Count - 1) then
      ReadMesh(Document.Meshes[MeshIndex], ParentGroup)
    else
      WritelnWarning('glTF', 'Mesh index invalid: %d', [MeshIndex]);
  end;

  procedure ReadCamera(const Camera: TPasGLTF.TCamera; const ParentGroup: TAbstractX3DGroupingNode);
  var
    OrthoViewpoint: TOrthoViewpointNode;
    Viewpoint: TViewpointNode;
  begin
    if Camera.Type_ = TPasGLTF.TCamera.TCameraType.Orthographic then
    begin
      OrthoViewpoint := TOrthoViewpointNode.Create;
      OrthoViewpoint.X3DName := Camera.Name;
      ParentGroup.AddChildren(OrthoViewpoint);
    end else
    begin
      Viewpoint := TViewpointNode.Create;
      Viewpoint.X3DName := Camera.Name;
      if Camera.Perspective.YFov <> 0 then
        Viewpoint.FieldOfView := Camera.Perspective.YFov / 2;
      ParentGroup.AddChildren(Viewpoint);
    end;
  end;

  procedure ReadCamera(const CameraIndex: Integer; const ParentGroup: TAbstractX3DGroupingNode);
  begin
    if Between(CameraIndex, 0, Document.Cameras.Count - 1) then
      ReadCamera(Document.Cameras[CameraIndex], ParentGroup)
    else
      WritelnWarning('glTF', 'Camera index invalid: %d', [CameraIndex]);
  end;

  procedure ReadNode(const NodeIndex: Integer; const ParentGroup: TAbstractX3DGroupingNode);
  var
    Transform: TTransformNode;

    { Apply Node.Skin, adding a new item to SkinsToInitialize list
      and making the node collide as a box (otherwise every frame we would recalculate octree). }
    procedure ApplySkin(const Skin: TPasGLTF.TSkin);
    var
      SkinToInitialize: TSkinToInitialize;
      Shapes: TAbstractX3DGroupingNode;
      I: Integer;
      ShapeNode: TShapeNode;
    begin
      SkinToInitialize := TSkinToInitialize.Create;
      SkinsToInitialize.Add(SkinToInitialize);
      // Shapes is the group created inside ReadMesh
      Shapes := Transform.FdChildren.InternalItems.Last as TAbstractX3DGroupingNode;
      SkinToInitialize.Shapes := Shapes;
      SkinToInitialize.ShapesParent := Transform;
      SkinToInitialize.Skin := Skin;

      { Make shapes collide as simple boxes.
        We don't want to recalculate octree of their triangles each frame,
        and their boxes are easy, since we fill shape's bbox. }
      for I := 0 to Shapes.FdChildren.Count - 1 do
        if Shapes.FdChildren[I] is TShapeNode then
        begin
          ShapeNode := TShapeNode(Shapes.FdChildren[I]);
          ShapeNode.Collision := scBox;
        end;
    end;

  var
    Node: TPasGLTF.TNode;
    NodeMatrix: TMatrix4;
    Translation, Scale: TVector3;
    Rotation: TVector4;
    ChildNodeIndex: Integer;
  begin
    if Between(NodeIndex, 0, Document.Nodes.Count - 1) then
    begin
      Node := Document.Nodes[NodeIndex];
      NodeMatrix := Matrix4FromGltf(Node.Matrix);

      if not TMatrix4.PerfectlyEquals(NodeMatrix, TMatrix4.Identity) then
      begin
        MatrixDecompose(NodeMatrix, Translation, Rotation, Scale);
      end else
      begin
        Translation := Vector3FromGltf(Node.Translation);
        Rotation := RotationFromGltf(Node.Rotation);
        Scale := Vector3FromGltf(Node.Scale);
      end;

      Transform := TTransformNode.Create;
      Transform.X3DName := Node.Name;
      { Assign name to more easily recognize this in X3D output. }
      if Transform.X3DName = '' then
        Transform.X3DName := 'Node' + IntToStr(NodeIndex);
      Transform.Translation := Translation;
      Transform.Rotation := Rotation;
      Transform.Scale := Scale;
      ParentGroup.AddChildren(Transform);

      if Node.Mesh <> -1 then
      begin
        ReadMesh(Node.Mesh, Transform);

        if Node.Skin <> -1 then
        begin
          if Between(Node.Skin, 0, Document.Skins.Count - 1) then
            ApplySkin(Document.Skins[Node.Skin])
          else
            WritelnWarning('glTF', 'Skin index invalid: %d', [Node.Skin]);
        end;
      end;

      if Node.Camera <> -1 then
        ReadCamera(Node.Camera, Transform);

      for ChildNodeIndex in Node.Children do
        ReadNode(ChildNodeIndex, Transform);

      // add to Nodes list
      Nodes.Count := Max(Nodes.Count, NodeIndex + 1);
      if Nodes[NodeIndex] <> nil then
        WritelnWarning('glTF', 'Node %d read multiple times (impossible if glTF is a strict tree)', [NodeIndex])
      else
        Nodes[NodeIndex] := Transform;
    end else
      WritelnWarning('glTF', 'Node index invalid: %d', [NodeIndex]);
  end;

  procedure ReadScene(const SceneIndex: Integer; const ParentGroup: TAbstractX3DGroupingNode);
  var
    Scene: TPasGLTF.TScene;
    NodeIndex: Integer;
  begin
    if Between(SceneIndex, 0, Document.Scenes.Count - 1) then
    begin
      Scene := Document.Scenes[SceneIndex];
      for NodeIndex in Scene.Nodes do
        ReadNode(NodeIndex, ParentGroup);
      AnimationSampler.TransformNodesRoots := Scene.Nodes;
    end else
      WritelnWarning('glTF', 'Scene index invalid: %d', [SceneIndex]);
  end;

  function ReadSampler(const Sampler: TPasGLTF.TAnimation.TSampler;
    const Node: TTransformNode;
    const Path: TGltfSamplerPath;
    const TimeSensor: TTimeSensorNode;
    const ParentGroup: TAbstractX3DGroupingNode;
    out Duration: TFloatTime): TAbstractInterpolatorNode;
  var
    InterpolatePosition: TPositionInterpolatorNode;
    InterpolateOrientation: TOrientationInterpolatorNode;
    Interpolator: TAbstractInterpolatorNode;
    Route: TX3DRoute;
    InterpolatorOutputEvent: TX3DEvent;
    TargetField: TX3DField;
    I: Integer;
  begin
    case Path of
      gsTranslation, gsScale:
        begin
          InterpolatePosition := TPositionInterpolatorNode.Create;
          Interpolator := InterpolatePosition;
          InterpolatorOutputEvent := InterpolatePosition.EventValue_changed;
          AccessorToVector3(Sampler.Output, InterpolatePosition.FdKeyValue, false);
          case Path of
            gsTranslation: TargetField := Node.FdTranslation;
            gsScale      : TargetField := Node.FdScale;
            else raise EInternalError.Create('ReadSampler vector3 - Path?');
          end;
        end;
      gsRotation:
        begin
          InterpolateOrientation := TOrientationInterpolatorNode.Create;
          Interpolator := InterpolateOrientation;
          InterpolatorOutputEvent := InterpolateOrientation.EventValue_changed;
          AccessorToRotation(Sampler.Output, InterpolateOrientation.FdKeyValue, false);
          TargetField := Node.FdRotation;
        end;
      {$ifndef COMPILER_CASE_ANALYSIS}
      else raise EInternalError.Create('ReadSampler - Path?');
      {$endif}
    end;

    Interpolator.X3DName := 'Animate_' + TargetField.X3DName + '_' + TimeSensor.X3DName;

    AccessorToFloat(Sampler.Input, Interpolator.FdKey, false);
    if Interpolator.FdKey.Count <> 0 then
      Duration := Interpolator.FdKey.Items.Last
    else
      Duration := 0;

    ParentGroup.AddChildren(Interpolator);

    Route := TX3DRoute.Create;
    Route.SetSourceDirectly(TimeSensor.EventFraction_changed);
    Route.SetDestinationDirectly(Interpolator.EventSet_fraction);
    ParentGroup.AddRoute(Route);

    Route := TX3DRoute.Create;
    Route.SetSourceDirectly(InterpolatorOutputEvent);
    Route.SetDestinationDirectly(TargetField);
    ParentGroup.AddRoute(Route);

    Result := Interpolator;

    // take into account Interpolation
    case Sampler.Interpolation of
      TPasGLTF.TAnimation.TSampler.TSamplerType.Linear: ; // nothing to do
      TPasGLTF.TAnimation.TSampler.TSamplerType.Step:
        begin
          WritelnWarning('Animation interpolation Step not supported now, will be Linear');
        end;
      TPasGLTF.TAnimation.TSampler.TSamplerType.CubicSpline:
        begin
          WritelnWarning('Animation interpolation "CubicSpline" not supported yet, approximating by "Linear"');
          case Path of
            gsTranslation, gsScale:
              begin
                if InterpolatePosition.FdKeyValue.Count <>
                   InterpolatePosition.FdKey.Count * 3 then
                begin
                  WritelnWarning('For "CubicSpline", expected 3 output values for each input time, got %d for %d', [
                    InterpolatePosition.FdKeyValue.Count,
                    InterpolatePosition.FdKey.Count
                  ]);
                  Exit;
                end;
                for I := 0 to InterpolatePosition.FdKeyValue.Count div 3 - 1 do
                  InterpolatePosition.FdKeyValue.Items[I] :=
                    InterpolatePosition.FdKeyValue.Items[3 * I + 1];
                InterpolatePosition.FdKeyValue.Count := InterpolatePosition.FdKeyValue.Count div 3;
              end;
            gsRotation:
              begin
                if InterpolateOrientation.FdKeyValue.Count <>
                   InterpolateOrientation.FdKey.Count * 3 then
                begin
                  WritelnWarning('For "CubicSpline", expected 3 output values for each input time, got %d for %d', [
                    InterpolateOrientation.FdKeyValue.Count,
                    InterpolateOrientation.FdKey.Count
                  ]);
                  Exit;
                end;
                for I := 0 to InterpolateOrientation.FdKeyValue.Count div 3 - 1 do
                  InterpolateOrientation.FdKeyValue.Items[I] :=
                    InterpolateOrientation.FdKeyValue.Items[3 * I + 1];
                InterpolateOrientation.FdKeyValue.Count := InterpolateOrientation.FdKeyValue.Count div 3;
              end;
            {$ifndef COMPILER_CASE_ANALYSIS}
            else raise EInternalError.Create('ReadSampler - Path?');
            {$endif}
          end;
        end;
      {$ifndef COMPILER_CASE_ANALYSIS}
      else
        begin
          WritelnWarning('Given animation interpolation is not supported');
        end;
      {$endif}
    end;
  end;

  procedure ReadAnimation(const Animation: TPasGLTF.TAnimation; const ParentGroup: TAbstractX3DGroupingNode);
  var
    TimeSensor: TTimeSensorNode;
    Channel: TPasGLTF.TAnimation.TChannel;
    Sampler: TPasGLTF.TAnimation.TSampler;
    Node: TTransformNode;
    Duration, MaxDuration: TFloatTime;
    Interpolator: TAbstractInterpolatorNode;
    NodeIndex, I: Integer;
    Anim: TAnimation;
    InterpolatorRec: TInterpolator;
    Path: TGltfSamplerPath;
  begin
    Anim := TAnimation.Create;
    Animations.Add(Anim);

    TimeSensor := TTimeSensorNode.Create;
    if Animation.Name = '' then
      { Needs a name, otherwise TCastleSceneCore.AnimationsList would ignore it. }
      TimeSensor.X3DName := 'unnamed'
    else
      TimeSensor.X3DName := Animation.Name;
    ParentGroup.AddChildren(TimeSensor);
    Anim.TimeSensor := TimeSensor;

    MaxDuration := 0;
    for Channel in Animation.Channels do
    begin
      NodeIndex := Channel.Target.Node;

      // glTF spec says "When node isn't defined, channel should be ignored"
      if NodeIndex = -1 then
        Continue;

      if not (Between(NodeIndex, 0, Nodes.Count - 1) and (Nodes[NodeIndex] <> nil)) then
      begin
        WritelnWarning('Node index %d indicated by animation %s was not imported', [
          NodeIndex,
          TimeSensor.X3DName
        ]);
        Continue;
      end;

      Node := Nodes[NodeIndex] as TTransformNode;

      // read Sampler
      if not Between(Channel.Sampler, 0, Animation.Samplers.Count - 1) then
      begin
        WritelnWarning('Invalid animation "%s" sampler index %d', [
          TimeSensor.X3DName,
          Channel.Sampler
        ]);
        Continue;
      end;

      Sampler := Animation.Samplers[Channel.Sampler];

      // read channel Path
      case Channel.Target.Path of
        'translation': Path := gsTranslation;
        'rotation'   : Path := gsRotation;
        'scale'      : Path := gsScale;
        else
          begin
            WritelnWarning('Animating "%s" not supported', [Channel.Target.Path]);
            Continue;
          end;
      end;

      // call ReadSampler with all information
      Interpolator := ReadSampler(Sampler, Node, Path, TimeSensor, ParentGroup, Duration);

      // extend Anim.Interpolators list
      InterpolatorRec.Node := Interpolator;
      InterpolatorRec.Target := Node;
      InterpolatorRec.Path := Path;
      Anim.Interpolators.Add(InterpolatorRec);

      MaxDuration := Max(MaxDuration, Duration);
    end;

    // adjust TimeSensor duration, scale the keys in all Interpolators to be in 0..1 range
    if MaxDuration <> 0 then
    begin
      TimeSensor.CycleInterval := MaxDuration;
      for I := 0 to Anim.Interpolators.Count - 1 do
      begin
        Interpolator := Anim.Interpolators[I].Node;
        Interpolator.FdKey.Items.MultiplyAll(1 / MaxDuration);
      end;
    end;
  end;

  { Gather all key times (in 0..1 range) from Interpolators, place them in AllKeys.
    If you have animation that uses multiple interpolators,
    then this routine calculates *all* key points within this animation. }
  procedure GatherAnimationKeysToSample(const AllKeys: TSingleList;
    const Interpolators: TInterpolatorList);
  var
    I: Integer;
    Interpolator: TAbstractInterpolatorNode;
  begin
    AllKeys.Clear;
    for I := 0 to Interpolators.Count - 1 do
    begin
      Interpolator := Interpolators[I].Node;
      AllKeys.AddRange(Interpolator.FdKey.Items);
    end;
    AllKeys.SortAndRemoveDuplicates;
  end;

  { Sample animation Anim at time TimeFraction (in 0..1 range)
    to determine how does a skin look like at this moment of time.
    OriginalCoords contains original (not animated) coords.
    To the AnimatedCoords, we will add OriginalCoords.Count vertexes.

    We also add to AnimatedNormals if they are <> nil.
    Both OriginalNormals and AnimatedNormals must be nil or both must be <> nil. }
  procedure SampleSkinAnimation(const Anim: TAnimation;
    const TimeFraction: Single;
    const OriginalCoords, AnimatedCoords: TVector3List;
    const OriginalNormals, AnimatedNormals: TVector3List;
    const Joints: TX3DNodeList; const JointsGltf: TPasGLTF.TSkin.TJoints;
    const InverseBindMatrices: TMatrix4List;
    const SkeletonRootIndex: Integer;
    const MeshJoints: TVector4IntegerList;
    const MeshWeights: TVector4List);
  var
    I: Integer;
    SkinMatrix, SkeletonRootInverse: TMatrix4;
    VertexJoints: TVector4Integer;
    VertexWeights: TVector4;
  begin
    Assert((AnimatedNormals = nil) = (OriginalNormals = nil));
    Assert((OriginalNormals = nil) or (OriginalNormals.Count = OriginalCoords.Count));

    AnimationSampler.Animation := Anim;
    AnimationSampler.SetTime(TimeFraction);

    if SkeletonRootIndex <> -1 then
      SkeletonRootInverse := AnimationSampler.TransformMatrixInverse[SkeletonRootIndex]
    else
      SkeletonRootInverse := TMatrix4.Identity;

    { For each Joint, we calculate JointMatrix following
      https://www.slideshare.net/Khronos_Group/gltf-20-reference-guide }
    for I := 0 to Joints.Count - 1 do
      JointMatrix[I] := SkeletonRootInverse *
        AnimationSampler.TransformMatrix[JointsGltf[I]] *
        InverseBindMatrices[I];

    { For each vertex, calculate SkinMatrix as linear combination of JointMatrix[...]
      for all joints indicated by MeshJoints values for this vertex.
      TODO: Support JOINTS_1, WEIGHTS_1 etc. }
    for I := 0 to OriginalCoords.Count - 1 do
    begin
      VertexWeights := MeshWeights[I];
      VertexJoints := MeshJoints[I];
      if VertexWeights.IsPerfectlyZero then
      begin
        { Happens with glTF files generated by Blender.
          This is not correct (glTF spec says that weights should sum to 1.0).
          Solution that works: Transform it with weight 1 by the joint number 0
          (relying that Blender put root joint at this position). See
          https://github.com/KhronosGroup/glTF/issues/1213
          https://github.com/KhronosGroup/glTF-Blender-IO/issues/308
          https://github.com/KhronosGroup/glTF-Blender-IO/issues/308#issuecomment-531355129
            """it's not exactly a satisfying fix, but in practice using 1, 0, 0, 0 when the weights would otherwise be zero has avoided these issues in threejs."""
          https://github.com/KhronosGroup/glTF/pull/1352
          https://github.com/Franck-Dernoncourt/NeuroNER/issues/91 }
        SkinMatrix := JointMatrix.List^[0];
      end else
      begin
        SkinMatrix :=
          JointMatrix.List^[VertexJoints.Data[0]] * VertexWeights.Data[0] +
          JointMatrix.List^[VertexJoints.Data[1]] * VertexWeights.Data[1] +
          JointMatrix.List^[VertexJoints.Data[2]] * VertexWeights.Data[2] +
          JointMatrix.List^[VertexJoints.Data[3]] * VertexWeights.Data[3];
      end;
      AnimatedCoords.Add(SkinMatrix.MultPoint(OriginalCoords[I]));
      if AnimatedNormals <> nil then
        AnimatedNormals.Add(SkinMatrix.MultDirection(OriginalNormals[I]));
    end;
  end;

  { When animation TimeSensor starts, set Shape.BBox using X3D routes. }
  procedure SetBBoxWhenAnimationStarts(const TimeSensor: TTimeSensorNode;
    const Shape: TShapeNode; const BBox: TBox3D);
  var
    ValueTrigger: TValueTriggerNode;
    Center, Size: TVector3;
    F: TX3DField;
  begin
    BBox.ToCenterSize(Center, Size);

    F := TSFVec3f.Create(nil, true, 'bboxCenter', Center);
    ValueTrigger := TValueTriggerNode.Create;
    ValueTrigger.AddCustomField(F);
    Shape.AddRoute(TimeSensor.EventIsActive, ValueTrigger.EventTrigger);
    Shape.AddRoute(F, Shape.FdBboxCenter);

    F := TSFVec3f.Create(nil, true, 'bboxSize', Size);
    ValueTrigger := TValueTriggerNode.Create;
    ValueTrigger.AddCustomField(F);
    Shape.AddRoute(TimeSensor.EventIsActive, ValueTrigger.EventTrigger);
    Shape.AddRoute(F, Shape.FdBboxSize);
  end;

  { Calculate skin interpolator nodes to deform this one shape.

    Note that ParentGroup can be really any grouping node,
    we add there only interpolators and routes, it doesn't matter where this node is. }
  procedure CalculateSkinInterpolators(const Shape: TShapeNode;
    const Joints: TX3DNodeList; const JointsGltf: TPasGLTF.TSkin.TJoints;
    const InverseBindMatrices: TMatrix4List;
    const SkeletonRoot: TAbstractX3DGroupingNode; const SkeletonRootIndex: Integer;
    const ParentGroup: TAbstractX3DGroupingNode);
  var
    CoordField: TSFNode;
    Coord: TCoordinateNode;
    Normal: TNormalNode;
    Anim: TAnimation;
    CoordInterpolator: TCoordinateInterpolatorNode;
    NormalInterpolator: TCoordinateInterpolatorNode;
    I: Integer;
    OriginalNormals, AnimatedNormals: TVector3List;
  begin
    CoordField := Shape.Geometry.CoordField;
    if CoordField = nil then
    begin
      WritelnWarning('Cannot animate using skin geometry %s, it does not have coordinates', [
        Shape.Geometry.NiceName
      ]);
      Exit;
    end;

    if not (CoordField.Value is TCoordinateNode) then
    begin
      WritelnWarning('Cannot animate using skin geometry %s, the coordinates are not expressed as Coordinate node', [
        Shape.Geometry.NiceName
      ]);
      Exit;
    end;
    Coord := CoordField.Value as TCoordinateNode;

    Normal := nil;
    if (Shape.Geometry.NormalField <> nil) and
       (Shape.Geometry.NormalField.Value is TNormalNode) then
    begin
      Normal := TNormalNode(Shape.Geometry.NormalField.Value);
      // SampleSkinAnimation assumes that normals and coords counts are equal
      if Normal.FdVector.Count <> Coord.FdPoint.Count then
      begin
        WritelnWarning('When animating using skin geometry %s, coords and normals counts different', [
          Shape.Geometry.NiceName
        ]);
        Normal := nil;
      end;
    end;

    if (Shape.Geometry.InternalSkinJoints = nil) or
       (Shape.Geometry.InternalSkinWeights = nil) then
    begin
      WritelnWarning('Cannot animate using skin geometry %s, no JOINTS_0 and WEIGHTS_0 information in the mesh', [
        Shape.Geometry.NiceName
      ]);
      Exit;
    end;

    for Anim in Animations do
    begin
      CoordInterpolator := TCoordinateInterpolatorNode.Create;
      CoordInterpolator.X3DName := 'SkinCoordInterpolator_' + Anim.TimeSensor.X3DName;
      GatherAnimationKeysToSample(CoordInterpolator.FdKey.Items, Anim.Interpolators);

      ParentGroup.AddChildren(CoordInterpolator);
      ParentGroup.AddRoute(Anim.TimeSensor.EventFraction_changed, CoordInterpolator.EventSet_fraction);
      ParentGroup.AddRoute(CoordInterpolator.EventValue_changed, Coord.FdPoint);

      if Normal <> nil then
      begin
        NormalInterpolator := TCoordinateInterpolatorNode.Create;
        NormalInterpolator.X3DName := 'SkinNormalInterpolator_' + Anim.TimeSensor.X3DName;
        //GatherAnimationKeysToSample(NormalInterpolator.FdKey.Items, Anim.Interpolators);
        // faster:
        NormalInterpolator.FdKey.Assign(CoordInterpolator.FdKey);

        ParentGroup.AddChildren(NormalInterpolator);
        ParentGroup.AddRoute(Anim.TimeSensor.EventFraction_changed, NormalInterpolator.EventSet_fraction);
        ParentGroup.AddRoute(NormalInterpolator.EventValue_changed, Normal.FdVector);

        OriginalNormals := Normal.FdVector.Items;
        AnimatedNormals := NormalInterpolator.FdKeyValue.Items;
      end else
      begin
        OriginalNormals := nil;
        AnimatedNormals := nil;
      end;

      for I := 0 to CoordInterpolator.FdKey.Items.Count - 1 do
      begin
        SampleSkinAnimation(Anim, CoordInterpolator.FdKey.Items[I],
          Coord.FdPoint.Items, CoordInterpolator.FdKeyValue.Items,
          OriginalNormals, AnimatedNormals,
          Joints, JointsGltf, InverseBindMatrices,
          SkeletonRootIndex,
          Shape.Geometry.InternalSkinJoints,
          Shape.Geometry.InternalSkinWeights);
      end;

      { We want to use Shape.BBox for optimization (to avoid recalculating bbox).
        Simple version:

          Shape.BBox := Shape.BBox + TBox3D.FromPoints(CoordInterpolator.FdKeyValue.Items);

        But it's more efficient to set bbox for specific animation
        once the animation starts.
        It also looks a bit more intuitive when you view bbox
        (otherwise you would see a large bbox accounting for *all* animations,
        but with mesh transformed with current animation, testcase: Bee, Monster).

        This matters, because bbox is also used for collisions.
        E.g. knight in fps_game when Walking should not have huge bbox
        because of Dying animation. }
      SetBBoxWhenAnimationStarts(Anim.TimeSensor, Shape,
        TBox3D.FromPoints(CoordInterpolator.FdKeyValue.Items));
    end;
  end;

  { Apply Skin to deform shapes list. }
  procedure ReadSkin(const SkinToInitialize: TSkinToInitialize;
    const ParentGroup: TAbstractX3DGroupingNode);
  var
    SkeletonRootIndex: Integer;
    SkeletonRoot: TAbstractX3DGroupingNode;
    Joints: TX3DNodeList;
    InverseBindMatrices: TMatrix4List;
    I: Integer;
    Skin: TPasGLTF.TSkin;
    Shapes: TAbstractX3DGroupingNode;
    ShapeNode: TShapeNode;
  begin
    Skin := SkinToInitialize.Skin;
    Shapes := SkinToInitialize.Shapes;

    SkeletonRootIndex := Skin.Skeleton;
    if SkeletonRootIndex = -1 then
      SkeletonRoot := Result // root node created by LoadGltf
    else
    begin
      if not Between(SkeletonRootIndex, 0, Nodes.Count - 1) then
      begin
        WritelnWarning('Skin "%s" specifies invalid skeleton root node index %d', [
          Skin.Name,
          SkeletonRootIndex
        ]);
        Exit;
      end;
      SkeletonRoot := Nodes[SkeletonRootIndex] as TAbstractX3DGroupingNode;
    end;

    // first nil local variables, to reliably do try..finally that includes them all
    Joints := nil;
    InverseBindMatrices := nil;

    try
      Joints := TX3DNodeList.Create(false);
      Joints.Count := Skin.Joints.Count;
      for I := 0 to Skin.Joints.Count - 1 do
      begin
        if not Between(Skin.Joints[I], 0, Nodes.Count - 1) then
        begin
          WritelnWarning('Skin "%s" specifies invalid joint index %d', [
            Skin.Name,
            Skin.Joints[I]
          ]);
          Exit;
        end;
        Joints[I] := Nodes[Skin.Joints[I]];
      end;

      InverseBindMatrices := TMatrix4List.Create;
      AccessorToMatrix4(Skin.InverseBindMatrices, InverseBindMatrices, false);

      if Joints.Count <> InverseBindMatrices.Count then
      begin
        WritelnWarning('Joints and InverseBindMatrices counts differ for skin "%s": %d and %d', [
          Skin.Name,
          Joints.Count,
          InverseBindMatrices.Count
        ]);
        Exit;
      end;

      JointMatrix.Count := Joints.Count;

      { To satisfy glTF requirements
        """
        Client implementations should apply only the transform of the skeleton root
        node to the skinned mesh while ignoring the transform of the skinned mesh node.
        """
        Just reparent the meshes under skeleton root.

        Testcase: demo-models/blender/skinned_animation/skinned_anim.glb . }
      if SkinToInitialize.ShapesParent <> SkeletonRoot then
      begin
        SkeletonRoot.AddChildren(Shapes);
        SkinToInitialize.ShapesParent.RemoveChildren(Shapes);
        SkinToInitialize.ShapesParent := SkeletonRoot;
      end;

      for I := 0 to Shapes.FdChildren.Count - 1 do
        if Shapes.FdChildren[I] is TShapeNode then
        begin
          ShapeNode := TShapeNode(Shapes.FdChildren[I]);
          CalculateSkinInterpolators(ShapeNode,
            Joints, Skin.Joints, InverseBindMatrices,
            SkeletonRoot, SkeletonRootIndex, ParentGroup);
        end;
    finally
      FreeAndNil(Joints);
      FreeAndNil(InverseBindMatrices);
    end;
  end;

  { Read glTF skins, which result in CoordinateInterpolator nodes
    attached to shapes.
    Must be called after Nodes and SkinsToInitialize are ready, so after ReadNodes. }
  procedure ReadSkins(const ParentGroup: TAbstractX3DGroupingNode);
  var
    SkinToInitialize: TSkinToInitialize;
  begin
    // one-time initialization of structures to process skin
    AnimationSampler.TransformNodes := Nodes;
    AnimationSampler.TransformNodesGltf := Document.Nodes;

    for SkinToInitialize in SkinsToInitialize do
      ReadSkin(SkinToInitialize, ParentGroup);
  end;

var
  Material: TPasGLTF.TMaterial;
  Animation: TPasGLTF.TAnimation;
begin
  { Make absolute URL.

    This also makes the later Document.RootPath calculation correct.
    Otherwise "InclPathDelim(ExtractFilePath(URIToFilenameSafe('my_file.gtlf')))"
    would result in '/' (accidentally making all TPasGLTF.TImage.URI values
    relative to root directory on Unix). This was reproducible doing
    "view3dscene my_file.gtlf" on the command-line. }
  BaseUrl := AbsoluteURI(URL);

  Result := TX3DRootNode.Create('', BaseUrl);
  try
    // Set to nil local variables, to avoid nested try..finally..end construction
    Document := nil;
    DefaultAppearance := nil;
    Appearances := nil;
    Nodes := nil;
    SkinsToInitialize := nil;
    Animations := nil;
    AnimationSampler := nil;
    JointMatrix := nil;
    try
      Document := TMyGltfDocument.Create(Stream, BaseUrl);
      SkinsToInitialize := TSkinToInitializeList.Create(true);
      Animations := TAnimationList.Create(true);
      AnimationSampler := TAnimationSampler.Create;
      JointMatrix := TMatrix4List.Create;

      ReadHeader;

      // read appearances (called "materials" in glTF; in X3D "material" is something smaller)
      DefaultAppearance := TGltfAppearanceNode.Create;
      DefaultAppearance.Material := TMaterialNode.Create;
      DefaultAppearance.DoubleSided := false;
      Appearances := TX3DNodeList.Create(false);
      for Material in Document.Materials do
        Appearances.Add(ReadAppearance(Material));

      // read main scene
      Nodes := TX3DNodeList.Create(false);
      if Document.Scene <> -1 then
        ReadScene(Document.Scene, Result)
      else
      begin
        WritelnWarning('glTF does not specify a default scene to render. We will import the 1st scene, if available.');
        ReadScene(0, Result);
      end;

      // read animations
      for Animation in Document.Animations do
        ReadAnimation(Animation, Result);
      ReadSkins(Result);
    finally
      FreeAndNil(Animations);
      FreeAndNil(SkinsToInitialize);
      FreeAndNil(AnimationSampler);
      FreeIfUnusedAndNil(DefaultAppearance);
      X3DNodeList_FreeUnusedAndNil(Appearances);
      X3DNodeList_FreeUnusedAndNil(Nodes);
      FreeAndNil(Document);
    end;
  except FreeAndNil(Result); raise end;
end;

function LoadGltf(const URL: string): TX3DRootNode;
var
  Stream: TStream;
begin
  { Using soForceMemoryStream, because PasGLTF does seeking,
    otherwise reading glTF from Android assets (TReadAssetStream) would fail. }
  Stream := Download(URL, [soForceMemoryStream]);
  try
    Result := LoadGltf(Stream, URL);
  finally FreeAndNil(Stream) end;
end;

end.
