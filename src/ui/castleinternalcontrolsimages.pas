{ -*- buffer-read-only: t -*- }

{ Unit automatically generated by image-to-pascal tool,
  to embed images in Pascal source code.
  @exclude (Exclude this unit from PasDoc documentation.) }
unit CastleInternalControlsImages;

interface

uses CastleImages;

function Panel: TGrayscaleAlphaImage;

function WindowDarkTransparent: TRGBAlphaImage;

function Tooltip: TRGBAlphaImage;

function TooltipRounded: TRGBAlphaImage;

function ButtonPressed: TGrayscaleAlphaImage;

function ButtonDisabled: TGrayscaleAlphaImage;

function ButtonFocused: TGrayscaleAlphaImage;

function ButtonNormal: TGrayscaleAlphaImage;

function FrameWhite: TGrayscaleAlphaImage;

function FrameWhiteBlack: TGrayscaleAlphaImage;

function FrameYellow: TRGBAlphaImage;

function FrameYellowBlack: TRGBAlphaImage;

function FrameThickWhite: TGrayscaleAlphaImage;

function FrameThickYellow: TRGBAlphaImage;

function ProgressBar: TRGBAlphaImage;

function ProgressFill: TRGBAlphaImage;

function TouchCtlInner: TRGBAlphaImage;

function TouchCtlOuter: TRGBAlphaImage;

function TouchCtlFlyInner: TRGBAlphaImage;

function TouchCtlFlyOuter: TRGBAlphaImage;

function Loading: TGrayscaleAlphaImage;

function Crosshair1: TRGBAlphaImage;

function Crosshair2: TRGBAlphaImage;

function ScrollbarSlider: TGrayscaleAlphaImage;

function Checkmark: TRGBAlphaImage;

function Disclosure: TRGBAlphaImage;

function SquareEmpty: TRGBAlphaImage;

function SquarePressedBackground: TRGBAlphaImage;

function SquareChecked: TRGBAlphaImage;

function SliderBackground: TRGBAlphaImage;

function SliderThumb: TRGBAlphaImage;

function PanelSeparator: TGrayscaleImage;

function WindowDark: TRGBImage;

function WindowGray: TRGBImage;

function ScrollbarFrame: TRGBImage;

function Edit: TRGBImage;

implementation

uses SysUtils, CastleInternalDataCompression;

{ Actual image data is included from another file, with a deliberately
  non-Pascal file extension ".image_data". This way online code analysis
  tools will NOT consider this source code as an uncommented Pascal code
  (which would be unfair --- the image data file is autogenerated
  and never supposed to be processed by a human). }
{$I castleinternalcontrolsimages.image_data}

initialization
finalization
  FreeAndNil(FPanel);
  FreeAndNil(FWindowDarkTransparent);
  FreeAndNil(FTooltip);
  FreeAndNil(FTooltipRounded);
  FreeAndNil(FButtonPressed);
  FreeAndNil(FButtonDisabled);
  FreeAndNil(FButtonFocused);
  FreeAndNil(FButtonNormal);
  FreeAndNil(FFrameWhite);
  FreeAndNil(FFrameWhiteBlack);
  FreeAndNil(FFrameYellow);
  FreeAndNil(FFrameYellowBlack);
  FreeAndNil(FFrameThickWhite);
  FreeAndNil(FFrameThickYellow);
  FreeAndNil(FProgressBar);
  FreeAndNil(FProgressFill);
  FreeAndNil(FTouchCtlInner);
  FreeAndNil(FTouchCtlOuter);
  FreeAndNil(FTouchCtlFlyInner);
  FreeAndNil(FTouchCtlFlyOuter);
  FreeAndNil(FLoading);
  FreeAndNil(FCrosshair1);
  FreeAndNil(FCrosshair2);
  FreeAndNil(FScrollbarSlider);
  FreeAndNil(FCheckmark);
  FreeAndNil(FDisclosure);
  FreeAndNil(FSquareEmpty);
  FreeAndNil(FSquarePressedBackground);
  FreeAndNil(FSquareChecked);
  FreeAndNil(FSliderBackground);
  FreeAndNil(FSliderThumb);
  FreeAndNil(FPanelSeparator);
  FreeAndNil(FWindowDark);
  FreeAndNil(FWindowGray);
  FreeAndNil(FScrollbarFrame);
  FreeAndNil(FEdit);
end.