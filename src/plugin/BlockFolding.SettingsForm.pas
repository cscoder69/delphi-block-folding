unit BlockFolding.SettingsForm;

// Settings window of the plugin, built in code so the package needs no form file.

interface

uses System.Classes, Vcl.Forms, Vcl.Controls, Vcl.StdCtrls, Vcl.ComCtrls, Vcl.ExtCtrls, BlockFolding.Blocks,
  BlockFolding.Settings;

type
  TFoldSettingsForm = class(TForm)
  private
    FEnabled, FSigns: TCheckBox;
    FToggleKey, FOpenAllKey: THotKey;
    FKinds: array[TBlockKind] of TCheckBox;
    FMarker: TEdit;
    FDefaults, FOK, FCancel: TButton;
    procedure Build;
    procedure DefaultsClick(Sender: TObject);
    procedure SetValue(const Value: TFoldSettings);
    function GetValue: TFoldSettings;
  public
    constructor CreateSettings(AOwner: TComponent; const Value: TFoldSettings);
    property Value: TFoldSettings read GetValue write SetValue;
  end;

// Shows the window. True when the user confirmed; Value then holds the new settings.
function EditSettings(var Value: TFoldSettings): Boolean;

implementation

uses System.SysUtils, Vcl.Graphics, ToolsAPI;

const
  KindCaptions: array[TBlockKind] of string = (
    'begin .. end isolado, na linha do begin (o begin do if e o do else dobram em separado)',
    'try .. end',
    'case .. end',
    'repeat .. until',
    'asm .. end',
    'Comandos if (com o else), for, while e with, na linha do comando');
  // The statement first, the isolated begin..end last.
  KindOrder: array[0..5] of TBlockKind = (bkStatement, bkCase, bkTry, bkRepeat, bkAsm, bkBegin);
  KindNames: array[TBlockKind] of string = ('chkBegin', 'chkTry', 'chkCase', 'chkRepeat', 'chkAsm', 'chkStatement');

function EditSettings(var Value: TFoldSettings): Boolean;
var Form: TFoldSettingsForm;
begin
  Form := TFoldSettingsForm.CreateSettings(nil, Value);
  try
    Result := Form.ShowModal = mrOk;
    if Result then Value := Form.Value;
  finally Form.Free; end;
end;

constructor TFoldSettingsForm.CreateSettings(AOwner: TComponent; const Value: TFoldSettings);
var Theming: IOTAIDEThemingServices;
begin
  inherited CreateNew(AOwner);
  Build;
  SetValue(Value);
  if Application.MainForm <> nil then ScaleForPPI(Application.MainForm.CurrentPPI);
  // Same colours as the IDE, in the dark and in the light theme.
  if Supports(BorlandIDEServices, IOTAIDEThemingServices, Theming) and Theming.IDEThemingEnabled then
  begin
    Theming.RegisterFormClass(TFoldSettingsForm);
    Theming.ApplyTheme(Self);
  end;
end;

procedure TFoldSettingsForm.Build;
const Left1 = 16; Left2 = 290; FullWidth = 548;
var Top, Slot: Integer; Kind: TBlockKind; Group: TGroupBox;

  function AddLabel(const Text: string; ATop: Integer; AParent: TWinControl = nil): TLabel;
  begin
    Result := TLabel.Create(Self);
    if AParent = nil then Result.Parent := Self else Result.Parent := AParent;
    Result.Left := Left1; Result.Top := ATop;
    Result.Caption := Text;
  end;

begin
  Name := 'BlockFoldingSettingsForm';
  Caption := 'Block Folding - Configurações';
  BorderStyle := bsDialog;
  BorderIcons := [biSystemMenu];
  Position := poScreenCenter;
  ClientWidth := FullWidth + 2 * Left1;
  ShowHint := True;

  Top := 16;
  FEnabled := TCheckBox.Create(Self);
  FEnabled.Parent := Self; FEnabled.Name := 'chkEnabled';
  FEnabled.SetBounds(Left1, Top, FullWidth, 21);
  FEnabled.Caption := 'Ativar o Block Folding';
  FEnabled.Hint := 'Desligado, os comandos não fazem nada e as dobras existentes deixam de ser mantidas.';
  Inc(Top, 36);

  AddLabel('Atalho para dobrar/abrir o bloco do cursor:', Top + 3);
  FToggleKey := THotKey.Create(Self);
  FToggleKey.Parent := Self; FToggleKey.Name := 'hkToggle';
  FToggleKey.SetBounds(Left2 + Left1, Top, FullWidth - Left2, 23);
  FToggleKey.InvalidKeys := [];
  FToggleKey.Hint := 'Clique e pressione a combinação de teclas. Backspace remove o atalho.';
  Inc(Top, 32);

  AddLabel('Atalho para abrir todas as dobras da unit:', Top + 3);
  FOpenAllKey := THotKey.Create(Self);
  FOpenAllKey.Parent := Self; FOpenAllKey.Name := 'hkOpenAll';
  FOpenAllKey.SetBounds(Left2 + Left1, Top, FullWidth - Left2, 23);
  FOpenAllKey.InvalidKeys := [];
  FOpenAllKey.Hint := FToggleKey.Hint;
  Inc(Top, 40);

  Group := TGroupBox.Create(Self);
  Group.Parent := Self;
  Group.Caption := ' O que pode ser dobrado ';
  Group.SetBounds(Left1, Top, FullWidth, 28 + 24 * (Ord(High(TBlockKind)) + 1) + 8);
  for Slot := Low(KindOrder) to High(KindOrder) do
  begin
    Kind := KindOrder[Slot];
    FKinds[Kind] := TCheckBox.Create(Self);
    FKinds[Kind].Parent := Group; FKinds[Kind].Name := KindNames[Kind];
    FKinds[Kind].SetBounds(Left1, 24 + 24 * Slot, FullWidth - 2 * Left1, 21);
    FKinds[Kind].Caption := KindCaptions[Kind];
  end;
  Inc(Top, Group.Height + 14);

  FSigns := TCheckBox.Create(Self);
  FSigns.Parent := Self; FSigns.Name := 'chkSigns';
  FSigns.SetBounds(Left1, Top, FullWidth, 21);
  FSigns.Caption := 'Mostrar os sinais − e + na margem para dobrar e abrir com o mouse';
  FSigns.Hint := 'Usado quando a dobra de código da própria IDE está desligada; com ela ligada, a IDE desenha os sinais dela.';
  Inc(Top, 30);

  AddLabel('Texto mostrado na linha dobrada:', Top + 3);
  FMarker := TEdit.Create(Self);
  FMarker.Parent := Self; FMarker.Name := 'edtMarker';
  FMarker.SetBounds(Left2 + Left1, Top, FullWidth - Left2, 23);
  FMarker.MaxLength := MaxMarkerLength;
  FMarker.Text := '';
  FMarker.Hint := 'Aparece numa caixinha depois da primeira linha do bloco dobrado. Só letras, números e sinais simples.';
  Inc(Top, 34);

  with AddLabel('As dobras valem enquanto a unit está aberta: editar antes ou depois e salvar mantém; ' +
    'fechar e reabrir a unit volta sem dobras.', Top) do
  begin
    AutoSize := False; WordWrap := True;
    SetBounds(Left1, Top, FullWidth, 32);
  end;
  Inc(Top, 46);

  FDefaults := TButton.Create(Self);
  FDefaults.Parent := Self; FDefaults.Name := 'btnDefaults';
  FDefaults.SetBounds(Left1, Top, 130, 27);
  FDefaults.Caption := 'Restaurar padrões';
  FDefaults.OnClick := DefaultsClick;

  FOK := TButton.Create(Self);
  FOK.Parent := Self; FOK.Name := 'btnOK';
  FOK.SetBounds(Left1 + FullWidth - 180, Top, 85, 27);
  FOK.Caption := 'OK';
  FOK.Default := True;
  FOK.ModalResult := mrOk;

  FCancel := TButton.Create(Self);
  FCancel.Parent := Self; FCancel.Name := 'btnCancel';
  FCancel.SetBounds(Left1 + FullWidth - 85, Top, 85, 27);
  FCancel.Caption := 'Cancelar';
  FCancel.Cancel := True;
  FCancel.ModalResult := mrCancel;

  ClientHeight := Top + 27 + 16;
end;

procedure TFoldSettingsForm.DefaultsClick(Sender: TObject);
begin
  SetValue(TFoldSettings.Defaults);
end;

procedure TFoldSettingsForm.SetValue(const Value: TFoldSettings);
var Kind: TBlockKind;
begin
  FEnabled.Checked := Value.Enabled;
  FSigns.Checked := Value.GutterSigns;
  FToggleKey.HotKey := Value.ToggleKey;
  FOpenAllKey.HotKey := Value.OpenAllKey;
  for Kind := Low(TBlockKind) to High(TBlockKind) do
    FKinds[Kind].Checked := Kind in Value.Kinds;
  FMarker.Text := Value.Marker;
end;

function TFoldSettingsForm.GetValue: TFoldSettings;
var Kind: TBlockKind;
begin
  Result.Enabled := FEnabled.Checked;
  Result.GutterSigns := FSigns.Checked;
  Result.ToggleKey := FToggleKey.HotKey;
  Result.OpenAllKey := FOpenAllKey.HotKey;
  Result.Kinds := [];
  for Kind := Low(TBlockKind) to High(TBlockKind) do
    if FKinds[Kind].Checked then Include(Result.Kinds, Kind);
  Result.Marker := FMarker.Text;
end;

end.
