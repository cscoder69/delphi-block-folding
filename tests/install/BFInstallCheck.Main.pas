unit BFInstallCheck.Main;

// Test-only: checks, from inside the IDE, a Block Folding that was put there by its
// installer. It holds no unit of the plugin, so both packages load together. It
// reports which file the IDE loaded, looks for the CS.Coder > Block Folding menu,
// folds a block of a sample unit through the menu command and opens it again.
// It only runs when BFCHECK_REPORT is set; test-install.ps1 starts the IDE with an
// isolated registry profile and ends it.

interface

procedure Register;

implementation

uses Winapi.Windows, Winapi.Messages, System.SysUtils, System.Classes, System.Rtti, Vcl.Forms, Vcl.Menus, Vcl.Controls,
  Vcl.ExtCtrls, ToolsAPI, ToolsAPI.Editor;

const
  // Names the plugin gives its menu items (BlockFolding.Register).
  RootName = 'CSCoderSharedMenu';
  BranchName = 'CSCoderBlockFoldingMenu';
  ToggleName = 'CSCoderBlockFoldingToggle';
  // A line inside the body of the if of samples\Sample.pas.
  CursorLine = 32;

type
  TCheck = class
  private
    FTimer: TTimer;
    FReport: TStringList;
    FReportFile, FSample: string;
    FStep, FTicks, FDialogs: Integer;
    FView: IOTAEditView;
    FEditor: TWinControl;
    procedure Tick(Sender: TObject);
    procedure Note(const Text: string);
    procedure Finish;
    procedure CloseDialogs;
    function MenuItem(const ItemName: string): TMenuItem;
    function Hidden: string;
    procedure Start;
    procedure Fold;
  public
    constructor Create(const ReportFile: string);
    destructor Destroy; override;
  end;

var
  Check: TCheck;
  DialogText: TStringList;

function CollectText(Window: HWND; Param: LPARAM): BOOL; stdcall;
var Text: array[0..511] of Char;
begin
  Result := True;
  if IsWindowVisible(Window) and (GetWindowText(Window, Text, Length(Text)) > 0) then DialogText.Add(Text);
end;

function FindDialog(Window: HWND; Param: LPARAM): BOOL; stdcall;
var ClassName: array[0..63] of Char;
begin
  Result := True;
  if not IsWindowVisible(Window) then Exit;
  GetClassName(Window, ClassName, Length(ClassName));
  if string(ClassName) = '#32770' then
  begin
    PHandle(Param)^ := Window;
    Result := False;
  end;
end;

constructor TCheck.Create(const ReportFile: string);
begin
  inherited Create;
  FReportFile := ReportFile;
  FSample := GetEnvironmentVariable('BFCHECK_SAMPLE');
  FReport := TStringList.Create;
  FTimer := TTimer.Create(nil);
  FTimer.Interval := 1000;
  FTimer.OnTimer := Tick;
end;

destructor TCheck.Destroy;
begin
  FTimer.Free;
  FReport.Free;
  inherited;
end;

// The report is rewritten at every line, so a run that stops half way still tells how far it went.
procedure TCheck.Note(const Text: string);
begin
  FReport.Add(Text);
  try
    FReport.SaveToFile(FReportFile, TEncoding.UTF8);
  except
  end;
end;

procedure TCheck.Finish;
begin
  FTimer.Enabled := False;
  Note('DONE');
end;

// A message box nobody would answer (a package that did not load, for one): its text
// goes to the report and it is closed.
procedure TCheck.CloseDialogs;
var Window: HWND; Caption: array[0..255] of Char;
begin
  Window := 0;
  EnumThreadWindows(MainThreadID, @FindDialog, LPARAM(@Window));
  if Window = 0 then Exit;
  Inc(FDialogs);
  DialogText := TStringList.Create;
  try
    Caption[0] := #0;
    GetWindowText(Window, Caption, Length(Caption));
    EnumChildWindows(Window, @CollectText, 0);
    Note('DIALOG | "' + Caption + '" | ' + StringReplace(Trim(DialogText.Text), sLineBreak, ' // ', [rfReplaceAll]));
  finally FreeAndNil(DialogText); end;
  if FDialogs > 10 then Finish
  else if Odd(FDialogs) then PostMessage(Window, WM_COMMAND, IDNO, 0)
  else PostMessage(Window, WM_CLOSE, 0, 0);
end;

function TCheck.MenuItem(const ItemName: string): TMenuItem;

  function Search(Parent: TMenuItem): TMenuItem;
  var I: Integer;
  begin
    for I := 0 to Parent.Count - 1 do
    begin
      if SameText(Parent[I].Name, ItemName) then Exit(Parent[I]);
      Result := Search(Parent[I]);
      if Result <> nil then Exit;
    end;
    Result := nil;
  end;

begin
  Result := Search((BorlandIDEServices as INTAServices).MainMenu.Items);
end;

// Hidden lines of the sample as ranges, "31..38"; empty when nothing is folded. Asked
// of the editor control itself, the same way for the five IDEs.
function TCheck.Hidden: string;
var Context: TRttiContext; Method, Found: TRttiMethod; Line, First, Count: Integer; IsHidden: Boolean;
begin
  Result := '';
  Found := nil;
  Context := TRttiContext.Create;
  try
    for Method in Context.GetType(FEditor.ClassType).GetMethods do
      if SameText(Method.Name, 'LineIsElided') and (Length(Method.GetParameters) = 1) then Found := Method;
    if Found = nil then Exit('?');
    Count := FView.Buffer.GetLinesInBuffer;
    First := 0;
    for Line := 1 to Count + 1 do
    begin
      IsHidden := (Line <= Count) and Found.Invoke(FEditor, [Line]).AsBoolean;
      if IsHidden and (First = 0) then First := Line;
      if not IsHidden and (First > 0) then
      begin
        Result := Trim(Result + Format(' %d..%d', [First, Line - 1]));
        First := 0;
      end;
    end;
  finally Context.Free; end;
end;

procedure TCheck.Start;
var Module: HMODULE; FileName: array[0..MAX_PATH] of Char; Root, Branch: TMenuItem; I: Integer; Items: string;
begin
  Module := GetModuleHandle('BlockFolding.bpl');
  if Module = 0 then Note('MODULE | not loaded')
  else
  begin
    GetModuleFileName(Module, FileName, Length(FileName));
    Note('MODULE | ' + FileName);
  end;
  Root := MenuItem(RootName);
  Branch := MenuItem(BranchName);
  Items := '';
  if Branch <> nil then
    for I := 0 to Branch.Count - 1 do Items := Items + '[' + StripHotkey(Branch[I].Caption) + '] ';
  Note(Format('MENU | CS.Coder: %s | Block Folding: %s | below CS.Coder: %s | items: %s', [BoolToStr(Root <> nil, True),
    BoolToStr(Branch <> nil, True), BoolToStr((Branch <> nil) and (Branch.Parent = Root), True), Trim(Items)]));
  if (Module = 0) or (Branch = nil) then begin Finish; Exit; end;
  (BorlandIDEServices as IOTAActionServices).OpenFile(FSample);
end;

procedure TCheck.Fold;
var Services: INTACodeEditorServices;
begin
  FView := (BorlandIDEServices as IOTAEditorServices).TopView;
  if (FView = nil) or not SameText(FView.Buffer.FileName, FSample) then
  begin
    Note('EDITOR | the sample unit is not the top view');
    Finish;
    Exit;
  end;
  if Supports(BorlandIDEServices, INTACodeEditorServices, Services) then FEditor := Services.GetEditorForView(FView);
  if FEditor = nil then begin Note('EDITOR | no editor control for the view'); Finish; Exit; end;
  FView.Buffer.EditPosition.Move(CursorLine, 9);
  FView.MoveViewToCursor;
  FView.Paint;
  Note('BEFORE | hidden: [' + Hidden + ']');
  MenuItem(ToggleName).Click;
end;

procedure TCheck.Tick(Sender: TObject);
begin
  try
    CloseDialogs;
    if not FTimer.Enabled then Exit;
    if (Application.MainForm = nil) or not Application.MainForm.Visible then Exit;
    Inc(FTicks);
    case FStep of
      0: if FTicks >= 8 then begin Start; FStep := 1; FTicks := 0; end;
      1: if FTicks >= 4 then begin Fold; FStep := 2; FTicks := 0; end;
      2: if FTicks >= 2 then
        begin
          Note(Format('FOLD | hidden: [%s] | cursor line: %d', [Hidden, FView.CursorPos.Line]));
          // The cursor is now on the first line of the folded block: the same command opens it.
          MenuItem(ToggleName).Click;
          FStep := 3; FTicks := 0;
        end;
      3: if FTicks >= 2 then
        begin
          Note('OPEN | hidden: [' + Hidden + ']');
          Finish;
        end;
    end;
  except
    on E: Exception do
    begin
      Note('EXCEPTION | ' + E.ClassName + ': ' + E.Message);
      Finish;
    end;
  end;
end;

procedure Register;
var ReportFile: string;
begin
  ReportFile := GetEnvironmentVariable('BFCHECK_REPORT');
  if (ReportFile <> '') and (Check = nil) then Check := TCheck.Create(ReportFile);
end;

initialization

finalization
  FreeAndNil(Check);

end.
