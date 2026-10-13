unit BlockFolding.Register;

// Commands of the plugin: the "Block Folding" branch of the CS.Coder menu and
// the keyboard shortcuts chosen in the settings.

interface

procedure Register;
// Removes the menu branch and the shortcuts. Called when the package unloads.
procedure Unregister;

const
  SharedRootName = 'CSCoderSharedMenu';
  BranchName = 'CSCoderBlockFoldingMenu';
  ToggleItemName = 'CSCoderBlockFoldingToggle';
  OpenAllItemName = 'CSCoderBlockFoldingOpenAll';
  SettingsItemName = 'CSCoderBlockFoldingSettings';
  AboutItemName = 'CSCoderBlockFoldingAbout';

implementation

uses System.SysUtils, System.Classes, Winapi.Windows, Vcl.Graphics, Vcl.Menus, Vcl.Controls, Vcl.Forms, ToolsAPI,
  BlockFolding.Manager, BlockFolding.Settings, BlockFolding.SettingsForm, BlockFolding.About;

type
  // The CS.Coder item of the main menu is shared by the CS.Coder tools and
  // belongs to the IDE: each tool owns only its own branch below it.
  TFoldCommands = class(TComponent)
  private
    FRoot, FBranch: TMenuItem;
    procedure ToggleClick(Sender: TObject);
    procedure OpenAllClick(Sender: TObject);
    procedure SettingsClick(Sender: TObject);
    procedure AboutClick(Sender: TObject);
  protected
    procedure Notification(AComponent: TComponent; Operation: TOperation); override;
  public
    constructor CreateMenu(MainMenu: TMainMenu);
    destructor Destroy; override;
  end;

  TFoldKeys = class(TNotifierObject, IOTAKeyboardBinding)
  private
    procedure ToggleKey(const Context: IOTAKeyContext; KeyCode: TShortCut; var BindingResult: TKeyBindingResult);
    procedure OpenAllKey(const Context: IOTAKeyContext; KeyCode: TShortCut; var BindingResult: TKeyBindingResult);
  public
    function GetBindingType: TBindingType;
    function GetDisplayName: string;
    function GetName: string;
    procedure BindKeyboard(const BindingServices: IOTAKeyBindingServices);
  end;

var
  Commands: TFoldCommands;
  KeysIndex: Integer = -1;

function TopView: IOTAEditView;
var Services: IOTAEditorServices;
begin
  if Supports(BorlandIDEServices, IOTAEditorServices, Services) then Result := Services.TopView else Result := nil;
end;

procedure BindKeys;
var Keyboard: IOTAKeyboardServices;
begin
  if not Supports(BorlandIDEServices, IOTAKeyboardServices, Keyboard) then Exit;
  if KeysIndex >= 0 then Keyboard.RemoveKeyboardBinding(KeysIndex);
  KeysIndex := Keyboard.AddKeyboardBinding(TFoldKeys.Create);
end;

{ TFoldCommands }

constructor TFoldCommands.CreateMenu(MainMenu: TMainMenu);
var I, Position: Integer;

  function AddItem(const ItemName, Text, HintText: string; Handler: TNotifyEvent): TMenuItem;
  begin
    Result := TMenuItem.Create(FBranch);
    // Named so the IDE shows the key binding beside the command.
    Result.Name := ItemName;
    Result.Caption := Text;
    Result.Hint := HintText;
    Result.OnClick := Handler;
    FBranch.Add(Result);
  end;

begin
  inherited Create(nil);
  if MainMenu = nil then Exit;
  for I := 0 to MainMenu.Items.Count - 1 do
    if SameText(MainMenu.Items[I].Name, SharedRootName) or
      SameText(StringReplace(MainMenu.Items[I].Caption, '&', '', [rfReplaceAll]), 'CS.Coder') then
    begin
      FRoot := MainMenu.Items[I];
      Break;
    end;
  if FRoot = nil then
  begin
    // The IDE owns the shared root, so unloading this package cannot destroy
    // the branch of another installed tool.
    FRoot := TMenuItem.Create(MainMenu);
    FRoot.Name := SharedRootName;
    FRoot.Caption := 'CS.Coder';
    MainMenu.Items.Add(FRoot);
  end;
  FRoot.FreeNotification(Self);
  FBranch := TMenuItem.Create(Self);
  FBranch.Name := BranchName;
  FBranch.Caption := 'Block Folding';
  FBranch.Hint := 'Dobra de blocos de comandos no editor e suas configurações.';
  FBranch.FreeNotification(Self);
  AddItem(ToggleItemName, 'Dobrar/abrir o bloco do cursor',
    'Dobra o bloco mais interno em volta do cursor; na linha de um bloco dobrado, abre.', ToggleClick);
  AddItem(OpenAllItemName, 'Abrir todas as dobras desta unit',
    'Abre todas as dobras feitas pelo Block Folding na unit atual.', OpenAllClick);
  AddItem('CSCoderBlockFoldingSeparator', '-', '', nil);
  AddItem(SettingsItemName, 'Configurações...', 'Atalhos, tipos de bloco e texto da linha dobrada.', SettingsClick);
  AddItem(AboutItemName, 'Sobre...', 'Versão, licença e contato', AboutClick);
  // The tools of the menu stay in alphabetical order.
  Position := 0;
  while (Position < FRoot.Count) and
    (CompareText(StringReplace(FRoot[Position].Caption, '&', '', [rfReplaceAll]), FBranch.Caption) < 0) do Inc(Position);
  FRoot.Insert(Position, FBranch);
end;

procedure TFoldCommands.Notification(AComponent: TComponent; Operation: TOperation);
begin
  inherited;
  if Operation = opRemove then
  begin
    if AComponent = FBranch then FBranch := nil;
    if AComponent = FRoot then FRoot := nil;
  end;
end;

destructor TFoldCommands.Destroy;
begin
  FreeAndNil(FBranch);
  // Never delete a root that was already there or one with other tools in it.
  if (FRoot <> nil) and (FRoot.Count = 0) and SameText(FRoot.Name, SharedRootName) then FreeAndNil(FRoot);
  inherited;
end;

procedure TFoldCommands.ToggleClick(Sender: TObject);
begin
  TFoldManager.Instance.Toggle(TopView);
end;

procedure TFoldCommands.OpenAllClick(Sender: TObject);
begin
  TFoldManager.Instance.OpenAll(TopView);
end;

procedure TFoldCommands.SettingsClick(Sender: TObject);
var Value: TFoldSettings;
begin
  Value := CurrentSettings;
  if not EditSettings(Value) then Exit;
  ApplySettings(Value);
  BindKeys;
end;

// The window takes its colours from the IDE theme, dark or light.
procedure TFoldCommands.AboutClick(Sender: TObject);
var Info: TFoldAboutInfo; Theming: IOTAIDEThemingServices;
begin
  Info.BackColor := clBtnFace;
  Info.TextColor := clBtnText;
  Info.AccentColor := clHighlight;
  if Supports(BorlandIDEServices, IOTAIDEThemingServices, Theming) and Theming.IDEThemingEnabled then
  begin
    Info.BackColor := Theming.StyleServices.GetSystemColor(clBtnFace);
    Info.TextColor := Theming.StyleServices.GetSystemColor(clBtnText);
    Info.AccentColor := Theming.StyleServices.GetSystemColor(clHighlight);
  end;
  ShowFoldAbout(Info, procedure(Form: TCustomForm)
    var Services: IOTAIDEThemingServices;
    begin
      // The IDE only themes windows of classes it was told about.
      if Supports(BorlandIDEServices, IOTAIDEThemingServices, Services) and Services.IDEThemingEnabled then
      begin
        Services.RegisterFormClass(TCustomFormClass(Form.ClassType));
        Services.ApplyTheme(Form);
      end;
    end);
end;

{ TFoldKeys }

function TFoldKeys.GetBindingType: TBindingType;
begin
  Result := btPartial;
end;

function TFoldKeys.GetDisplayName: string;
begin
  Result := 'CS.Coder Block Folding';
end;

function TFoldKeys.GetName: string;
begin
  Result := 'CSCoder.BlockFolding.Keys';
end;

procedure TFoldKeys.BindKeyboard(const BindingServices: IOTAKeyBindingServices);
var Settings: TFoldSettings;
begin
  Settings := CurrentSettings;
  if Settings.ToggleKey <> 0 then
    BindingServices.AddKeyBinding([Settings.ToggleKey], ToggleKey, nil, kfImplicitShift or kfImplicitModifier or
      kfImplicitKeypad, '', ToggleItemName);
  if Settings.OpenAllKey <> 0 then
    BindingServices.AddKeyBinding([Settings.OpenAllKey], OpenAllKey, nil, kfImplicitShift or kfImplicitModifier or
      kfImplicitKeypad, '', OpenAllItemName);
end;

procedure TFoldKeys.ToggleKey(const Context: IOTAKeyContext; KeyCode: TShortCut; var BindingResult: TKeyBindingResult);
begin
  TFoldManager.Instance.Toggle(Context.EditBuffer.TopView);
  BindingResult := krHandled;
end;

procedure TFoldKeys.OpenAllKey(const Context: IOTAKeyContext; KeyCode: TShortCut; var BindingResult: TKeyBindingResult);
begin
  TFoldManager.Instance.OpenAll(Context.EditBuffer.TopView);
  BindingResult := krHandled;
end;

procedure Register;
var Services: INTAServices;
begin
  if Commands <> nil then Exit;
  TFoldManager.Instance;
  if Supports(BorlandIDEServices, INTAServices, Services) then Commands := TFoldCommands.CreateMenu(Services.MainMenu);
  BindKeys;
end;

procedure Unregister;
var Keyboard: IOTAKeyboardServices;
begin
  if (KeysIndex >= 0) and Supports(BorlandIDEServices, IOTAKeyboardServices, Keyboard) then
    Keyboard.RemoveKeyboardBinding(KeysIndex);
  KeysIndex := -1;
  FreeAndNil(Commands);
  TFoldManager.Release;
end;

initialization

finalization
  Unregister;

end.
