unit BlockFolding.Settings;

// Settings of the plugin. They are global to the IDE and stored below the
// registry key of the running IDE, so each Delphi version and each registry
// profile (bds -r) keeps its own.

interface

uses System.Classes, BlockFolding.Blocks;

type
  TBlockKinds = set of TBlockKind;

  TFoldSettings = record
    Enabled: Boolean;
    // 0 means no shortcut.
    ToggleKey, OpenAllKey: TShortCut;
    // Kinds of block the "fold at cursor" command considers.
    Kinds: TBlockKinds;
    // Text the editor shows after the first line of a folded block.
    Marker: string;
    // Draw - and + in the gutter. Only done when the IDE's own code folding is
    // turned off, since otherwise the IDE draws its own.
    GutterSigns: Boolean;
    class function Defaults: TFoldSettings; static;
  end;

const
  MaxMarkerLength = 20;

function CurrentSettings: TFoldSettings;
// Stores the settings and makes them the current ones.
procedure ApplySettings(const Value: TFoldSettings);
function SettingsRegistryKey: string;

implementation

uses System.SysUtils, System.Win.Registry, System.TypInfo, Winapi.Windows, Vcl.Menus, ToolsAPI, BlockFolding.Engine;

var
  Loaded: Boolean;
  Current: TFoldSettings;

class function TFoldSettings.Defaults: TFoldSettings;
begin
  Result.Enabled := True;
  Result.ToggleKey := ShortCut(Ord('B'), [ssCtrl, ssAlt]);
  Result.OpenAllKey := ShortCut(Ord('B'), [ssCtrl, ssAlt, ssShift]);
  // Folding happens on the line of the statement; a begin..end on its own is an option.
  Result.Kinds := [Low(TBlockKind)..High(TBlockKind)] - [bkBegin];
  Result.Marker := '...';
  Result.GutterSigns := True;
end;

function SettingsRegistryKey: string;
var Services: IOTAServices;
begin
  if Supports(BorlandIDEServices, IOTAServices, Services) then
    Result := Services.GetBaseRegistryKey + '\CSCoder\BlockFolding'
  else Result := '\Software\CSCoder\BlockFolding';
end;

// Only printable ASCII, so the text is the same in every editor encoding.
function CleanMarker(const Value: string): string;
var Character: Char;
begin
  Result := '';
  for Character in Value do
    if (Character >= ' ') and (Character <= '~') and (Length(Result) < MaxMarkerLength) then Result := Result + Character;
end;

function LoadSettings: TFoldSettings;
var Registry: TRegistry; Kind: TBlockKind; Names: TStringList;
begin
  Result := TFoldSettings.Defaults;
  Registry := TRegistry.Create(KEY_READ);
  try
    Registry.RootKey := HKEY_CURRENT_USER;
    if not Registry.OpenKeyReadOnly(SettingsRegistryKey) then Exit;
    if Registry.ValueExists('Enabled') then Result.Enabled := Registry.ReadInteger('Enabled') <> 0;
    if Registry.ValueExists('ToggleKey') then Result.ToggleKey := TShortCut(Registry.ReadInteger('ToggleKey'));
    if Registry.ValueExists('OpenAllKey') then Result.OpenAllKey := TShortCut(Registry.ReadInteger('OpenAllKey'));
    if Registry.ValueExists('GutterSigns') then Result.GutterSigns := Registry.ReadInteger('GutterSigns') <> 0;
    if Registry.ValueExists('Marker') then Result.Marker := CleanMarker(Registry.ReadString('Marker'));
    if Registry.ValueExists('Kinds') then
    begin
      Names := TStringList.Create;
      try
        Names.CommaText := Registry.ReadString('Kinds');
        Result.Kinds := [];
        for Kind := Low(TBlockKind) to High(TBlockKind) do
          if Names.IndexOf(BlockKindName(Kind)) >= 0 then Include(Result.Kinds, Kind);
      finally Names.Free; end;
    end;
  finally Registry.Free; end;
end;

procedure SaveSettings(const Value: TFoldSettings);
var Registry: TRegistry; Kind: TBlockKind; Names: TStringList;
begin
  Registry := TRegistry.Create;
  try
    Registry.RootKey := HKEY_CURRENT_USER;
    if not Registry.OpenKey(SettingsRegistryKey, True) then Exit;
    Registry.WriteInteger('Enabled', Ord(Value.Enabled));
    Registry.WriteInteger('ToggleKey', Value.ToggleKey);
    Registry.WriteInteger('OpenAllKey', Value.OpenAllKey);
    Registry.WriteString('Marker', Value.Marker);
    Registry.WriteInteger('GutterSigns', Ord(Value.GutterSigns));
    Names := TStringList.Create;
    try
      for Kind := Low(TBlockKind) to High(TBlockKind) do
        if Kind in Value.Kinds then Names.Add(BlockKindName(Kind));
      Registry.WriteString('Kinds', Names.CommaText);
    finally Names.Free; end;
  finally Registry.Free; end;
end;

function CurrentSettings: TFoldSettings;
begin
  if not Loaded then
  begin
    Current := LoadSettings;
    Loaded := True;
    TFoldEngine.SetMarker(AnsiString(Current.Marker));
  end;
  Result := Current;
end;

procedure ApplySettings(const Value: TFoldSettings);
begin
  Current := Value;
  Current.Marker := CleanMarker(Value.Marker);
  Loaded := True;
  SaveSettings(Current);
  TFoldEngine.SetMarker(AnsiString(Current.Marker));
end;

end.
