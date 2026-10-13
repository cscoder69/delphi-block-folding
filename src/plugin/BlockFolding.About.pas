unit BlockFolding.About;

// The "About" window, in the pattern of the CS.Coder tools: the product, its
// licence, what it does and who makes it. It has no IDE dependency, so a test
// program can build and render it; the caller gives the colours of the IDE theme.

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.Types, System.UITypes,
  Vcl.Graphics, Vcl.Controls, Vcl.Forms, Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.ImageCollection;

type
  // The colours of the IDE theme. Everything else comes from the package itself.
  TFoldAboutInfo = record
    BackColor: TColor;   // background of a dialog
    TextColor: TColor;
    AccentColor: TColor; // highlight colour of the theme
  end;

  // Lets the caller apply the IDE theme to each window this unit opens.
  TFoldThemeProc = reference to procedure(Form: TCustomForm);

  TFoldAboutGlyph = record
    Bounds: TRect;
    Text: string;
    Height: Integer;
    Color: TColor;
  end;

  TFoldAboutForm = class(TForm)
  private
    FInfo: TFoldAboutInfo;
    FThemer: TFoldThemeProc;
    FDim, FLine, FAccent, FTile: TColor;
    FSemibold, FGlyphFont: Boolean;
    FBack: TPaintBox;
    FIcons: TImageCollection;
    FLicense: string;
    FIconRect, FBoxRect, FTileRect: TRect;
    FRules: TArray<TRect>;
    FGlyphs: TArray<TFoldAboutGlyph>;
    function P(Value: Integer): Integer;
    function NewLabel(const Text: string; X, Y, Height: Integer; Color: TColor; Semibold: Boolean = False;
      Width: Integer = 0): TLabel;
    function NewLink(const Text, Url: string; X, Y: Integer): TLabel;
    function NewButton(const Text: string; X, Y, Width: Integer; Click: TNotifyEvent): TButton;
    procedure AddRule(const R: TRect);
    procedure AddGlyph(const Glyph: string; const R: TRect; Height: Integer; Color: TColor);
    procedure Build;
    procedure BackPaint(Sender: TObject);
    procedure FormKeyPress(Sender: TObject; var Key: Char);
    procedure LinkClick(Sender: TObject);
    procedure LinkEnter(Sender: TObject);
    procedure LinkLeave(Sender: TObject);
    procedure LicenseClick(Sender: TObject);
    procedure SiteClick(Sender: TObject);
  public
    constructor CreateAbout(const Info: TFoldAboutInfo; const Themer: TFoldThemeProc);
    destructor Destroy; override;
  end;

  // A class of its own so the IDE can be told to theme it.
  TFoldLicenseForm = class(TForm);

const
  FoldDeveloper = 'CS.Coder';
  FoldSiteUrl = 'https://www.cscoder.com.br';
  FoldSiteText = 'www.cscoder.com.br';
  FoldMail = 'contato@cscoder.com.br';
  // Support and documentation: the company site, until the product has an address of its own.
  FoldSupportUrl = FoldSiteUrl;
  // Where problems are reported: the issues of the product's repository.
  FoldIssuesUrl = 'https://github.com/cscoder69/delphi-block-folding/issues';

procedure ShowFoldAbout(const Info: TFoldAboutInfo; const Themer: TFoldThemeProc);

implementation

uses Winapi.ShellAPI, System.Math, System.IOUtils, BlockFolding.Strings;

const
  FontName = 'Segoe UI';
  SemiboldName = 'Segoe UI Semibold';
  GlyphFontName = 'Segoe MDL2 Assets';
  Compatibility = 'Delphi 11, 12, 13';
  // Resources linked into the package (BlockFolding.rc).
  IconResource = 'CSFOLDICON';
  LicenseResource = 'CSFOLDLICENSE';   // LICENSE.txt, the text that counts
  SummaryResource = 'CSFOLDLICENCA';   // LICENCA.txt, the summary in Portuguese

function MixColor(A, B: TColor; PercentA: Integer): TColor;
var CA, CB: TColor;
begin
  CA := ColorToRGB(A);
  CB := ColorToRGB(B);
  Result := RGB(
    (GetRValue(CA) * PercentA + GetRValue(CB) * (100 - PercentA)) div 100,
    (GetGValue(CA) * PercentA + GetGValue(CB) * (100 - PercentA)) div 100,
    (GetBValue(CA) * PercentA + GetBValue(CB) * (100 - PercentA)) div 100);
end;

function ResourceText(const Name: string): string;
var Stream: TResourceStream; Lines: TStringList;
begin
  Result := '';
  if FindResource(HInstance, PChar(Name), RT_RCDATA) = 0 then Exit;
  Stream := TResourceStream.Create(HInstance, Name, RT_RCDATA);
  Lines := TStringList.Create;
  try
    Lines.LoadFromStream(Stream, TEncoding.UTF8);
    Result := Lines.Text;
  finally Lines.Free; Stream.Free; end;
end;

// Both read from the package file itself, so the window never disagrees with it:
// the ProductVersion text of its version resource (it may end in a letter, which
// the four numbers cannot hold), and the day it was built.
procedure PackageVersion(out Version, BuildDay: string);
type
  TTranslation = packed record
    Language, CodePage: Word;
  end;
var FileName: array[0..MAX_PATH] of Char; Size, Dummy, Len: DWORD; Buffer: TBytes; Info: PVSFixedFileInfo;
  Translation: ^TTranslation; Text: PChar;
begin
  Version := '';
  BuildDay := '';
  if GetModuleFileName(HInstance, FileName, Length(FileName)) = 0 then Exit;
  try
    BuildDay := FormatDateTime('yyyymmdd', TFile.GetLastWriteTime(FileName));
  except
    // no date, no build line content
  end;
  Size := GetFileVersionInfoSize(FileName, Dummy);
  if Size = 0 then Exit;
  SetLength(Buffer, Size);
  if not GetFileVersionInfo(FileName, 0, Size, Buffer) then Exit;
  if VerQueryValue(Buffer, '\VarFileInfo\Translation', Pointer(Translation), Len) and (Len >= SizeOf(TTranslation)) and
    VerQueryValue(Buffer, PChar(Format('\StringFileInfo\%.4x%.4x\ProductVersion',
      [Translation.Language, Translation.CodePage])), Pointer(Text), Len) and (Len > 0) then
    Version := Trim(Text);
  if Version <> '' then Exit;
  if not VerQueryValue(Buffer, '\', Pointer(Info), Len) then Exit;
  Version := Format('%d.%d.%d.%d', [HiWord(Info.dwFileVersionMS), LoWord(Info.dwFileVersionMS),
    HiWord(Info.dwFileVersionLS), LoWord(Info.dwFileVersionLS)]);
end;

procedure OpenUrl(const Url: string);
begin
  ShellExecute(0, 'open', PChar(Url), nil, nil, SW_SHOWNORMAL);
end;

procedure ShowFoldAbout(const Info: TFoldAboutInfo; const Themer: TFoldThemeProc);
var Form: TFoldAboutForm;
begin
  Form := TFoldAboutForm.CreateAbout(Info, Themer);
  try
    if Assigned(Themer) then Themer(Form);
    Form.ShowModal;
  finally Form.Free; end;
end;

{ TFoldAboutForm }

constructor TFoldAboutForm.CreateAbout(const Info: TFoldAboutInfo; const Themer: TFoldThemeProc);
begin
  inherited CreateNew(nil);
  FInfo := Info;
  FThemer := Themer;
  // Every colour comes from the three the theme gave us.
  FDim := MixColor(FInfo.TextColor, FInfo.BackColor, 60);
  FLine := MixColor(FInfo.TextColor, FInfo.BackColor, 18);
  // The highlight colour alone can be too close to the background: pull it toward the text.
  FAccent := MixColor(FInfo.AccentColor, FInfo.TextColor, 65);
  FTile := MixColor(FInfo.AccentColor, FInfo.BackColor, 30);
  FSemibold := Screen.Fonts.IndexOf(SemiboldName) >= 0;
  FGlyphFont := Screen.Fonts.IndexOf(GlyphFontName) >= 0;
  FIcons := TImageCollection.Create(nil);
  Build;
end;

destructor TFoldAboutForm.Destroy;
begin
  inherited;
  FIcons.Free;
end;

function TFoldAboutForm.P(Value: Integer): Integer;
begin
  Result := MulDiv(Value, CurrentPPI, 96);
end;

// Positions and sizes arrive already scaled. Width > 0 wraps the text in that width.
function TFoldAboutForm.NewLabel(const Text: string; X, Y, Height: Integer; Color: TColor; Semibold: Boolean;
  Width: Integer): TLabel;
begin
  Result := TLabel.Create(Self);
  Result.Parent := Self;
  Result.ShowAccelChar := False;
  Result.Transparent := True;
  // Our own colours, not the font colour of the style.
  Result.StyleElements := Result.StyleElements - [seFont];
  Result.Font.Name := FontName;
  if Semibold then
    if FSemibold then Result.Font.Name := SemiboldName else Result.Font.Style := [fsBold];
  Result.Font.Height := -Height;
  Result.Font.Color := Color;
  Result.Left := X;
  Result.Top := Y;
  if Width > 0 then
  begin
    // Width first, with auto-size off: an empty auto-sized label collapses and
    // would then wrap the text in almost no width.
    Result.AutoSize := False;
    Result.Width := Width;
    Result.WordWrap := True;
    Result.Caption := Text;
    Result.AutoSize := True; // now only the height follows the text
  end
  else Result.Caption := Text;
end;

function TFoldAboutForm.NewLink(const Text, Url: string; X, Y: Integer): TLabel;
begin
  Result := NewLabel(Text, X, Y, P(13), FAccent);
  Result.Cursor := crHandPoint;
  Result.Hint := Url; // where it goes, shown on hover and used by the click
  Result.ShowHint := True;
  Result.OnClick := LinkClick;
  Result.OnMouseEnter := LinkEnter;
  Result.OnMouseLeave := LinkLeave;
end;

function TFoldAboutForm.NewButton(const Text: string; X, Y, Width: Integer; Click: TNotifyEvent): TButton;
begin
  Result := TButton.Create(Self);
  Result.Parent := Self;
  Result.SetBounds(X, Y, Width, P(34));
  Result.Font.Name := FontName;
  Result.Font.Height := -P(13);
  Result.Caption := Text;
  Result.OnClick := Click;
end;

procedure TFoldAboutForm.AddRule(const R: TRect);
begin
  FRules := FRules + [R];
end;

procedure TFoldAboutForm.AddGlyph(const Glyph: string; const R: TRect; Height: Integer; Color: TColor);
var G: TFoldAboutGlyph;
begin
  G.Bounds := R;
  G.Text := Glyph;
  G.Height := Height;
  G.Color := Color;
  FGlyphs := FGlyphs + [G];
end;

procedure TFoldAboutForm.Build;
const
  ClientW = 820;
  FeatureGlyphs: array[0..3] of string = (#$E8FD, #$E765, #$E718, #$E943);
  FeatureTitles: array[0..3] of TFoldStr = (sFeatBlockTitle, sFeatKeysTitle, sFeatKeepTitle, sFeatDelphiTitle);
  FeatureTexts: array[0..3] of TFoldStr = (sFeatBlockText, sFeatKeysText, sFeatKeepText, sFeatDelphiText);
  LinkGlyphs: array[0..3] of string = (#$E774, #$E715, #$E897, #$EBE8);
  RowPitch = 28;
var Lbl: TLabel; Btn: TButton; Stream: TResourceStream; Version, BuildDay: string; X, Y, I, LeftEnd, TopEnd, ColumnW: Integer;

  procedure Row(LabelX, ValueX, ValueW: Integer; const LabelText, ValueText: string);
  var Value: TLabel;
  begin
    NewLabel(LabelText, LabelX, Y, P(13), FDim);
    Value := NewLabel(ValueText, ValueX, Y, P(13), FInfo.TextColor);
    if Value.Width > ValueW then
    begin
      // A long translation: cut it at the end, whole text in the hint.
      Value.AutoSize := False;
      Value.Width := ValueW;
      Value.EllipsisPosition := epEndEllipsis;
      Value.Hint := ValueText;
      Value.ShowHint := True;
    end;
    Inc(Y, P(RowPitch));
  end;

begin
  Name := 'BlockFoldingAboutForm';
  BorderStyle := bsDialog;
  Position := poScreenCenter;
  Caption := L(sAboutCaption);
  Color := FInfo.BackColor;
  Font.Name := FontName;
  KeyPreview := True;
  OnKeyPress := FormKeyPress;
  ClientWidth := P(ClientW);

  // Rules, the licence frame, the icon and the glyphs are painted here, under the labels.
  FBack := TPaintBox.Create(Self);
  FBack.Parent := Self;
  FBack.Align := alClient;
  FBack.OnPaint := BackPaint;

  if FindResource(HInstance, IconResource, RT_RCDATA) <> 0 then
  begin
    Stream := TResourceStream.Create(HInstance, IconResource, RT_RCDATA);
    try
      FIcons.Add('icon', Stream);
    finally Stream.Free; end;
  end;
  FLicense := ResourceText(LicenseResource);
  if (FLicense <> '') and (FoldLanguage = lgPortuguese) and (ResourceText(SummaryResource) <> '') then
    FLicense := ResourceText(SummaryResource) + sLineBreak + StringOfChar('-', 60) + sLineBreak + sLineBreak + FLicense;
  PackageVersion(Version, BuildDay);

  { Left: the product }
  FIconRect := Rect(P(24), P(24), P(120), P(120));
  NewLabel(L(sTitle), P(140), P(22), P(28), FInfo.TextColor, True);
  Lbl := NewLabel(L(sAboutBy), P(140), P(62), P(15), FDim);
  NewLabel(FoldDeveloper, Lbl.BoundsRect.Right + P(5), P(62), P(15), FInfo.TextColor);
  Lbl := NewLabel(L(sAboutTagline), P(140), P(88), P(13), FDim, False, P(300));
  Y := Max(P(142), Lbl.BoundsRect.Bottom + P(14));
  AddRule(Rect(P(24), Y, P(440), Y + 1));
  Inc(Y, P(14));
  Row(P(24), P(170), P(270), L(sAboutVersionLabel), Version);
  Row(P(24), P(170), P(270), L(sAboutBuild), BuildDay);
  Row(P(24), P(170), P(270), L(sAboutCompat), Compatibility);
  LeftEnd := Y;

  { Right: the licence }
  FBoxRect := Rect(P(476), P(24), P(796), P(210));
  FTileRect := Rect(P(492), P(40), P(528), P(76));
  AddGlyph(#$E73E, FTileRect, P(18), FAccent);
  NewLabel(L(sAboutLicFree), P(540), P(38), P(15), FInfo.TextColor, True);
  NewLabel(L(sAboutLicSub), P(540), P(60), P(12), FDim);
  AddRule(Rect(P(492), P(90), P(780), P(90) + 1));
  Y := P(100);
  Row(P(492), P(640), P(140), L(sAboutLicType), L(sAboutLicTypeValue));
  Row(P(492), P(640), P(140), L(sAboutLicCommercial), L(sAboutAllowed));
  Row(P(492), P(640), P(140), L(sAboutLicSource), L(sAboutSourceOpen));
  Row(P(492), P(640), P(140), L(sAboutLicData), L(sAboutNone));
  // Side by side under the frame, short captions; the hints say what each one does.
  Btn := NewButton(L(sAboutLicenseTitle), P(476), P(222), P(154), LicenseClick);
  Btn.Name := 'btnLicense';
  Btn.Hint := L(sAboutLicenseDetails);
  Btn.ShowHint := True;
  Btn.Enabled := FLicense <> '';
  Btn := NewButton(L(sAboutUpdates), P(642), P(222), P(154), SiteClick);
  Btn.Name := 'btnUpdates';
  Btn.Hint := L(sAboutCheckUpdates);
  Btn.ShowHint := True;

  TopEnd := Max(LeftEnd, P(256)) + P(20);
  AddRule(Rect(P(458), P(24), P(458) + 1, TopEnd - P(20)));
  AddRule(Rect(P(24), TopEnd, P(796), TopEnd + 1));

  { What it does }
  Y := TopEnd + P(18);
  ColumnW := (P(ClientW) - 2 * P(24)) div 4;
  for I := 0 to 3 do
  begin
    X := P(24) + I * ColumnW;
    AddGlyph(FeatureGlyphs[I], Rect(X, Y, X + P(32), Y + P(36)), P(24), FAccent);
    NewLabel(L(FeatureTitles[I]), X + P(44), Y, P(13), FInfo.TextColor, True);
    NewLabel(L(FeatureTexts[I]), X + P(44), Y + P(20), P(12), FDim, False, ColumnW - P(52));
  end;
  Inc(Y, P(58));
  AddRule(Rect(P(24), Y, P(796), Y + 1));

  { Who makes it }
  Inc(Y, P(18));
  NewLabel(FoldDeveloper, P(24), Y, P(26), FInfo.TextColor, True);
  NewLabel(L(sAboutSlogan), P(25), Y + P(40), P(10), FDim);
  for I := 0 to High(LinkGlyphs) do
    AddGlyph(LinkGlyphs[I], Rect(P(300), Y + I * P(24), P(320), Y + I * P(24) + P(20)), P(14), FAccent);
  NewLink(FoldSiteText, FoldSiteUrl, P(328), Y + P(1));
  NewLink(FoldMail, 'mailto:' + FoldMail, P(328), Y + P(25));
  NewLink(L(sAboutSupport), FoldSupportUrl, P(328), Y + P(49));
  NewLink(L(sAboutReport), FoldIssuesUrl, P(328), Y + P(73));
  AddRule(Rect(P(560), Y, P(560) + 1, Y + P(92)));
  NewLabel(L(sAboutRights, [L(sTitle), FoldDeveloper]), P(580), Y + P(14), P(12), FDim, False, P(216));
  ClientHeight := Y + P(96) + P(20);
end;

procedure TFoldAboutForm.BackPaint(Sender: TObject);
var C: TCanvas; R: TRect; G: TFoldAboutGlyph;
begin
  C := FBack.Canvas;
  C.Brush.Style := bsSolid;
  C.Brush.Color := FLine;
  for R in FRules do C.FillRect(R);

  C.Pen.Width := 1;
  C.Pen.Color := FLine;
  C.Brush.Style := bsClear;
  C.RoundRect(FBoxRect.Left, FBoxRect.Top, FBoxRect.Right, FBoxRect.Bottom, P(10), P(10));
  C.Pen.Color := FTile;
  C.Brush.Style := bsSolid;
  C.Brush.Color := FTile;
  C.RoundRect(FTileRect.Left, FTileRect.Top, FTileRect.Right, FTileRect.Bottom, P(8), P(8));

  if FIcons.Count > 0 then FIcons.Draw(C, FIconRect, 0, True);

  if not FGlyphFont then Exit;
  C.Brush.Style := bsClear;
  C.Font.Name := GlyphFontName;
  C.Font.Style := [];
  for G in FGlyphs do
  begin
    C.Font.Height := -G.Height;
    C.Font.Color := G.Color;
    R := G.Bounds;
    DrawText(C.Handle, PChar(G.Text), Length(G.Text), R, DT_CENTER or DT_VCENTER or DT_SINGLELINE or DT_NOPREFIX);
  end;
end;

procedure TFoldAboutForm.FormKeyPress(Sender: TObject; var Key: Char);
begin
  if Key = #27 then
  begin
    Key := #0;
    ModalResult := mrCancel;
  end;
end;

procedure TFoldAboutForm.LinkClick(Sender: TObject);
begin
  OpenUrl((Sender as TLabel).Hint);
end;

procedure TFoldAboutForm.LinkEnter(Sender: TObject);
begin
  (Sender as TLabel).Font.Style := [fsUnderline];
end;

procedure TFoldAboutForm.LinkLeave(Sender: TObject);
begin
  (Sender as TLabel).Font.Style := [];
end;

// There is nowhere to ask for the latest version and the plugin never goes online
// by itself: the user's browser opens the site instead.
procedure TFoldAboutForm.SiteClick(Sender: TObject);
begin
  OpenUrl(FoldSiteUrl);
end;

procedure TFoldAboutForm.LicenseClick(Sender: TObject);
var Form: TFoldLicenseForm; Bottom: TPanel; Button: TButton; Memo: TMemo;
begin
  Form := TFoldLicenseForm.CreateNew(Self);
  try
    Form.BorderStyle := bsDialog;
    Form.Position := poOwnerFormCenter;
    Form.Caption := L(sAboutLicenseDetails);
    Form.Font.Name := FontName;
    Form.ClientWidth := P(640);
    Form.ClientHeight := P(480);

    Bottom := TPanel.Create(Form);
    Bottom.Parent := Form;
    Bottom.Align := alBottom;
    Bottom.Height := P(58);
    Bottom.BevelOuter := bvNone;
    Bottom.ShowCaption := False;
    Button := TButton.Create(Form);
    Button.Parent := Bottom;
    Button.Width := P(96);
    Button.AlignWithMargins := True;
    Button.Margins.SetBounds(0, P(12), P(16), P(14));
    Button.Align := alRight;
    Button.Caption := L(sBtnClose);
    Button.Default := True;
    Button.Cancel := True;
    Button.ModalResult := mrOk;

    Memo := TMemo.Create(Form);
    Memo.Parent := Form;
    Memo.AlignWithMargins := True;
    Memo.Margins.SetBounds(P(16), P(16), P(16), 0);
    Memo.Align := alClient;
    Memo.ReadOnly := True;
    Memo.ScrollBars := ssVertical;
    Memo.Font.Height := -P(13);
    Memo.Lines.Text := FLicense;

    if Assigned(FThemer) then FThemer(Form);
    Form.ActiveControl := Button;
    Form.ShowModal;
  finally Form.Free; end;
end;

end.
