unit BlockFolding.Manager;

// Keeps the folds the user asked for while the unit is edited. The IDE forgets a
// block it did not create whenever it parses the unit again (after an edit, a
// debugger stop, "unfold all"), so each block is followed by the line tracker of
// the ToolsAPI and, right before the editor repaints, registered again in the
// state it had. The IDE also forgets them after running a command, with no edit
// at all, so "forgotten" never means "the user opened it": the state of a block
// is read while the editor still has it. Folds live only while the unit stays open.
//
// Rule of the editor kernel, found by testing in Delphi 11, 12 and 13: a block
// must never be registered around a block that already exists, ours or the
// IDE's. Doing so breaks the kernel (access violation, or a stack overflow when
// the outer block is opened). So blocks are always registered from the outside
// in, a block is registered together with the blocks around it, and a block
// that holds a {$REGION} is refused. The body of a routine is left to the IDE's
// own folding.

interface

uses System.Classes, System.Types, System.Generics.Collections, Vcl.Controls, Vcl.ExtCtrls, Vcl.Graphics, ToolsAPI,
  ToolsAPI.Editor, BlockFolding.Blocks;

type
  TFoldItem = record
    // Key of the two lines in the line tracker: Id for the first, Id + 1 for the last.
    Id: Integer;
    First, Last: Integer;
    Collapsed: Boolean;
  end;

  TFileFolds = class
  public
    Items: TList<TFoldItem>;
    // First line -> last line of every block of the unit that can be folded, as of ParsedAt.
    Starts: TDictionary<Integer, Integer>;
    ParsedAt: UInt64;
    constructor Create;
    destructor Destroy; override;
  end;

  // Where things are in an editor, as of its last repaint.
  TEditorLayout = record
    CodeLeft, LineHeight, SignSize: Integer;
    // Logical line shown on each screen row.
    Rows: TArray<Integer>;
    FileName: string;
  end;

  TFoldManager = class
  private
    FLayouts: TDictionary<TWinControl, TEditorLayout>;
    FFiles: TObjectDictionary<string, TFileFolds>;
    FServices: INTACodeEditorServices;
    FNotifier: Integer;
    FNextId: Integer;
    FBusy: Boolean;
    // The sign the left button went down on, and what its block was then; nil when none.
    FDownEditor: TWinControl;
    FDownLine: Integer;
    FDownFolded: Boolean;
    FReapplied, FPasses, FErrors: Integer;
    FLastPassMs, FMaxPassMs: Int64;
    FLastError: string;
    FLog: TStringList;
    // Diagnosis: what the editor reports is written to a text file whenever it changes.
    FDiagTimer: TTimer;
    FDiagFile, FDiagLast: string;
    procedure DiagTick(Sender: TObject);
    procedure DiagWrite(const Text: string);
    procedure EditorBeginPaint(const Editor: TWinControl; const ForceFullRepaint: Boolean);
    function FoldsOf(const FileName: string; CreateIt: Boolean): TFileFolds;
    procedure Sync(Editor: TWinControl; const View: IOTAEditView);
    procedure Forget(const Tracker: IOTAEditLineTracker; Id: Integer);
    procedure Log(const Text: string);
    procedure UpdateLayout(Editor: TWinControl; const View: IOTAEditView);
    procedure EditorPaintGutter(const Rect: TRect; const Stage: TPaintGutterStage; const BeforeEvent: Boolean;
      var AllowDefaultPainting: Boolean; const Context: INTACodeEditorPaintContext);
    function SignsActive(Editor: TWinControl): Boolean;
    function SignLineAt(Editor: TWinControl; X, Y: Integer): Integer;
    function EnsureRegistered(Editor: TWinControl; Lines: TStrings; const Blocks: TArray<TBlock>; Index: Integer): Boolean;
    function FoldBlock(Editor: TWinControl; const View: IOTAEditView; Lines: TStrings; const Blocks: TArray<TBlock>;
      Index: Integer): Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    class function Instance: TFoldManager;
    class procedure Release;
    // Folds the innermost block around the cursor, or opens it when it is folded.
    // Returns what was done; the same text goes to the status bar of the editor
    // when nothing could be folded.
    function Toggle(const View: IOTAEditView): string;
    // Folds the block that spans exactly these lines. Lines may hold the text of
    // the buffer, to save reading it.
    function FoldRange(const View: IOTAEditView; First, Last: Integer; Lines: TStrings = nil): Boolean;
    // Opens every fold made here in the unit of the view, and stops keeping them.
    procedure OpenAll(const View: IOTAEditView);
    // Folds or opens the block that starts on the line; what a click on its sign does.
    // Fold says what the block must end up as; the IDE may already have opened it.
    procedure ToggleLine(const View: IOTAEditView; Line: Integer; Fold: Boolean);
    // A mouse button went down in an editor; True when it was on one of our signs.
    function MouseDown(Editor: TWinControl; X, Y: Integer): Boolean;
    // The button was released; a press on a sign takes effect here.
    procedure MouseUp(Editor: TWinControl; X, Y: Integer);
    function Items(const FileName: string): TArray<TFoldItem>;
    // What happened since the last call, one event per line; for diagnosis.
    function TakeLog: string;
    procedure ResetStatistics;
    property Reapplied: Integer read FReapplied;
    property Passes: Integer read FPasses;
    property MaxPassMs: Int64 read FMaxPassMs;
    property Errors: Integer read FErrors;
    property LastError: string read FLastError;
  end;

function ReadBufferText(const Buffer: IOTAEditBuffer): string;

implementation

uses System.SysUtils, System.StrUtils, System.Diagnostics, Winapi.Windows, Winapi.Messages, BlockFolding.Engine,
  BlockFolding.Settings;

type
  // The mouse events of the base class cannot be handled by a method, so the
  // interface is bound again here to a method of this class.
  TPaintNotifier = class(TNTACodeEditorNotifier, INTACodeEditorEvents)
  protected
    function AllowedEvents: TCodeEditorEvents; override;
    function AllowedGutterStages: TPaintGutterStages; override;
  public
    procedure EditorMouseDown(const Editor: TWinControl; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure EditorMouseUp(const Editor: TWinControl; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
  end;

var
  Manager: TFoldManager;

function TPaintNotifier.AllowedEvents: TCodeEditorEvents;
begin
  Result := [cevBeginEndPaintEvents, cevPaintGutterEvents, cevMouseEvents];
end;

function TPaintNotifier.AllowedGutterStages: TPaintGutterStages;
begin
  Result := [pgsEndPaint];
end;

procedure TPaintNotifier.EditorMouseDown(const Editor: TWinControl; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  if (Button = mbLeft) and (Manager <> nil) then Manager.MouseDown(Editor, X, Y);
end;

procedure TPaintNotifier.EditorMouseUp(const Editor: TWinControl; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  if (Button = mbLeft) and (Manager <> nil) then Manager.MouseUp(Editor, X, Y);
end;

function ReadBufferText(const Buffer: IOTAEditBuffer): string;
var Reader: IOTAEditReader; Chunk: array[0..16383] of AnsiChar; Count, Position: Integer; Bytes: UTF8String;
begin
  Reader := Buffer.CreateReader; Bytes := ''; Position := 0;
  repeat
    Count := Reader.GetText(Position, @Chunk[0], Length(Chunk));
    if Count > 0 then
    begin
      SetLength(Bytes, Position + Count);
      Move(Chunk[0], Bytes[Position + 1], Count);
      Inc(Position, Count);
    end;
  until Count <= 0;
  Reader := nil;
  Result := UTF8ToString(Bytes);
end;

// Blocks come sorted by first line, the outer one first when two start together.
function IndexOfBlock(const Blocks: TArray<TBlock>; First, Last: Integer): Integer;
var Low, High, Middle: Integer;
begin
  Low := 0; High := Length(Blocks) - 1;
  while Low < High do
  begin
    Middle := (Low + High) div 2;
    if Blocks[Middle].FirstLine < First then Low := Middle + 1 else High := Middle;
  end;
  while (Low < Length(Blocks)) and (Blocks[Low].FirstLine = First) do
  begin
    if Blocks[Low].LastLine = Last then Exit(Low);
    Inc(Low);
  end;
  Result := -1;
end;

// What this plugin offers to fold, out of everything the analyser finds:
// - only the kinds chosen in the settings;
// - not the body of a routine, which belongs to the IDE's own folding;
// - of several that start on the same line only the outermost, since the editor
//   cannot tell them apart;
// - nothing that reaches past the end of what is around it: in the editor a
//   block is either inside another or apart from it.
function Foldable(const Source: string): TArray<TBlock>;
var All: TArray<TBlock>; Kept, Open: TList<TBlock>; Block: TBlock; Kinds: TBlockKinds;
begin
  Kinds := CurrentSettings.Kinds;
  All := FindBlocks(Source);
  Kept := TList<TBlock>.Create; Open := TList<TBlock>.Create;
  try
    for Block in All do
    begin
      if not (Block.Kind in Kinds) or (Block.Depth < 1) or (Block.LastLine <= Block.FirstLine) then Continue;
      while (Open.Count > 0) and (Open.Last.LastLine < Block.FirstLine) do Open.Delete(Open.Count - 1);
      if (Open.Count > 0) and ((Block.FirstLine = Open.Last.FirstLine) or (Block.LastLine > Open.Last.LastLine)) then Continue;
      Kept.Add(Block);
      Open.Add(Block);
    end;
    Result := Kept.ToArray;
  finally Open.Free; Kept.Free; end;
end;

// Everything in a list made by Foldable can be used.
function Usable(const Blocks: TArray<TBlock>; Index: Integer): Boolean;
begin
  Result := (Index >= 0) and (Index <= High(Blocks));
end;

{ TFileFolds }

constructor TFileFolds.Create;
begin
  inherited Create;
  Items := TList<TFoldItem>.Create;
  Starts := TDictionary<Integer, Integer>.Create;
end;

destructor TFileFolds.Destroy;
begin
  Starts.Free;
  Items.Free;
  inherited;
end;

{ TFoldManager }

constructor TFoldManager.Create;
var Notifier: TPaintNotifier;
begin
  inherited Create;
  FFiles := TObjectDictionary<string, TFileFolds>.Create([doOwnsValues]);
  FLayouts := TDictionary<TWinControl, TEditorLayout>.Create;
  FLog := TStringList.Create;
  FNextId := 720000;
  FNotifier := -1;
  FDiagFile := GetEnvironmentVariable('LOCALAPPDATA') + '\CSCoder\BlockFolding\diagnostico.log';
  ForceDirectories(ExtractFileDir(FDiagFile));
  DiagWrite('--- Block Folding carregado em ' + ParamStr(0));
  // The periodic snapshot asks the editor kernel for a position; it is only taken
  // when a file named diagnostico.on sits next to the log.
  if FileExists(ChangeFileExt(FDiagFile, '.on')) then
  begin
    FDiagTimer := TTimer.Create(nil);
    FDiagTimer.Interval := 500;
    FDiagTimer.OnTimer := DiagTick;
  end;
  if Supports(BorlandIDEServices, INTACodeEditorServices, FServices) then
  begin
    Notifier := TPaintNotifier.Create;
    Notifier.OnEditorBeginPaint := EditorBeginPaint;
    Notifier.OnEditorPaintGutter := EditorPaintGutter;
    FNotifier := FServices.AddEditorEventsNotifier(Notifier);
  end;
end;

destructor TFoldManager.Destroy;
begin
  if (FServices <> nil) and (FNotifier >= 0) then FServices.RemoveEditorEventsNotifier(FNotifier);
  FDiagTimer.Free;
  FServices := nil;
  FLog.Free;
  FLayouts.Free;
  FFiles.Free;
  inherited;
end;

class function TFoldManager.Instance: TFoldManager;
begin
  if Manager = nil then Manager := TFoldManager.Create;
  Result := Manager;
end;

class procedure TFoldManager.Release;
begin
  FreeAndNil(Manager);
end;

procedure TFoldManager.Log(const Text: string);
begin
  if FLog.Count >= 400 then FLog.Delete(0);
  FLog.Add(Text);
  DiagWrite('evento: ' + Text);
end;

procedure TFoldManager.DiagWrite(const Text: string);
var Stream: TFileStream; Bytes: TBytes;
begin
  try
    if FileExists(FDiagFile) then Stream := TFileStream.Create(FDiagFile, fmOpenReadWrite or fmShareDenyNone)
    else Stream := TFileStream.Create(FDiagFile, fmCreate);
    try
      // A log that is never read must not grow for ever.
      if Stream.Size > 2 * 1024 * 1024 then Stream.Size := 0;
      Stream.Seek(0, soEnd);
      Bytes := TEncoding.UTF8.GetBytes(FormatDateTime('hh:nn:ss.zzz', Now) + ' ' + Text + sLineBreak);
      Stream.WriteBuffer(Bytes[0], Length(Bytes));
    finally Stream.Free; end;
  except
  end;
end;

// What the top editor reports, written only when it differs from the last time.
procedure TFoldManager.DiagTick(Sender: TObject);
var View: IOTAEditView; Editor: TWinControl; Folds: TFileFolds; Item: TFoldItem; State, Items: string; Services: IOTAEditorServices;
begin
  try
    if (FServices = nil) or FBusy or not Supports(BorlandIDEServices, IOTAEditorServices, Services) then Exit;
    View := Services.TopView;
    if (View = nil) or (View.Buffer = nil) then Exit;
    Editor := FServices.GetEditorForView(View);
    if Editor = nil then Exit;
    Items := '';
    Folds := FoldsOf(View.Buffer.FileName, False);
    if Folds <> nil then
      for Item in Folds.Items do
        Items := Items + Format('%d..%d%s ', [Item.First, Item.Last, IfThen(Item.Collapsed, '', '(aberta)')]);
    State := Format('%s | origem-do-texto-X=%d | coluna-esquerda=%d | topo=%d | linhas-na-tela=%d | margem-de-dobra=%d | largura-do-editor=%d | dobras=[%s]',
      [ExtractFileName(View.Buffer.FileName), TFoldEngine.TextOriginX(Editor), View.LeftColumn, View.TopPos.Line, View.ViewSize.cy,
       TFoldEngine.FoldGutterWidth(Editor), Editor.Width, Trim(Items)]);
    if State <> FDiagLast then
    begin
      FDiagLast := State;
      DiagWrite(State + Format(' | cursor=%d,%d', [View.CursorPos.Line, View.CursorPos.Col]));
    end;
  except
  end;
end;

function TFoldManager.TakeLog: string;
begin
  Result := Trim(FLog.Text);
  FLog.Clear;
end;

procedure TFoldManager.ResetStatistics;
begin
  FReapplied := 0; FPasses := 0; FErrors := 0; FMaxPassMs := 0; FLastPassMs := 0; FLastError := '';
end;

function TFoldManager.FoldsOf(const FileName: string; CreateIt: Boolean): TFileFolds;
begin
  if not FFiles.TryGetValue(AnsiLowerCase(FileName), Result) then
  begin
    Result := nil;
    if CreateIt then
    begin
      Result := TFileFolds.Create;
      FFiles.Add(AnsiLowerCase(FileName), Result);
    end;
  end;
end;

function TFoldManager.Items(const FileName: string): TArray<TFoldItem>;
var Folds: TFileFolds;
begin
  Folds := FoldsOf(FileName, False);
  if Folds = nil then Result := nil else Result := Folds.Items.ToArray;
end;

procedure TFoldManager.Forget(const Tracker: IOTAEditLineTracker; Id: Integer);
var Index: Integer;
begin
  Index := Tracker.IndexOfData(Id);
  if Index >= 0 then Tracker.Delete(Index);
  Index := Tracker.IndexOfData(Id + 1);
  if Index >= 0 then Tracker.Delete(Index);
end;

// A repaint must never fail because of this plugin.
procedure TFoldManager.EditorBeginPaint(const Editor: TWinControl; const ForceFullRepaint: Boolean);
var View: IOTAEditView;
begin
  try
    if FBusy or not CurrentSettings.Enabled then Exit;
    View := FServices.GetViewForEditor(Editor);
    if (View = nil) or (View.Buffer = nil) then Exit;
    if FFiles.Count > 0 then Sync(Editor, View);
    if SignsActive(Editor) then UpdateLayout(Editor, View);
  except
    on E: Exception do
    begin
      Inc(FErrors);
      FLastError := E.ClassName + ': ' + E.Message;
      Log('error in repaint: ' + FLastError);
    end;
  end;
end;

// Our own signs are drawn only when the IDE is not drawing its own.
function TFoldManager.SignsActive(Editor: TWinControl): Boolean;
var Reason: string;
begin
  Result := CurrentSettings.Enabled and CurrentSettings.GutterSigns and (TFoldEngine.FoldGutterWidth(Editor) <= 0) and
    TFoldEngine.Supported(Editor, Reason);
end;

// Before a repaint: which logical line each screen row shows, where the code
// starts, and (not more than a few times a second) the blocks of the unit.
procedure TFoldManager.UpdateLayout(Editor: TWinControl; const View: IOTAEditView);
var Layout: TEditorLayout; Folds: TFileFolds; Row, Line, Count, I: Integer; Text: string; Blocks: TArray<TBlock>;
  State: INTACodeEditorState; Settings: TFoldSettings;
begin
  if not FLayouts.TryGetValue(Editor, Layout) then Layout := Default(TEditorLayout);
  Layout.FileName := View.Buffer.FileName;
  Folds := FoldsOf(Layout.FileName, True);
  if (Folds.ParsedAt = 0) or (GetTickCount64 - Folds.ParsedAt > 300) then
  begin
    Settings := CurrentSettings;
    Text := ReadBufferText(View.Buffer);
    Blocks := Foldable(Text);
    Folds.Starts.Clear;
    for I := 0 to High(Blocks) do
      if Usable(Blocks, I) and (Blocks[I].Kind in Settings.Kinds) and not Folds.Starts.ContainsKey(Blocks[I].FirstLine) then
        Folds.Starts.Add(Blocks[I].FirstLine, Blocks[I].LastLine);
    Folds.ParsedAt := GetTickCount64;
  end;
  Count := View.ViewSize.cy + 3;
  SetLength(Layout.Rows, Count);
  Line := View.TopPos.Line;
  for Row := 0 to Count - 1 do
  begin
    Layout.Rows[Row] := Line;
    // The next row shows the next line that is not hidden.
    I := 0;
    repeat
      Inc(Line); Inc(I);
    until (I > 5000) or not TFoldEngine.LineHidden(Editor, Line);
  end;
  // Where the code starts, from the public editor state.
  State := FServices.GetEditorState(Editor);
  if State <> nil then
  begin
    {$IF CompilerVersion >= 36}
    State.Refresh;
    {$IFEND}
    // The pixel position of the first column of text on screen. (CodeLeftEdge is not
    // it: in Delphi 11 that is the width of the breakpoint strip.)
    Layout.CodeLeft := State.GetCharacterPosPx(View.LeftColumn, State.TopLine).Left;
  end;
  FLayouts.AddOrSetValue(Editor, Layout);
end;

// After the IDE painted the gutter of a row: our - or + on a row that starts a block.
procedure TFoldManager.EditorPaintGutter(const Rect: TRect; const Stage: TPaintGutterStage; const BeforeEvent: Boolean;
  var AllowDefaultPainting: Boolean; const Context: INTACodeEditorPaintContext);
var Editor: TWinControl; Layout: TEditorLayout; Folds: TFileFolds; Row, Line, Size, Left, Top, Middle: Integer; Canvas: TCanvas;
  Collapsed: Boolean; Box: TRect;
begin
  try
    if BeforeEvent or (Stage <> pgsEndPaint) or FBusy then Exit;
    Editor := Context.EditControl;
    if (Editor = nil) or not FLayouts.TryGetValue(Editor, Layout) or (Length(Layout.Rows) = 0) or (Rect.Height <= 0) then Exit;
    if not SignsActive(Editor) then Exit;
    // The row is taken from where the IDE is painting, not from the line number it
    // reports, which is wrong below a fold in some versions.
    Row := Rect.Top div Rect.Height;
    Size := (Rect.Height * 3 div 5) or 1;
    if (Layout.LineHeight <> Rect.Height) or (Layout.SignSize <> Size) then
    begin
      Layout.LineHeight := Rect.Height;
      Layout.SignSize := Size;
      FLayouts.AddOrSetValue(Editor, Layout);
    end;
    if Row > High(Layout.Rows) then Exit;
    Line := Layout.Rows[Row];
    Folds := FoldsOf(Layout.FileName, False);
    if (Folds = nil) or not Folds.Starts.ContainsKey(Line) then Exit;
    Collapsed := TFoldEngine.LineHidden(Editor, Line + 1) and not TFoldEngine.LineHidden(Editor, Line);
    Left := Layout.CodeLeft - Size - 2;
    Top := Rect.Top + (Rect.Height - Size) div 2;
    Box := System.Types.Rect(Left, Top, Left + Size, Top + Size);
    Middle := Size div 2;
    Canvas := Context.Canvas;
    Canvas.Brush.Style := bsSolid;
    Canvas.Brush.Color := FServices.Options.BackgroundColor[atWhiteSpace];
    Canvas.Pen.Style := psSolid; Canvas.Pen.Width := 1;
    Canvas.Pen.Color := FServices.Options.FontColor[atWhiteSpace];
    Canvas.Rectangle(Box);
    Canvas.MoveTo(Left + 2, Top + Middle); Canvas.LineTo(Left + Size - 2, Top + Middle);
    if Collapsed then
    begin
      Canvas.MoveTo(Left + Middle, Top + 2); Canvas.LineTo(Left + Middle, Top + Size - 2);
    end;
  except
    on E: Exception do
    begin
      Inc(FErrors);
      FLastError := E.ClassName + ': ' + E.Message;
    end;
  end;
end;

// The line whose sign is at this point of the editor, or 0.
function TFoldManager.SignLineAt(Editor: TWinControl; X, Y: Integer): Integer;
var Layout: TEditorLayout; Folds: TFileFolds; Row: Integer;
begin
  Result := 0;
  if not FLayouts.TryGetValue(Editor, Layout) or (Layout.LineHeight <= 0) or not SignsActive(Editor) then Exit;
  if (X < Layout.CodeLeft - Layout.SignSize - 4) or (X >= Layout.CodeLeft) or (Y < 0) then Exit;
  Row := Y div Layout.LineHeight;
  if Row > High(Layout.Rows) then Exit;
  Folds := FoldsOf(Layout.FileName, False);
  if (Folds <> nil) and Folds.Starts.ContainsKey(Layout.Rows[Row]) then Result := Layout.Rows[Row];
end;

function TFoldManager.MouseDown(Editor: TWinControl; X, Y: Integer): Boolean;
var Line: Integer;
begin
  Result := False;
  try
    FDownEditor := nil;
    Line := SignLineAt(Editor, X, Y);
    if Line = 0 then Exit;
    Result := True;
    // The IDE itself opens a folded block on a click here, but never folds one, and it
    // goes on doing so until the button is released. So the state is noted now and the
    // opposite is made sure of after the release.
    FDownEditor := Editor;
    FDownLine := Line;
    FDownFolded := TFoldEngine.LineHidden(Editor, Line + 1) and not TFoldEngine.LineHidden(Editor, Line);
    Log(Format('click on the sign of line %d, to %s', [Line, IfThen(FDownFolded, 'open', 'fold')]));
  except
    on E: Exception do
    begin
      Inc(FErrors);
      FLastError := E.ClassName + ': ' + E.Message;
    end;
  end;
end;

procedure TFoldManager.MouseUp(Editor: TWinControl; X, Y: Integer);
var Line: Integer; View: IOTAEditView; Later: TThreadProcedure; Fold, Same: Boolean; Window: HWND;
begin
  try
    if (FDownEditor = nil) or (FDownEditor <> Editor) then Exit;
    FDownEditor := nil;
    Line := FDownLine;
    Fold := not FDownFolded;
    // Released on the same sign. The rows are those of now: the IDE may have opened the
    // block in the meantime, which moves no row above or on the sign.
    Same := SignLineAt(Editor, X, Y) = Line;
    View := FServices.GetViewForEditor(Editor);
    // The IDE paints when it handles the release, the kernel paints again for each block
    // that is folded, and none of those pictures is the final one: the signs are missing
    // or the rows are half moved. Drawing is held from here until all is done, so the
    // click shows as a single repaint.
    Window := Editor.Handle;
    SendMessage(Window, WM_SETREDRAW, 0, 0);
    // After the IDE has finished with the release itself. Released somewhere else, the
    // block goes back to what it was.
    Later := procedure
      begin
        try
          if Manager <> nil then Manager.ToggleLine(View, Line, Fold = Same);
        finally
          if IsWindow(Window) then
          begin
            SendMessage(Window, WM_SETREDRAW, 1, 0);
            RedrawWindow(Window, nil, 0, RDW_INVALIDATE or RDW_UPDATENOW);
          end;
        end;
      end;
    TThread.ForceQueue(nil, Later);
  except
    on E: Exception do
    begin
      Inc(FErrors);
      FLastError := E.ClassName + ': ' + E.Message;
    end;
  end;
end;

procedure TFoldManager.ToggleLine(const View: IOTAEditView; Line: Integer; Fold: Boolean);
var Editor: TWinControl; Reason, Text: string; Folds: TFileFolds; List: TList<TFoldItem>; Lines: TStringList; Blocks: TArray<TBlock>;
  I, Index, Column, Cursor: Integer;
begin
  try
    if (FServices = nil) or (View = nil) or (View.Buffer = nil) or not CurrentSettings.Enabled then Exit;
    Editor := FServices.GetEditorForView(View);
    if not TFoldEngine.Supported(Editor, Reason) then Exit;
    Sync(Editor, View);
    Folds := FoldsOf(View.Buffer.FileName, True);
    List := Folds.Items;
    if not Fold then
    begin
      // Open: whatever the IDE did, the block ends up open and is no longer kept folded.
      FBusy := True;
      try
        if TFoldEngine.LineHidden(Editor, Line + 1) and not TFoldEngine.LineHidden(Editor, Line) then
          TFoldEngine.Open(Editor, Line);
        for I := List.Count - 1 downto 0 do
          if List[I].First = Line then
          begin
            Forget(View.Buffer.GetEditLineTracker, List[I].Id);
            Log(Format('opened %d..%d', [List[I].First, List[I].Last]));
            List.Delete(I);
          end;
      finally FBusy := False; end;
      View.Paint;
      Exit;
    end;
    Lines := TStringList.Create;
    try
      Lines.Text := ReadBufferText(View.Buffer);
      Blocks := Foldable(Lines.Text);
      Index := -1;
      for I := 0 to High(Blocks) do
        if (Blocks[I].FirstLine = Line) and Usable(Blocks, I) then begin Index := I; Break; end;
      if Index < 0 then Exit;
      // With the cursor inside the block the IDE would open it again to show it.
      Cursor := View.CursorPos.Line;
      if (Cursor > Blocks[Index].FirstLine) and (Cursor <= Blocks[Index].LastLine) then
      begin
        Text := Lines[Line - 1];
        Column := 1;
        while (Column <= Length(Text)) and (Text[Column] = ' ') do Inc(Column);
        View.Buffer.EditPosition.Move(Line, Column);
      end;
      if not FoldBlock(Editor, View, Lines, Blocks, Index) then
        View.SetTempMsg('Block Folding: este bloco contém outra dobra da IDE (por exemplo {$REGION}) e não pode ser dobrado');
      View.Paint;
    finally Lines.Free; end;
  except
    on E: Exception do
    begin
      Inc(FErrors);
      FLastError := E.ClassName + ': ' + E.Message;
      Log('error in toggle line: ' + FLastError);
    end;
  end;
end;

// Registers the block and, before it, every block around it that is not yet
// registered, from the outside in. False when the block itself cannot be
// registered safely: something already starts a block on its first line or
// inside it. A block around it that cannot be registered is simply left out.
function TFoldManager.EnsureRegistered(Editor: TWinControl; Lines: TStrings; const Blocks: TArray<TBlock>;
  Index: Integer): Boolean;
var I, Line: Integer; Target, Candidate: TBlock; Safe: Boolean;
begin
  Target := Blocks[Index];
  for I := 0 to Index do
  begin
    Candidate := Blocks[I];
    if I <> Index then
      if not Usable(Blocks, I) or (Candidate.FirstLine >= Target.FirstLine) or (Candidate.LastLine < Target.LastLine) then
        Continue;
    if TFoldEngine.BlockStartsAt(Editor, Candidate.FirstLine) then Continue;
    Safe := Candidate.LastLine <= Lines.Count;
    if Safe then
      for Line := Candidate.FirstLine + 1 to Candidate.LastLine do
        if TFoldEngine.BlockStartsAt(Editor, Line) then begin Safe := False; Break; end;
    if Safe then
      TFoldEngine.RegisterBlock(Editor, Candidate.FirstLine, Length(Lines[Candidate.FirstLine - 1]), Candidate.LastLine,
        Length(Lines[Candidate.LastLine - 1]))
    else if I = Index then
    begin
      Log(Format('refused %d..%d: another foldable block starts inside it', [Target.FirstLine, Target.LastLine]));
      Exit(False);
    end;
  end;
  Result := TFoldEngine.BlockStartsAt(Editor, Target.FirstLine);
end;

// Brings every kept block of the view's unit to its current lines. A block the
// editor still has only tells its state, since the user may have opened or closed
// it with the mouse; one the editor forgot is registered again as it was.
procedure TFoldManager.Sync(Editor: TWinControl; const View: IOTAEditView);
var Folds: TFileFolds; List: TList<TFoldItem>; Tracker: IOTAEditLineTracker; I, A, B, Cursor, Index: Integer;
  Item: TFoldItem; Lines: TStringList; Blocks: TArray<TBlock>; Watch: TStopwatch; Reason: string; Missing: TList<Integer>;
  Quiet: Boolean;
begin
  Quiet := False;
  if FBusy or (View = nil) or (View.Buffer = nil) then Exit;
  Folds := FoldsOf(View.Buffer.FileName, False);
  if (Folds = nil) or (Folds.Items.Count = 0) or not TFoldEngine.Supported(Editor, Reason) then Exit;
  List := Folds.Items;
  FBusy := True;
  Watch := TStopwatch.StartNew;
  Lines := nil;
  Missing := TList<Integer>.Create;
  try
    try
      Tracker := View.Buffer.GetEditLineTracker;
      Cursor := View.CursorPos.Line;
      // First what the editor still has; no text is read for this.
      for I := List.Count - 1 downto 0 do
      begin
        Item := List[I];
        A := Tracker.IndexOfData(Item.Id);
        B := Tracker.IndexOfData(Item.Id + 1);
        // The unit was closed and opened again: its folds are gone, as intended.
        if (A < 0) or (B < 0) then begin List.Delete(I); Continue; end;
        Item.First := Tracker.GetLineNum(A);
        Item.Last := Tracker.GetLineNum(B);
        if (Item.First < 1) or (Item.Last <= Item.First) then
        begin
          Forget(Tracker, Item.Id);
          List.Delete(I);
          Continue;
        end;
        // Hidden inside a folded outer block: the editor does not report it and its own
        // state cannot be read now; it is still there and is left alone.
        if TFoldEngine.LineHidden(Editor, Item.First) then
        begin
          List[I] := Item;
          Continue;
        end;
        if TFoldEngine.BlockStartsAt(Editor, Item.First) then
        begin
          begin
            Item.Collapsed := TFoldEngine.LineHidden(Editor, Item.First + 1);
            // The cursor is on a hidden line of the block, for one after Enter at the end
            // of the folded line: open it instead of leaving the user typing blind.
            if Item.Collapsed and (Cursor > Item.First) and (Cursor <= Item.Last) then
            begin
              TFoldEngine.Open(Editor, Item.First);
              Item.Collapsed := False;
            end;
          end;
        end
        else Missing.Add(Item.Id);
        List[I] := Item;
      end;
      if Missing.Count > 0 then
      begin
        // The editor repaints itself after each block that is folded; with more than one
        // that would show the others still open for an instant, and costs time.
        Quiet := Missing.Count > 1;
        if Quiet then SendMessage(Editor.Handle, WM_SETREDRAW, 0, 0);
        Lines := TStringList.Create;
        Lines.Text := ReadBufferText(View.Buffer);
        Blocks := Foldable(Lines.Text);
        // Then what it forgot, from the top down, which is from the outside in.
        I := 0;
        while I < List.Count do
        begin
          Item := List[I];
          if not Missing.Contains(Item.Id) then begin Inc(I); Continue; end;
          Index := IndexOfBlock(Blocks, Item.First, Item.Last);
          // Kept only if those two lines still open and close a block, and it can be registered safely.
          if (Index < 0) or not Usable(Blocks, Index) or not EnsureRegistered(Editor, Lines, Blocks, Index) then
          begin
            Log(Format('dropped %d..%d', [Item.First, Item.Last]));
            Forget(Tracker, Item.Id);
            List.Delete(I);
            Continue;
          end;
          if Item.Collapsed and (Cursor > Item.First) and (Cursor <= Item.Last) then Item.Collapsed := False;
          Inc(FReapplied);
          List[I] := Item;
          Inc(I);
        end;
        // Folding has no order to respect, so it goes from the bottom up: hiding a
        // block then never moves one that is still to be hidden.
        for I := List.Count - 1 downto 0 do
          if List[I].Collapsed and Missing.Contains(List[I].Id) then
            TFoldEngine.Collapse(Editor, List[I].First, Length(Lines[List[I].First - 1]), List[I].Last,
              Length(Lines[List[I].Last - 1]));
      end;
    except
      on E: Exception do
      begin
        Inc(FErrors);
        FLastError := E.ClassName + ': ' + E.Message;
        Log('error: ' + FLastError);
      end;
    end;
  finally
    if Quiet then
    begin
      SendMessage(Editor.Handle, WM_SETREDRAW, 1, 0);
      Editor.Invalidate;
    end;
    Missing.Free;
    Lines.Free;
    FBusy := False;
    Inc(FPasses);
    FLastPassMs := Watch.ElapsedMilliseconds;
    if FLastPassMs > FMaxPassMs then FMaxPassMs := FLastPassMs;
  end;
end;

function TFoldManager.FoldBlock(Editor: TWinControl; const View: IOTAEditView; Lines: TStrings; const Blocks: TArray<TBlock>;
  Index: Integer): Boolean;
var Folds: TFileFolds; List: TList<TFoldItem>; Item: TFoldItem; Tracker: IOTAEditLineTracker; I, Position: Integer; Block: TBlock;
begin
  Result := False;
  Block := Blocks[Index];
  if not Usable(Blocks, Index) then Exit;
  Folds := FoldsOf(View.Buffer.FileName, True);
  List := Folds.Items;
  FBusy := True;
  try
    if not EnsureRegistered(Editor, Lines, Blocks, Index) then Exit;
    // Kept sorted by first line, the outer block first.
    Position := List.Count;
    for I := 0 to List.Count - 1 do
    begin
      if (List[I].First = Block.FirstLine) and (List[I].Last = Block.LastLine) then begin Position := -1 - I; Break; end;
      if (List[I].First > Block.FirstLine) or ((List[I].First = Block.FirstLine) and (List[I].Last < Block.LastLine)) then
      begin
        Position := I;
        Break;
      end;
    end;
    if Position < 0 then
    begin
      Item := List[-1 - Position];
      Item.Collapsed := True;
      List[-1 - Position] := Item;
    end
    else
    begin
      Item.Id := FNextId; Inc(FNextId, 2);
      Item.First := Block.FirstLine; Item.Last := Block.LastLine; Item.Collapsed := True;
      Tracker := View.Buffer.GetEditLineTracker;
      Tracker.AddLine(Item.First, Item.Id);
      Tracker.AddLine(Item.Last, Item.Id + 1);
      List.Insert(Position, Item);
    end;
    TFoldEngine.Collapse(Editor, Block.FirstLine, Length(Lines[Block.FirstLine - 1]), Block.LastLine,
      Length(Lines[Block.LastLine - 1]));
    Log(Format('folded %d..%d', [Block.FirstLine, Block.LastLine]));
    Result := True;
  finally FBusy := False; end;
end;

function TFoldManager.FoldRange(const View: IOTAEditView; First, Last: Integer; Lines: TStrings): Boolean;
var Editor: TWinControl; Own: TStringList; Reason: string; Blocks: TArray<TBlock>; Index: Integer;
begin
  Result := False;
  if (FServices = nil) or (View = nil) or (View.Buffer = nil) or (Last <= First) then Exit;
  Editor := FServices.GetEditorForView(View);
  if not TFoldEngine.Supported(Editor, Reason) then Exit;
  Own := nil;
  try
    try
      if Lines = nil then
      begin
        Own := TStringList.Create;
        Own.Text := ReadBufferText(View.Buffer);
        Lines := Own;
      end;
      Blocks := Foldable(Lines.Text);
      Index := IndexOfBlock(Blocks, First, Last);
      if Index < 0 then Exit;
      Result := FoldBlock(Editor, View, Lines, Blocks, Index);
    except
      on E: Exception do
      begin
        Inc(FErrors);
        FLastError := E.ClassName + ': ' + E.Message;
        Log('error: ' + FLastError);
      end;
    end;
  finally Own.Free; end;
end;

function TFoldManager.Toggle(const View: IOTAEditView): string;
var Editor: TWinControl; Reason, Text: string; Folds: TFileFolds; List: TList<TFoldItem>; Lines: TStringList;
  Blocks: TArray<TBlock>; Block: TBlock; Line, I, Best, Column: Integer; Settings: TFoldSettings;
  Native: IOTAElideActions;
begin
  Result := '';
  try
    if (FServices = nil) or (View = nil) or (View.Buffer = nil) then Exit('no editor');
    Settings := CurrentSettings;
    if not Settings.Enabled then Exit('Block Folding: desativado nas configurações');
    Editor := FServices.GetEditorForView(View);
    if not TFoldEngine.Supported(Editor, Reason) then
    begin
      Result := 'Block Folding: indisponível nesta versão do Delphi (' + Reason + ')';
      View.SetTempMsg(Result);
      Exit;
    end;
    Sync(Editor, View);
    Line := View.CursorPos.Line;
    Log('toggle at line ' + IntToStr(Line));
    Folds := FoldsOf(View.Buffer.FileName, True);
    List := Folds.Items;
    // On the first line of one of our folded blocks: open it and stop keeping it.
    for I := List.Count - 1 downto 0 do
      if (List[I].First = Line) and List[I].Collapsed then
      begin
        FBusy := True;
        try
          TFoldEngine.Open(Editor, Line);
          Forget(View.Buffer.GetEditLineTracker, List[I].Id);
          Log(Format('opened %d..%d', [List[I].First, List[I].Last]));
          List.Delete(I);
        finally FBusy := False; end;
        View.Paint;
        Exit('opened');
      end;
    Lines := TStringList.Create;
    try
      Lines.Text := ReadBufferText(View.Buffer);
      Blocks := Foldable(Lines.Text);
      // The innermost block around the cursor is the last one that starts before it.
      Best := -1;
      for I := 0 to High(Blocks) do
        if Usable(Blocks, I) and (Blocks[I].Kind in Settings.Kinds) and (Blocks[I].FirstLine <= Line) and
          (Blocks[I].LastLine >= Line) then Best := I;
      if Best < 0 then
      begin
        // Only the routine itself is around the cursor: that fold is the IDE's own.
        if Supports(View, IOTAElideActions, Native) then
        begin
          Native.ElideNearestBlock;
          Log('native fold at ' + IntToStr(Line));
          Exit('native');
        end;
        Exit('no block');
      end;
      Block := Blocks[Best];
      // The cursor goes to the line that stays visible, on its first character.
      Text := Lines[Block.FirstLine - 1];
      Column := 1;
      while (Column <= Length(Text)) and (Text[Column] = ' ') do Inc(Column);
      // Moved in the editor itself and before folding: with the cursor still inside,
      // the IDE would open the block again to show it.
      View.Buffer.EditPosition.Move(Block.FirstLine, Column);
      View.MoveViewToCursor;
      if FoldBlock(Editor, View, Lines, Blocks, Best) then Result := 'folded'
      else
      begin
        Result := 'Block Folding: este bloco contém outra dobra da IDE (por exemplo {$REGION}) e não pode ser dobrado';
        View.SetTempMsg(Result);
      end;
      View.Paint;
    finally Lines.Free; end;
  except
    on E: Exception do
    begin
      Inc(FErrors);
      FLastError := E.ClassName + ': ' + E.Message;
      Log('error in toggle: ' + FLastError);
      Result := 'error';
    end;
  end;
end;

procedure TFoldManager.OpenAll(const View: IOTAEditView);
var Editor: TWinControl; Folds: TFileFolds; List: TList<TFoldItem>; Tracker: IOTAEditLineTracker; I: Integer; Reason: string;
begin
  try
    if (FServices = nil) or (View = nil) or (View.Buffer = nil) then Exit;
    Editor := FServices.GetEditorForView(View);
    if not TFoldEngine.Supported(Editor, Reason) then Exit;
    Sync(Editor, View);
    Folds := FoldsOf(View.Buffer.FileName, False);
    if Folds = nil then Exit;
    List := Folds.Items;
    Tracker := View.Buffer.GetEditLineTracker;
    // A repaint in the middle of this must not go through the list being emptied.
    FBusy := True;
    try
      // From the top down: an inner block can only be opened once the outer one is.
      for I := 0 to List.Count - 1 do
      begin
        if TFoldEngine.BlockStartsAt(Editor, List[I].First) and not TFoldEngine.LineHidden(Editor, List[I].First) and
          TFoldEngine.LineHidden(Editor, List[I].First + 1) then
          TFoldEngine.Open(Editor, List[I].First);
        Forget(Tracker, List[I].Id);
      end;
      Log(Format('opened all (%d)', [List.Count]));
      List.Clear;
    finally FBusy := False; end;
    View.Paint;
  except
    on E: Exception do
    begin
      Inc(FErrors);
      FLastError := E.ClassName + ': ' + E.Message;
      Log('error in open all: ' + FLastError);
    end;
  end;
end;

initialization

finalization
  FreeAndNil(Manager);

end.
