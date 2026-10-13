program AboutPreview;

// Renders the About window of the plugin to PNG files, outside the IDE: one per
// language in light colours and one in dark colours. Usage: AboutPreview <output folder>.
// Built and run by preview-about.ps1.

{$APPTYPE CONSOLE}
{$R '..\src\plugin\BlockFolding.res'}

uses
  System.SysUtils, Vcl.Graphics, Vcl.Forms, Vcl.Imaging.pngimage,
  BlockFolding.Strings in '..\src\plugin\BlockFolding.Strings.pas',
  BlockFolding.About in '..\src\plugin\BlockFolding.About.pas';

const
  Names: array[TFoldLang] of string = ('en', 'pt', 'es', 'de', 'fr');

procedure Render(const FileName: string; Back, Text, Accent: TColor);
var Info: TFoldAboutInfo; Form: TFoldAboutForm; Bitmap: TBitmap; Png: TPngImage;
begin
  Info.BackColor := Back; Info.TextColor := Text; Info.AccentColor := Accent;
  Form := TFoldAboutForm.CreateAbout(Info, nil);
  try
    Bitmap := Form.GetFormImage;
    Png := TPngImage.Create;
    try
      Png.Assign(Bitmap);
      Png.SaveToFile(FileName);
    finally Png.Free; Bitmap.Free; end;
  finally Form.Free; end;
end;

var
  Lang: TFoldLang;
  Folder: string;

begin
  try
    Folder := IncludeTrailingPathDelimiter(ParamStr(1));
    ForceDirectories(Folder);
    for Lang := Low(TFoldLang) to High(TFoldLang) do
    begin
      SetFoldLanguage(Lang);
      Render(Folder + 'about-' + Names[Lang] + '.png', clBtnFace, clBtnText, clHighlight);
    end;
    SetFoldLanguage(lgPortuguese);
    Render(Folder + 'about-pt-escuro.png', $00382B26, $00E6E6E6, $00D77800);
    Writeln('OK');
  except
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
