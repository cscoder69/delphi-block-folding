unit BFProbe.Main;

// Self-driving probe of code folding (elision) in the Delphi code editor.
// It runs only when BFPROBE_REPORT names a report file: a timer waits for the
// IDE, opens the sample unit named by BFPROBE_SAMPLE and writes what it
// observed. Everything here uses the public ToolsAPI or read-only RTTI; no
// internal method of the IDE is called.

interface

procedure Register;

implementation

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Classes, System.Types, System.IOUtils,
  System.Rtti, System.TypInfo, System.StrUtils, System.Generics.Collections, System.RegularExpressions,
  Vcl.Graphics, Vcl.Controls, Vcl.Forms, Vcl.ExtCtrls, Vcl.ActnList, System.Actions, Vcl.Imaging.pngimage,
  System.Diagnostics, Vcl.Menus, ToolsAPI, ToolsAPI.Editor, BlockFolding.Blocks, BlockFolding.Engine,
  BlockFolding.Manager, BlockFolding.Register, BlockFolding.Settings, Vcl.StdCtrls, Vcl.ComCtrls, System.Win.Registry;

const
  // Names worth reporting from the RTTI listing.
  HitPattern = '(?i)elid|elis|fold|collaps|outlin|region';
  MaxRttiClasses = 300;
  MaxRttiDepth = 2;

type
  // A block whose fold is kept while the unit is edited.
  TKept = record
    Id, First, Last: Integer;
    Collapsed: Boolean;
  end;

  TMarker = record
    Name: string;
    Line, Col: Integer;
  end;

  TProbeNotifier = class(TNTACodeEditorNotifier)
  protected
    function AllowedEvents: TCodeEditorEvents; override;
    function AllowedLineStages: TPaintLineStages; override;
  end;

  // A highlighter of our own, to see what the IDE asks it in a real editor.
  TProbeHighlighter = class(TNotifierObject, IInterface, IOTANotifier, IOTAHighlighter,
    IOTAHighlighterPreview, IOTAElisionPreview)
  private
    FCalls: TDictionary<string, Integer>;
    procedure Hit(const Name: string);
  public
    constructor Create;
    destructor Destroy; override;
    function Summary: string;
    function QueryInterface(const IID: TGUID; out Obj): HResult; stdcall;
    { IOTAHighlighter }
    function GetIDString: string;
    function GetName: string;
    procedure Tokenize(StartClass: TOTALineClass; LineBuf: POTAEdChar; LineBufLen: TOTALineSize;
      HighlightCodes: POTASyntaxCode);
    function TokenizeLineClass(StartClass: TOTALineClass; LineBuf: POTAEdChar;
      LineBufLen: TOTALineSize): TOTALineClass;
    { IOTAHighlighterPreview }
    function GetDisplayName: string;
    function GetSampleText: string;
    function GetInvalidBreakpointLine: Integer;
    function GetCurrentInstructionLine: Integer;
    function GetValidBreakpointLine: Integer;
    function GetDisabledBreakpointLine: Integer;
    function GetErrorLine: Integer;
    function GetSampleSearchText: string;
    function GetBlockStartLine: Integer;
    function GetBlockStartCol: Integer;
    function GetBlockEndLine: Integer;
    function GetBlockEndCol: Integer;
    { IOTAElisionPreview }
    function GetElidableBlockStartLine: Integer;
    function GetElidableBlockStartCol: Integer;
    function GetElidableBlockEndLine: Integer;
    function GetElidableBlockEndCol: Integer;
    function GetElidedBlockStartLine: Integer;
    function GetElidedBlockStartCol: Integer;
    function GetElidedBlockEndLine: Integer;
    function GetElidedBlockEndCol: Integer;
    function GetElidedBlockDescription: String;
    function GetElidableBlockDescription: String;
  end;

  TProbe = class
  private
    FTimer, FWatch: TTimer;
    FReport, FRtti, FHits, FLines, FEvents: TStringList;
    FReportFile, FSample, FDir, FMode, FFoldFile: string;
    FTicks, FFoldFirst, FFoldLast: Integer;
    FRunning: Boolean;
    FWatchWindow: HWND;
    FWatchTicks, FWatchAttempts, FWatchPatience: Integer;
    FMarkers: TList<TMarker>;
    FServices: INTACodeEditorServices;
    FView: IOTAEditView;
    FEditor: TWinControl;
    FNotifier: TProbeNotifier;
    FNotifierIndex: Integer;
    FPaintOn, FLogAnyLine, FKeep, FKeepBusy: Boolean;
    FKeepReapplied, FKeepErrors, FOpenLines, FOpenEpisodes: Integer;
    FLastOpen: UInt64;
    FKeepError: string;
    FTracker: IOTAEditLineTracker;
    FKept: TList<TKept>;
    FKeepAll: Boolean;
    FArgLines: TStringList;
    FKeepPasses: Integer;
    FKeepLastMs, FKeepMaxMs: Int64;
    FCheckPaints, FInCommand: Boolean;
    FDialogShots: Integer;
    // Mouse and keyboard through the system, as a person uses them, instead of messages to the editor.
    FRealInput: Boolean;
    FFilm: Integer;
    FPaintsChecked, FPaintsWrong: Integer;
    FModalTimer: TTimer;
    FModalAction: TProc<TCustomForm>;
    FModalShot: string;
    // Class of the modal window ModalTick expects to find open.
    FModalClass: string;
    FPaintCalls, FPaintDrawn, FPaintLogged, FGuideFrom, FGuideTo, FGuideCol: Integer;
    FRows: TDictionary<Integer, Integer>;
    FRowMarks: TDictionary<Integer, string>;
    FTint: TBitmap;
    FCtx: TRttiContext;
    FVisited: TList<TClass>;
    procedure Tick(Sender: TObject);
    procedure WatchDialogs(Sender: TObject);
    procedure Note(const Text: string);
    procedure Run;
    procedure LoadSample;
    function Marker(const Name: string): TMarker;
    function OpenAndBind(const FileName: string): Boolean;
    function State: INTACodeEditorState;
    procedure SetCursor(Line, Col: Integer);
    function VisibleRows(Top: Integer): string;
    function HiddenByQuery: string;
    function PaintedRows: string;
    function Capture(const Name: string): Integer;
    procedure RunEnvironment;
    procedure RunRegions(const Module: IOTAModule);
    procedure RunRegionsOfView;
    procedure RunNearestBlock;
    procedure RunPainting;
    procedure RunRtti;
    procedure RunHighlighter;
    procedure DescribeType(RttiType: TRttiType; const Indent: string; Depth: Integer);
    procedure RunLayout;
    procedure RunFold;
    procedure CloseSample(const FileName: string);
    procedure RunFoldReopen;
    function DebugLine: Integer;
    function WaitDebugStop(Seconds: Integer): Integer;
    procedure DebugStep;
    procedure DebugTerminate;
    procedure RunFoldDebug;
    procedure KeepStart;
    procedure KeepStop;
    procedure KeepCheck;
    procedure OnBeginPaint(const Editor: TWinControl; const ForceFullRepaint: Boolean);
    procedure TypeAtEnd(Line: Integer; const Text: string; PauseMs: Integer);
    procedure DeleteLine(Line: Integer);
    procedure RunFoldKeep;
    function LineQueryOn(Editor: TWinControl; const Name: string; Line: Integer): Boolean;
    procedure ApplyRange(First, Last: Integer; Collapse: Boolean);
    procedure KeptStart;
    procedure KeptAdd(First, Last: Integer; Collapsed: Boolean);
    procedure KeptStop;
    procedure KeepCheckAll;
    function KeptVerify(const Title: string): Boolean;
    procedure ClickFoldBox(Line: Integer);
    procedure PostText(const Text: string);
    procedure PostKey(Key: Word);
    procedure RunFoldMulti;
    procedure RunFoldBig;
    procedure RunFoldViews;
    procedure OnEndPaint(const Editor: TWinControl);
    function MenuClick(const ItemName: string): Boolean;
    procedure PressShortcut(Key: Word; Ctrl, Alt, Shift: Boolean);
    function PluginHidden(First, Last: Integer): string;
    function PluginVerify(const Title: string): Boolean;
    procedure PluginToggleAt(Line, Col: Integer; UseShortcut: Boolean; const Title: string);
    procedure RunPlugin;
    procedure RunPluginSecondUnit;
    procedure RunPluginReopen;
    procedure SaveCurrent;
    procedure UnfoldAllNative;
    procedure RunPluginDebug;
    procedure RunPluginBig;
    procedure ModalTick(Sender: TObject);
    procedure CaptureForm(Form: TCustomForm; const Name: string);
    procedure WithSettingsForm(const Shot: string; const Action: TProc<TCustomForm>);
    procedure WithModal(const ItemName, FormClass, Shot: string; const Action: TProc<TCustomForm>);
    function MenuItemByName(const ItemName: string): TMenuItem;
    function MenuText(Parent: TMenuItem): string;
    procedure RunPluginSettings;
    procedure RunFoldNest;
    procedure RunCnPack;
    procedure RunReal;
    procedure ShowCode;
    function BringToFront: Boolean;
    procedure CaptureWindow(Window: HWND; const Name: string);
    procedure ClickAt(Line, Col: Integer);
    function KernelGutter: string;
    procedure ClickSign(Line: Integer);
    function FoldMethod(const Name: string; ParamCount: Integer; FirstIsRecord: Boolean): TRttiMethod;
    function CharPosArg(Method: TRttiMethod; ParamIndex, Index, Line: Integer): TValue;
    function LineQuery(const Name: string; Line: Integer): Boolean;
    function BufferText: string;
    procedure FoldObserve(const Title: string);
    function FoldExists: Boolean;
    procedure FoldArgs(out StartArg, EndArg: TValue);
    procedure FoldApply(Collapse: Boolean);
    procedure InsertLine(Line: Integer; const Text: AnsiString);
    procedure R(const Text: string);
    procedure DumpObject(Obj: TObject; const Path: string; Depth: Integer);
    procedure OnElided(const Editor: TWinControl; const LogicalLineNum: Integer);
    procedure OnUnElided(const Editor: TWinControl; const LogicalLineNum: Integer);
    procedure OnPaintLine(const Rect: TRect; const Stage: TPaintLineStage; const BeforeEvent: Boolean;
      var AllowDefaultPainting: Boolean; const Context: INTACodeEditorPaintContext);
  public
    constructor Create(const ReportFile: string);
    destructor Destroy; override;
  end;

var
  Probe: TProbe;

function PrintWindow(Window: HWND; Target: HDC; Flags: UINT): BOOL; stdcall; external user32 name 'PrintWindow';

procedure Pump(Milliseconds: Cardinal);
var Stop: UInt64;
begin
  Stop := GetTickCount64 + Milliseconds;
  repeat
    Application.ProcessMessages;
    Sleep(15);
  until GetTickCount64 >= Stop;
end;

// Like Pump, but lets the application reach its idle state between messages, which
// is when other plugins (CnPack for one) update what they draw in the editor.
procedure PumpIdle(Milliseconds: Cardinal);
var Stop: UInt64;
begin
  Stop := GetTickCount64 + Milliseconds;
  repeat
    Application.HandleMessage;
  until GetTickCount64 >= Stop;
end;

function RectText(const Rect: TRect): string;
begin
  Result := Format('(%d,%d,%d,%d)', [Rect.Left, Rect.Top, Rect.Right, Rect.Bottom]);
end;

{ TProbeNotifier }

function TProbeNotifier.AllowedEvents: TCodeEditorEvents;
begin
  Result := [cevWindowEvents, cevPaintLineEvents, cevBeginEndPaintEvents];
end;

function TProbeNotifier.AllowedLineStages: TPaintLineStages;
begin
  Result := [plsBeginPaint, plsEndPaint, plsBackground];
end;

{ TProbeHighlighter }

constructor TProbeHighlighter.Create;
begin
  inherited Create;
  FCalls := TDictionary<string, Integer>.Create;
end;

destructor TProbeHighlighter.Destroy;
begin
  FCalls.Free;
  inherited;
end;

procedure TProbeHighlighter.Hit(const Name: string);
var Count: Integer;
begin
  if not FCalls.TryGetValue(Name, Count) then Count := 0;
  FCalls.AddOrSetValue(Name, Count + 1);
end;

function TProbeHighlighter.Summary: string;
var Names: TArray<string>; Name: string;
begin
  Result := '';
  Names := FCalls.Keys.ToArray;
  TArray.Sort<string>(Names);
  for Name in Names do
    Result := Result + Format('%s=%d; ', [Name, FCalls[Name]]);
end;

function TProbeHighlighter.QueryInterface(const IID: TGUID; out Obj): HResult;
begin
  // Every interface the IDE asks this highlighter for is evidence of what it can use.
  if GetInterface(IID, Obj) then
  begin
    Hit('QI ' + GUIDToString(IID) + ' ok');
    Result := S_OK;
  end
  else
  begin
    Hit('QI ' + GUIDToString(IID) + ' recusada');
    Result := E_NOINTERFACE;
  end;
end;

function TProbeHighlighter.GetIDString: string;
begin Hit('GetIDString'); Result := 'BFProbe.Highlighter'; end;
function TProbeHighlighter.GetName: string;
begin Hit('GetName'); Result := 'BFProbe'; end;

procedure TProbeHighlighter.Tokenize(StartClass: TOTALineClass; LineBuf: POTAEdChar; LineBufLen: TOTALineSize;
  HighlightCodes: POTASyntaxCode);
begin
  Hit('Tokenize');
  if LineBufLen > 0 then FillChar(HighlightCodes^, LineBufLen, atIdentifier);
end;

function TProbeHighlighter.TokenizeLineClass(StartClass: TOTALineClass; LineBuf: POTAEdChar;
  LineBufLen: TOTALineSize): TOTALineClass;
begin Hit('TokenizeLineClass'); Result := 0; end;

function TProbeHighlighter.GetDisplayName: string;
begin Hit('GetDisplayName'); Result := 'BFProbe'; end;
function TProbeHighlighter.GetSampleText: string;
begin
  Hit('GetSampleText');
  Result := 'line 1'#13#10'begin'#13#10'  inner 3'#13#10'  inner 4'#13#10'end'#13#10'line 6'#13#10;
end;
function TProbeHighlighter.GetInvalidBreakpointLine: Integer;
begin Hit('GetInvalidBreakpointLine'); Result := -1; end;
function TProbeHighlighter.GetCurrentInstructionLine: Integer;
begin Hit('GetCurrentInstructionLine'); Result := -1; end;
function TProbeHighlighter.GetValidBreakpointLine: Integer;
begin Hit('GetValidBreakpointLine'); Result := -1; end;
function TProbeHighlighter.GetDisabledBreakpointLine: Integer;
begin Hit('GetDisabledBreakpointLine'); Result := -1; end;
function TProbeHighlighter.GetErrorLine: Integer;
begin Hit('GetErrorLine'); Result := -1; end;
function TProbeHighlighter.GetSampleSearchText: string;
begin Hit('GetSampleSearchText'); Result := ''; end;
function TProbeHighlighter.GetBlockStartLine: Integer;
begin Hit('GetBlockStartLine'); Result := 1; end;
function TProbeHighlighter.GetBlockStartCol: Integer;
begin Hit('GetBlockStartCol'); Result := 1; end;
function TProbeHighlighter.GetBlockEndLine: Integer;
begin Hit('GetBlockEndLine'); Result := 1; end;
function TProbeHighlighter.GetBlockEndCol: Integer;
begin Hit('GetBlockEndCol'); Result := 3; end;
function TProbeHighlighter.GetElidableBlockStartLine: Integer;
begin Hit('GetElidableBlockStartLine'); Result := 2; end;
function TProbeHighlighter.GetElidableBlockStartCol: Integer;
begin Hit('GetElidableBlockStartCol'); Result := 1; end;
function TProbeHighlighter.GetElidableBlockEndLine: Integer;
begin Hit('GetElidableBlockEndLine'); Result := 5; end;
function TProbeHighlighter.GetElidableBlockEndCol: Integer;
begin Hit('GetElidableBlockEndCol'); Result := 4; end;
function TProbeHighlighter.GetElidedBlockStartLine: Integer;
begin Hit('GetElidedBlockStartLine'); Result := -1; end;
function TProbeHighlighter.GetElidedBlockStartCol: Integer;
begin Hit('GetElidedBlockStartCol'); Result := -1; end;
function TProbeHighlighter.GetElidedBlockEndLine: Integer;
begin Hit('GetElidedBlockEndLine'); Result := -1; end;
function TProbeHighlighter.GetElidedBlockEndCol: Integer;
begin Hit('GetElidedBlockEndCol'); Result := -1; end;
function TProbeHighlighter.GetElidedBlockDescription: String;
begin Hit('GetElidedBlockDescription'); Result := 'bfprobe'; end;
function TProbeHighlighter.GetElidableBlockDescription: String;
begin Hit('GetElidableBlockDescription'); Result := 'bfprobe'; end;

{ Dialog watching: nobody is there to answer a dialog of the test IDE. }

var
  WatchFound: HWND;
  WatchTexts: TStrings;

function FindDialog(Window: HWND; Param: LPARAM): BOOL; stdcall;
var Name: array[0..63] of Char; Control: TWinControl;
begin
  Result := True;
  if not IsWindowVisible(Window) or not IsWindowEnabled(Window) then Exit;
  GetClassName(Window, Name, Length(Name));
  Control := FindControl(Window);
  if (StrComp(Name, '#32770') = 0) or
    ((Control is TCustomForm) and (fsModal in TCustomForm(Control).FormState)) then
  begin
    WatchFound := Window;
    Result := False;
  end;
end;

function CollectText(Window: HWND; Param: LPARAM): BOOL; stdcall;
var Text: array[0..511] of Char;
begin
  Result := True;
  if IsWindowVisible(Window) and (GetWindowText(Window, Text, Length(Text)) > 0) then
    WatchTexts.Add(Text);
end;

procedure TProbe.WatchDialogs(Sender: TObject);
const Answers: array[0..2] of Integer = (IDOK, IDNO, IDCANCEL);
var Found: HWND; Texts: TStringList; Caption: array[0..255] of Char; Control: TWinControl;
begin
  WatchFound := 0;
  EnumThreadWindows(MainThreadID, @FindDialog, 0);
  Found := WatchFound;
  if (Found = 0) or (Found <> FWatchWindow) then
  begin
    FWatchWindow := Found; FWatchTicks := 0; FWatchAttempts := 0;
    Exit;
  end;
  Inc(FWatchTicks);
  if FWatchTicks < FWatchPatience then Exit;
  if FWatchAttempts = 0 then
  begin
    Texts := TStringList.Create;
    try
      Caption[0] := #0; GetWindowText(Found, Caption, Length(Caption));
      WatchTexts := Texts;
      EnumChildWindows(Found, @CollectText, 0);
      Note('DIALOGO | fechado pela sonda: "' + Caption + '" | ' +
        StringReplace(Trim(Texts.Text), sLineBreak, ' // ', [rfReplaceAll]));
      // Its text may be drawn, not held by a child window: keep a picture of it.
      Inc(FDialogShots);
      if FDialogShots <= 4 then CaptureWindow(Found, 'dialogo-' + IntToStr(FDialogShots));
    finally Texts.Free; end;
  end;
  Control := FindControl(Found);
  if (Control is TCustomForm) and (fsModal in TCustomForm(Control).FormState) and (FWatchAttempts = 0) then
    TCustomForm(Control).ModalResult := mrNo
  else if FWatchAttempts <= High(Answers) then PostMessage(Found, WM_COMMAND, WPARAM(Answers[FWatchAttempts]), 0)
  else PostMessage(Found, WM_CLOSE, 0, 0);
  Inc(FWatchAttempts);
end;

{ TProbe }

constructor TProbe.Create(const ReportFile: string);
begin
  inherited Create;
  FReportFile := ReportFile;
  FDir := ExtractFileDir(ReportFile);
  FSample := GetEnvironmentVariable('BFPROBE_SAMPLE');
  FMode := GetEnvironmentVariable('BFPROBE_MODE');
  FRealInput := GetEnvironmentVariable('BFPROBE_INPUT') = 'real';
  FReport := TStringList.Create;
  FRtti := TStringList.Create;
  FHits := TStringList.Create;
  FLines := TStringList.Create;
  FEvents := TStringList.Create;
  FMarkers := TList<TMarker>.Create;
  FVisited := TList<TClass>.Create;
  FKept := TList<TKept>.Create;
  FRows := TDictionary<Integer, Integer>.Create;
  FRowMarks := TDictionary<Integer, string>.Create;
  FTint := TBitmap.Create;
  FTint.PixelFormat := pf24bit;
  FTint.SetSize(1, 1);
  FTint.Canvas.Pixels[0, 0] := RGB(70, 130, 255);
  FCtx := TRttiContext.Create;
  FWatchPatience := 4;
  FTimer := TTimer.Create(nil);
  FTimer.Interval := 1000; FTimer.OnTimer := Tick; FTimer.Enabled := True;
  FWatch := TTimer.Create(FTimer);
  FWatch.Interval := 1000; FWatch.OnTimer := WatchDialogs; FWatch.Enabled := True;
end;

destructor TProbe.Destroy;
begin
  FTimer.Free; FTint.Free; FRowMarks.Free; FRows.Free; FVisited.Free; FMarkers.Free; FEvents.Free; FLines.Free; FHits.Free; FRtti.Free; FReport.Free;
  inherited;
end;

procedure TProbe.Note(const Text: string);
var Attempt: Integer;
begin
  FReport.Add(Text);
  // Written at every step so a hang or crash still leaves what was observed so far.
  // The driving script reads the file while it waits, so a write may have to wait its turn.
  for Attempt := 1 to 40 do
    try
      FReport.SaveToFile(FReportFile, TEncoding.UTF8);
      Break;
    except
      on E: EStreamError do Sleep(25);
    end;
end;

procedure TProbe.Tick(Sender: TObject);
begin
  if FRunning then Exit;
  Inc(FTicks);
  if (FTicks < 8) or (Application.MainForm = nil) or not Application.MainForm.Visible or
    (BorlandIDEServices = nil) then Exit;
  FRunning := True; FTimer.Enabled := False;
  try
    Run;
  except
    on E: Exception do Note('EXCECAO | execucao da sonda | ' + E.ClassName + ': ' + E.Message);
  end;
  try
    FRtti.SaveToFile(TPath.Combine(FDir, 'rtti.txt'), TEncoding.UTF8);
  except
  end;
  Note('DONE | fim');
  // Last test of the prototype: the IDE is asked to close while the fold is active.
  if SameText(FMode, 'fold') then PostMessage(Application.MainForm.Handle, WM_CLOSE, 0, 0);
end;

procedure TProbe.LoadSample;
var I, P, First: Integer; Item: TMarker; Line: string;
begin
  FLines.LoadFromFile(FSample);
  for I := 0 to FLines.Count - 1 do
  begin
    Line := FLines[I];
    P := Pos('//@', Line);
    if P = 0 then Continue;
    First := 1;
    while (First <= Length(Line)) and (Line[First] = ' ') do Inc(First);
    Item.Name := Trim(Copy(Line, P + 3, MaxInt));
    Item.Line := I + 1;
    // One column into the first token of the line.
    Item.Col := First + 1;
    FMarkers.Add(Item);
  end;
end;

function TProbe.Marker(const Name: string): TMarker;
var Item: TMarker;
begin
  for Item in FMarkers do
    if Item.Name = Name then Exit(Item);
  raise Exception.Create('Marcador nao encontrado na unit de exemplo: ' + Name);
end;

function TProbe.OpenAndBind(const FileName: string): Boolean;
var Waited: Integer; Top: IOTAEditView;
begin
  Result := False;
  FView := nil; FEditor := nil;
  (BorlandIDEServices as IOTAActionServices).OpenFile(FileName);
  for Waited := 1 to 60 do
  begin
    Pump(500);
    Top := (BorlandIDEServices as IOTAEditorServices).TopView;
    if (Top <> nil) and (Top.Buffer <> nil) and SameText(Top.Buffer.FileName, FileName) then
    begin
      FView := Top;
      Break;
    end;
  end;
  if FView = nil then Exit;
  FEditor := FServices.GetEditorForView(FView);
  if FEditor = nil then FEditor := FServices.TopEditor;
  Result := FEditor <> nil;
end;

function TProbe.State: INTACodeEditorState;
begin
  Result := FServices.GetEditorState(FEditor);
  {$IF CompilerVersion >= 36}
  if Result <> nil then Result.Refresh;
  {$IFEND}
end;

procedure TProbe.SetCursor(Line, Col: Integer);
var Position: TOTAEditPos;
begin
  Position.Line := Line; Position.Col := Col;
  FView.CursorPos := Position;
  FView.MoveViewToCursor;
  FView.Paint;
end;

// The logical line of every row on screen, from the given top line: a jump in
// the sequence is a range of hidden lines.
function TProbe.VisibleRows(Top: Integer): string;
var Current: INTACodeEditorState; Row, Previous, Logical, Rows: Integer; LineState: INTACodeEditorLineState;
  Position: TOTAEditPos; Found: string;
begin
  Position.Line := Top; Position.Col := 1;
  FView.TopPos := Position;
  FView.Paint;
  Pump(200);
  Current := State;
  Found := ''; Previous := -1; Rows := 0;
  for Row := Current.TopLine to Current.BottomLine do
  begin
    LineState := Current.LineState[Row];
    if LineState = nil then Continue;
    Inc(Rows);
    Logical := LineState.LogicalLineNum;
    if (Previous > 0) and (Logical > Previous + 1) then
      Found := Found + Format(' OCULTAS[%d..%d]', [Previous + 1, Logical - 1]);
    if LineState.IsElidedLine then
      Found := Found + Format(' marcador-na-linha-%d(ElidedLineStart=%d ElidedLineEnd=%d)',
        [Logical, LineState.ElidedLineStart, LineState.ElidedLineEnd]);
    Previous := Logical;
  end;
  if Found = '' then Found := ' nenhuma linha oculta';
  Result := Format('TopLine=%d BottomLine=%d linhas-na-tela=%d ultima-logica=%d |%s',
    [Current.TopLine, Current.BottomLine, Rows, Previous, Found]);
end;

// The same question asked line by line, for the whole unit.
function TProbe.HiddenByQuery: string;
var Current: INTACodeEditorState; Line: Integer; A, B, C: string; LineState: INTACodeEditorLineState;

  procedure Add(var Text: string; Value: Integer);
  begin
    if Text <> '' then Text := Text + ',';
    Text := Text + IntToStr(Value);
  end;

begin
  Current := State;
  A := ''; B := ''; C := '';
  for Line := 1 to FLines.Count do
  begin
    try
      if not Current.IsLogicalLineVisible(Line) then Add(A, Line);
      if not Current.IsLineVisible(Line) then Add(B, Line);
      LineState := Current.LogicalLineState[Line];
      if (LineState <> nil) and LineState.IsElidedLine then
        C := C + Format(' %d(%d..%d)', [Line, LineState.ElidedLineStart, LineState.ElidedLineEnd]);
    except
      on E: Exception do C := C + Format(' %d!%s', [Line, E.ClassName]);
    end;
  end;
  Result := Format('IsLogicalLineVisible=False em [%s] | IsLineVisible=False em [%s] | LogicalLineState.IsElidedLine em [%s ]',
    [A, B, C]);
end;

// The same again, from what the IDE reports while it repaints: this does not
// depend on the editor state object, which Delphi 11 does not refresh.
function TProbe.PaintedRows: string;
var Rows: TArray<Integer>; Row, Previous, Logical: Integer; Found, Mark: string;
begin
  FRows.Clear; FRowMarks.Clear;
  FServices.InvalidateEditor(FEditor);
  FEditor.Update;
  Pump(300);
  Rows := FRows.Keys.ToArray;
  TArray.Sort<Integer>(Rows);
  Found := ''; Previous := -1;
  for Row in Rows do
  begin
    Logical := FRows[Row];
    if (Previous > 0) and (Logical > Previous + 1) then
      Found := Found + Format(' OCULTAS[%d..%d]', [Previous + 1, Logical - 1]);
    if FRowMarks.TryGetValue(Row, Mark) then Found := Found + Format(' marcador-na-linha-%d%s', [Logical, Mark]);
    Previous := Logical;
  end;
  if Found = '' then Found := ' nenhuma linha oculta';
  Result := Format('linhas pintadas=%d ultima-logica=%d |%s', [Length(Rows), Previous, Found]);
end;

// Picture of the editor control as shown on screen. Returns how many pixels
// have the exact colour the painting test draws with.
function TProbe.Capture(const Name: string): Integer;
var Form: TCustomForm; Bounds: TRect; Bitmap: TBitmap; Png: TPngImage; X, Y: Integer; Row: PByteArray;
  Root: HWND; Desktop: HDC;
begin
  Result := -1;
  Form := GetParentForm(FEditor);
  if Form = nil then Exit;
  // Read from the window itself, so the test IDE is not brought in front of what the user is doing.
  FEditor.Update;
  Pump(300);
  GetWindowRect(FEditor.Handle, Bounds);
  Bitmap := TBitmap.Create; Png := TPngImage.Create;
  try
    // From the screen, as the user would see it: the window has to be in front for a moment.
    Root := GetAncestor(FEditor.Handle, GA_ROOT);
    SetWindowPos(Root, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE or SWP_NOSIZE or SWP_NOACTIVATE);
    try
      FEditor.Update;
      Pump(500);
      GetWindowRect(FEditor.Handle, Bounds);
      Bitmap.PixelFormat := pf24bit;
      Bitmap.SetSize(Bounds.Width, Bounds.Height);
      Desktop := GetDC(0);
      try
        BitBlt(Bitmap.Canvas.Handle, 0, 0, Bounds.Width, Bounds.Height, Desktop, Bounds.Left, Bounds.Top, SRCCOPY);
      finally ReleaseDC(0, Desktop); end;
    finally
      SetWindowPos(Root, HWND_NOTOPMOST, 0, 0, 0, 0, SWP_NOMOVE or SWP_NOSIZE or SWP_NOACTIVATE);
    end;
    Result := 0;
    for Y := 0 to Bitmap.Height - 1 do
    begin
      Row := Bitmap.ScanLine[Y];
      for X := 0 to Bitmap.Width - 1 do
        if (Row[X * 3] = 255) and (Row[X * 3 + 1] = 0) and (Row[X * 3 + 2] = 255) then Inc(Result);
    end;
    Png.Assign(Bitmap);
    Png.SaveToFile(TPath.Combine(FDir, Name + '.png'));
    Note(Format('CAPTURA | %s.png | %dx%d | pixels magenta=%d', [Name, Bitmap.Width, Bitmap.Height, Result]));
  finally
    Png.Free; Bitmap.Free;
  end;
end;

procedure TProbe.OnElided(const Editor: TWinControl; const LogicalLineNum: Integer);
begin
  FEvents.Add('EditorElided(' + IntToStr(LogicalLineNum) + ')');
end;

procedure TProbe.OnUnElided(const Editor: TWinControl; const LogicalLineNum: Integer);
begin
  FEvents.Add('EditorUnElided(' + IntToStr(LogicalLineNum) + ')');
end;

procedure TProbe.OnPaintLine(const Rect: TRect; const Stage: TPaintLineStage; const BeforeEvent: Boolean;
  var AllowDefaultPainting: Boolean; const Context: INTACodeEditorPaintContext);
var Logical, X, Middle: Integer; Cell, Code: TRect; Canvas: TCanvas; Blend: TBlendFunction;
begin
  Inc(FPaintCalls);
  // What the IDE itself says it is painting: screen row and logical line of each row.
  if Stage = plsBeginPaint then
  begin
    // While a fold is being kept: a line of the block that gets painted was seen open by the user.
    if FKeep and (Context.EditControl = FEditor) and (Context.LogicalLineNum > FFoldFirst) and
      (Context.LogicalLineNum <= FFoldLast) then
    begin
      Inc(FOpenLines);
      if GetTickCount64 - FLastOpen > 30 then Inc(FOpenEpisodes);
      FLastOpen := GetTickCount64;
    end;
    FRows.AddOrSetValue(Context.EditorLineNum, Context.LogicalLineNum);
    if (Context.LineState <> nil) and Context.LineState.IsElidedLine then
      FRowMarks.AddOrSetValue(Context.EditorLineNum, Format('(ElidedLineStart=%d ElidedLineEnd=%d)',
        [Context.LineState.ElidedLineStart, Context.LineState.ElidedLineEnd]));
  end;
  if not FPaintOn then Exit;
  Logical := Context.LogicalLineNum;
  // With a fold active: one line per screen row near the block, whatever logical line the IDE reports.
  if FLogAnyLine and (Stage = plsEndPaint) and not BeforeEvent and (Context.EditorLineNum >= 19) and
    (Context.EditorLineNum <= 27) and (Context.LineState <> nil) then
    Note(Format('  com dobra: linha-de-tela=%d logica=%d Rect=%s CodeRect=%s celula(col %d, linha-de-tela)=%s celula(col %d, linha logica)=%s texto="%s"',
      [Context.EditorLineNum, Logical, RectText(Rect), RectText(Context.LineState.CodeRect), FGuideCol,
       RectText(Context.EditorState.GetCharacterPosPx(FGuideCol, Context.EditorLineNum)), FGuideCol,
       RectText(Context.EditorState.GetCharacterPosPx(FGuideCol, Logical)), Trim(Context.LineState.Text)]));
  if (Logical < FGuideFrom) or (Logical > FGuideTo) then Exit;
  Canvas := Context.Canvas;
  Cell := Context.EditorState.GetCharacterPosPx(FGuideCol, Context.EditorLineNum);
  if Context.LineState <> nil then Code := Context.LineState.CodeRect else Code := Rect;
  if FPaintLogged < 9 then
  begin
    Inc(FPaintLogged);
    Note(Format('  PaintLine stage=%s before=%s logica=%d linha-editor=%d Rect=%s CodeRect=%s celula(col %d)=%s',
      [GetEnumName(TypeInfo(TPaintLineStage), Ord(Stage)), BoolToStr(BeforeEvent, True), Logical,
       Context.EditorLineNum, RectText(Rect), RectText(Code), FGuideCol, RectText(Cell)]));
  end;
  if (Stage = plsEndPaint) and not BeforeEvent then
  begin
    // Block guide: a vertical line at the column of the block, with a tick at both ends.
    // Block highlight: a translucent band over the lines of the block.
    Blend.BlendOp := AC_SRC_OVER; Blend.BlendFlags := 0; Blend.SourceConstantAlpha := 56; Blend.AlphaFormat := 0;
    Winapi.Windows.AlphaBlend(Canvas.Handle, Cell.Left, Code.Top, Code.Right - Cell.Left, Code.Bottom - Code.Top,
      FTint.Canvas.Handle, 0, 0, 1, 1, Blend);
    X := Cell.Left + 1;
    Canvas.Pen.Style := psSolid; Canvas.Pen.Width := 2; Canvas.Pen.Color := clFuchsia;
    Canvas.MoveTo(X, Code.Top); Canvas.LineTo(X, Code.Bottom);
    if (Logical = FGuideFrom) or (Logical = FGuideTo) then
    begin
      Middle := (Code.Top + Code.Bottom) div 2;
      Canvas.MoveTo(X, Middle); Canvas.LineTo(X + 14, Middle);
    end;
    Inc(FPaintDrawn);
  end;
end;

procedure TProbe.RunEnvironment;
var Elide: IOTAElideActions; Old120: IOTAElideActions120; Old150: IOTAElideActions150;
begin
  Note('== AMBIENTE (observado dentro da IDE)');
  Note(Format('IDE | %s | %d bits | CompilerVersion %.1f', [ParamStr(0), SizeOf(Pointer) * 8, CompilerVersion]));
  Note('IDE | chave de registro em uso: ' + (BorlandIDEServices as IOTAServices).GetBaseRegistryKey);
  Note('IDE | unit de exemplo: ' + FSample + ' | linhas: ' + IntToStr(FLines.Count));
  Note(Format('EDITOR | controle %s | view %s | buffer %s', [FEditor.ClassType.QualifiedClassName,
    (FView as TObject).ClassType.QualifiedClassName, (FView.Buffer as TObject).ClassType.QualifiedClassName]));
  Note(Format('INTERFACES da view | IOTAElideActions=%s IOTAElideActions150=%s IOTAElideActions120=%s',
    [BoolToStr(Supports(FView, IOTAElideActions, Elide), True), BoolToStr(Supports(FView, IOTAElideActions150, Old150), True),
     BoolToStr(Supports(FView, IOTAElideActions120, Old120), True)]));
end;

procedure TProbe.RunRegions(const Module: IOTAModule);
const Kinds: array[0..7] of string = ('rkRegion', 'rkIf', 'rkNameSpace', 'rkType', 'rkMethod', 'rkNestedMethod',
  'rkGlobal', 'rkDocumentation');
var Regions: IOTAModuleRegions; List: TOTARegions; Waited, I: Integer; Kind, Text: string;
begin
  Note('== REGIOES QUE A IDE CONHECE (IOTAModuleRegions.GetRegions, observado)');
  if not Supports(Module, IOTAModuleRegions, Regions) then
  begin
    Note('REGIOES | o modulo nao implementa IOTAModuleRegions');
    Exit;
  end;
  // The list comes from the background parser, so it may take a while to appear.
  List := nil;
  for Waited := 0 to 40 do
  begin
    List := Regions.GetRegions(FView.Buffer.FileName);
    if Length(List) > 0 then Break;
    Pump(500);
  end;
  Pump(1500);
  List := Regions.GetRegions(FView.Buffer.FileName);
  Note(Format('REGIOES | %d regioes, depois de esperar %d ms', [Length(List), Waited * 500 + 1500]));
  for I := 0 to High(List) do
  begin
    if (List[I].RegionKind >= 0) and (List[I].RegionKind <= High(Kinds)) then Kind := Kinds[List[I].RegionKind]
    else Kind := 'kind ' + IntToStr(List[I].RegionKind);
    Text := '';
    if (List[I].Start.Line >= 1) and (List[I].Start.Line <= FLines.Count) then
      Text := Trim(FLines[List[I].Start.Line - 1]);
    Note(Format('REGIAO | %-15s linhas %d..%d (col %d..%d) ativa=%s nome="%s" | inicio: %s', [Kind, List[I].Start.Line,
      List[I].Stop.Line, List[I].Start.CharIndex, List[I].Stop.CharIndex, BoolToStr(List[I].Active, True), List[I].Name, Text]));
  end;
end;

// Kept apart so that the reference to the buffer made here ends with this call.
procedure TProbe.RunRegionsOfView;
begin
  RunRegions(FView.Buffer.Module);
end;

procedure TProbe.RunNearestBlock;
var Elide: IOTAElideActions; Item: TMarker;

  procedure Observe(const Title: string);
  begin
    FView.Paint;
    Pump(400);
    Note(Title);
    Note('     tela: ' + VisibleRows(1));
    Note('     consulta: ' + HiddenByQuery);
    Note('     pintura: ' + PaintedRows);
    Note('     eventos: ' + FEvents.CommaText);
    FEvents.Clear;
  end;

begin
  Note('== PERGUNTA 1: ElideNearestBlock com o cursor em cada bloco (observado)');
  if not Supports(FView, IOTAElideActions, Elide) then
  begin
    Note('Q1 | a view nao implementa IOTAElideActions');
    Exit;
  end;
  Elide.UnElideAllBlocks;
  Observe('Q1 | estado inicial, depois de UnElideAllBlocks');
  // Baseline: folds the IDE is known to make, to prove the readings detect a fold.
  Elide.ElideMethods;
  Observe('Q1 | controle: ElideMethods');
  Elide.UnElideAllBlocks; Pump(200); FEvents.Clear;
  Elide.ElideRegions;
  Observe('Q1 | controle: ElideRegions');
  for Item in FMarkers do
  begin
    Elide.UnElideAllBlocks;
    Pump(200);
    FEvents.Clear;
    SetCursor(Item.Line, Item.Col);
    Pump(150);
    Elide.ElideNearestBlock;
    Observe(Format('Q1 | ElideNearestBlock | %-13s | cursor linha %d col %d | %s', [Item.Name, Item.Line, Item.Col,
      Trim(FLines[Item.Line - 1])]));
    if Item.Name = 'if-body' then
    begin
      Capture('q1-if-body');
      // Does a second call climb to the next enclosing block?
      SetCursor(Item.Line, Item.Col);
      Pump(150);
      Elide.ElideNearestBlock;
      Observe('Q1 | ElideNearestBlock chamado de novo no mesmo ponto (if-body)');
    end;
  end;
  Elide.UnElideAllBlocks;
  Observe('Q1 | estado final, depois de UnElideAllBlocks');
end;

procedure TProbe.RunPainting;
var Magenta: Integer; Elide: IOTAElideActions;
begin
  Note('== PERGUNTA 5: guia e destaque de bloco pintados com INTACodeEditorEvents (observado)');
  FGuideFrom := Marker('for-begin').Line;
  FGuideTo := Marker('for-end').Line;
  FGuideCol := Marker('for-begin').Col - 1;
  Magenta := Capture('q5-antes');
  Note(Format('Q5 | antes de pintar: PaintLine recebido %d vezes desde o inicio, pixels magenta=%d', [FPaintCalls, Magenta]));
  FPaintOn := True;
  SetCursor(FGuideFrom, 1);
  FServices.InvalidateEditor(FEditor);
  VisibleRows(1);
  Pump(500);
  Magenta := Capture('q5-guia');
  Note(Format('Q5 | bloco linhas %d..%d coluna %d | linhas pintadas=%d | pixels magenta na tela=%d', [FGuideFrom, FGuideTo,
    FGuideCol, FPaintDrawn, Magenta]));
  // The guide below a real fold: the nested procedure above the block is folded by the IDE.
  if Supports(FView, IOTAElideActions, Elide) then
  begin
    SetCursor(Marker('nested-body').Line, Marker('nested-body').Col);
    Elide.ElideNearestBlock;
    // Log again what the IDE reports for the rows of the block while the fold is active.
    FPaintLogged := 0;
    FLogAnyLine := True;
    FServices.InvalidateEditor(FEditor);
    VisibleRows(1);
    Pump(500);
    Magenta := Capture('q5-guia-com-dobra');
    Note(Format('Q5 | com uma dobra da IDE ativa: pixels magenta na tela=%d | pintura: %s', [Magenta, PaintedRows]));
    FLogAnyLine := False;
    Elide.UnElideAllBlocks;
  end;
  FPaintOn := False;
  FServices.InvalidateEditor(FEditor);
  Pump(400);
  Magenta := Capture('q5-depois');
  Note(Format('Q5 | pintura desligada: pixels magenta na tela=%d', [Magenta]));
end;

procedure TProbe.R(const Text: string);
begin
  FRtti.Add(Text);
end;

function IsBaseUnit(const UnitName: string): Boolean;
begin
  Result := (Pos('System', UnitName) = 1) or (Pos('Vcl.', UnitName) = 1) or (Pos('Winapi.', UnitName) = 1);
end;

procedure TProbe.DumpObject(Obj: TObject; const Path: string; Depth: Integer);
type
  TChild = record
    Path: string;
    Obj: TObject;
  end;
var ClassRef: TClass; RttiType: TRttiType; Instance: TRttiInstanceType; Field: TRttiField; Method: TRttiMethod;
  Prop: TRttiProperty; Indexed: TRttiIndexedProperty; Children: TList<TChild>; Child: TChild; Table: PInterfaceTable;
  I: Integer; ClassTitle, Detail: string; Intf: IInterface;

  procedure Item(const Kind, Name, Text: string);
  var Line: string;
  begin
    Line := Format('     %s %s: %s', [Kind, Name, Text]);
    R(Line);
    if TRegEx.IsMatch(Name + ' ' + Text, HitPattern) then
      FHits.Add(Format('%s | %s |%s', [Path, ClassTitle, Line]));
  end;

begin
  if Obj = nil then begin R(''); R('=== ' + Path + ' : nil'); Exit; end;
  try
    ClassRef := Obj.ClassType;
    R('');
    R(Format('=== %s : %s  (modulo %s)', [Path, ClassRef.QualifiedClassName,
      ExtractFileName(GetModuleName(FindHInstance(ClassRef)))]));
    if FVisited.Contains(ClassRef) then begin R('  (classe ja listada acima)'); Exit; end;
    if FVisited.Count >= MaxRttiClasses then begin R('  (limite de classes atingido)'); Exit; end;
    FVisited.Add(ClassRef);
    if TRegEx.IsMatch(ClassRef.QualifiedClassName, HitPattern) then
      FHits.Add(Format('%s | classe %s', [Path, ClassRef.QualifiedClassName]));
    Children := TList<TChild>.Create;
    try
      RttiType := FCtx.GetType(ClassRef);
      while RttiType is TRttiInstanceType do
      begin
        Instance := TRttiInstanceType(RttiType);
        ClassTitle := Instance.MetaclassType.QualifiedClassName;
        if IsBaseUnit(Instance.MetaclassType.UnitName) then
        begin
          R('  -- herda de ' + ClassTitle + ' (base RTL/VCL, nao listada)');
          Break;
        end;
        R(Format('  -- classe %s  InstanceSize=%d', [ClassTitle, Instance.MetaclassType.InstanceSize]));
        Table := Instance.MetaclassType.GetInterfaceTable;
        if Table <> nil then
          for I := 0 to Table.EntryCount - 1 do
            R('     interface ' + GUIDToString(Table.Entries[I].IID));
        for Field in Instance.GetDeclaredFields do
        begin
          if Field.FieldType <> nil then Detail := Field.FieldType.Name else Detail := '(sem RTTI de tipo)';
          Item('campo', Field.Name, Format('%s @%d', [Detail, Field.Offset]));
          if Field.FieldType = nil then Continue;
          try
            Child.Obj := nil;
            if Field.FieldType.TypeKind = tkClass then Child.Obj := Field.GetValue(Obj).AsObject
            else if Field.FieldType.TypeKind = tkInterface then
            begin
              Intf := Field.GetValue(Obj).AsInterface;
              if Intf <> nil then Child.Obj := Intf as TObject;
            end;
            if Child.Obj <> nil then
            begin
              Child.Path := Path + '.' + Field.Name;
              Children.Add(Child);
            end;
          except
          end;
        end;
        for Method in Instance.GetDeclaredMethods do
        begin
          try Detail := Method.ToString; except Detail := '(assinatura sem RTTI)'; end;
          Item('metodo', Method.Name, Format('%s  [%s]', [Detail,
            GetEnumName(TypeInfo(TMemberVisibility), Ord(Method.Visibility))]));
        end;
        for Prop in Instance.GetDeclaredProperties do
        begin
          try Detail := Prop.ToString; except Detail := '(sem RTTI)'; end;
          Item('propriedade', Prop.Name, Detail);
        end;
        for Indexed in Instance.GetDeclaredIndexedProperties do
        begin
          try Detail := Indexed.ToString; except Detail := '(sem RTTI)'; end;
          Item('propriedade-indexada', Indexed.Name, Detail);
        end;
        RttiType := Instance.BaseType;
      end;
      if Depth < MaxRttiDepth then
        for Child in Children do
          try
            if not IsBaseUnit(Child.Obj.UnitName) then DumpObject(Child.Obj, Child.Path, Depth + 1);
          except
            on E: Exception do R('  (falha ao seguir ' + Child.Path + ': ' + E.ClassName + ')');
          end;
    finally Children.Free; end;
  except
    on E: Exception do R('  (falha ao listar ' + Path + ': ' + E.ClassName + ': ' + E.Message + ')');
  end;
end;

procedure TProbe.RunRtti;
var Hit: string; Current: INTACodeEditorState; Module: IOTAModule;
begin
  Note('== PERGUNTA 2: RTTI das classes internas do editor (observado, somente leitura)');
  Current := State;
  Module := FView.Buffer.Module;
  DumpObject(FEditor, 'ControleDoEditor', 0);
  DumpObject(FView as TObject, 'View', 0);
  DumpObject(FView.Buffer as TObject, 'Buffer', 0);
  DumpObject(Module as TObject, 'Modulo', 0);
  DumpObject(FServices as TObject, 'CodeEditorServices', 0);
  DumpObject(Current as TObject, 'EditorState', 0);
  if Current.LineState[Current.TopLine] <> nil then
    DumpObject(Current.LineState[Current.TopLine] as TObject, 'LineState', 0);
  DumpObject((BorlandIDEServices as IOTAEditorServices) as TObject, 'EditorServices', 0);
  FRtti.SaveToFile(TPath.Combine(FDir, 'rtti.txt'), TEncoding.UTF8);
  Note(Format('Q2 | classes listadas: %d | listagem completa em rtti.txt (%d linhas) | nomes com %s: %d',
    [FVisited.Count, FRtti.Count, HitPattern, FHits.Count]));
  for Hit in FHits do Note('Q2 | ' + Hit);
end;

procedure TProbe.RunHighlighter;
var Services: IOTAHighlightServices; Editors: IOTAEditorServices; Options: IOTAEditOptions; Highlighter: TProbeHighlighter;
  Intf: IOTAHighlighter; Index, I: Integer; FileName: string; Elide: IOTAElideActions; Regions: IOTAModuleRegions;
  Position: TOTAEditPos; Preview: IOTAElisionPreview;
begin
  Note('== PERGUNTA 4: highlighter proprio informando pontos de dobra (observado)');
  Services := BorlandIDEServices as IOTAHighlightServices;
  Editors := BorlandIDEServices as IOTAEditorServices;
  Highlighter := TProbeHighlighter.Create;
  Intf := Highlighter;
  // Control: a query made here must show up in the call log, or the log proves nothing.
  Supports(Intf, IOTAElisionPreview, Preview);
  Preview := nil;
  Note('Q4 | controle do registro de QueryInterface (uma consulta feita pela propria sonda): ' + Highlighter.Summary);
  Index := Services.AddHighlighter(Intf);
  Note(Format('Q4 | AddHighlighter devolveu %d | highlighters registrados: %d', [Index, Services.HighlighterCount]));
  Options := Editors.AddEditOptions('BFProbeHL');
  Options.OptionsName := 'BFProbe';
  Options.Extensions := 'bfp';
  Options.SyntaxHighlighter := Intf;
  FileName := ChangeFileExt(FSample, '.bfp');
  TFile.WriteAllText(FileName, 'line 1'#13#10'begin'#13#10'  inner 3'#13#10'  begin'#13#10'    inner 5'#13#10 +
    '  end'#13#10'  inner 7'#13#10'end'#13#10'line 9'#13#10, TEncoding.ASCII);
  FLines.LoadFromFile(FileName);
  if not OpenAndBind(FileName) then
  begin
    Note('Q4 | o arquivo .bfp nao abriu no editor');
    Exit;
  end;
  Pump(3000);
  Options := Editors.GetEditOptionsForFile(FileName);
  Note(Format('Q4 | arquivo aberto: %s | opcoes do arquivo: %s | highlighter do arquivo e o nosso: %s', [ExtractFileName(FileName),
    Options.IDString, BoolToStr(Options.SyntaxHighlighter = Intf, True)]));
  Note('Q4 | chamadas recebidas pelo highlighter com o arquivo aberto: ' + Highlighter.Summary);
  if Supports(FView.Buffer.Module, IOTAModuleRegions, Regions) then
    Note(Format('Q4 | IOTAModuleRegions do arquivo: %d regioes', [Length(Regions.GetRegions(FileName))]))
  else Note('Q4 | o modulo do arquivo nao implementa IOTAModuleRegions');
  if Supports(FView, IOTAElideActions, Elide) then
    for I := 2 to 5 do
    begin
      Elide.UnElideAllBlocks;
      Position.Line := I; Position.Col := 2;
      FView.CursorPos := Position;
      Elide.ElideNearestBlock;
      FView.Paint;
      Pump(300);
      Note(Format('Q4 | ElideNearestBlock no arquivo do highlighter, cursor linha %d | tela: %s | pintura: %s', [I, VisibleRows(1), PaintedRows]));
    end;
  Capture('q4-highlighter');
  Note('Q4 | chamadas recebidas pelo highlighter ao final: ' + Highlighter.Summary);
end;

// Layout of a type as RTTI describes it. Nothing is called or changed.
procedure TProbe.DescribeType(RttiType: TRttiType; const Indent: string; Depth: Integer);
var Field: TRttiField; Name: string; Names: string;
begin
  if RttiType = nil then begin Note(Indent + '(sem RTTI)'); Exit; end;
  Note(Format('%s%s | kind=%s | tamanho=%d', [Indent, RttiType.Name,
    GetEnumName(TypeInfo(TTypeKind), Ord(RttiType.TypeKind)), RttiType.TypeSize]));
  if Depth > 3 then Exit;
  if RttiType is TRttiRecordType then
    for Field in RttiType.GetFields do
    begin
      if Field.FieldType = nil then
        Note(Format('%s  campo %s @%d: (sem RTTI)', [Indent, Field.Name, Field.Offset]))
      else
      begin
        Note(Format('%s  campo %s @%d:', [Indent, Field.Name, Field.Offset]));
        DescribeType(Field.FieldType, Indent + '    ', Depth + 1);
      end;
    end
  else if RttiType is TRttiEnumerationType then
  begin
    Names := '';
    for Name in TRttiEnumerationType(RttiType).GetNames do Names := Names + Name + ' ';
    Note(Indent + '  valores: ' + Names);
  end
  else if RttiType is TRttiSetType then DescribeType(TRttiSetType(RttiType).ElementType, Indent + '  de ', Depth + 1)
  else if RttiType is TRttiDynamicArrayType then
    DescribeType(TRttiDynamicArrayType(RttiType).ElementType, Indent + '  elemento ', Depth + 1);
end;

procedure TProbe.RunLayout;
var Method: TRttiMethod; Param: TRttiParameter; Seen: TList<TRttiType>;
begin
  Note('== FORMATO DOS ARGUMENTOS DOS METODOS DE DOBRA (RTTI, somente leitura)');
  Seen := TList<TRttiType>.Create;
  try
    for Method in FCtx.GetType(FEditor.ClassType).GetMethods do
      if TRegEx.IsMatch(Method.Name, '(?i)^(AddElisionBlock|RemoveElisionBlock|Elide|UnElide|ClearAllElisions|IsInElisionBlock|BlockIsElided)$') then
      begin
        Note(Format('METODO | %s | convencao=%s | virtual=%s', [Method.ToString,
          GetEnumName(TypeInfo(TCallConv), Ord(Method.CallingConvention)),
          BoolToStr(Method.DispatchKind <> dkStatic, True)]));
        for Param in Method.GetParameters do
        begin
          Note(Format('   parametro %s | flags=%s', [Param.Name, SetToString(PTypeInfo(TypeInfo(TParamFlags)),
            Byte(Param.Flags), True)]));
          if (Param.ParamType <> nil) and not Seen.Contains(Param.ParamType) then
          begin
            Seen.Add(Param.ParamType);
            DescribeType(Param.ParamType, '      ', 0);
          end;
        end;
      end;
  finally Seen.Free; end;
end;

{ Prototype: a fold over an arbitrary range, through the public methods of the
  editor control found by RTTI. Nothing is hooked or patched. }

type
  // As RTTI describes Ek.TCharPos and Ek.TElisionDescription; checked before any call.
  TKernelCharPos = packed record
    Index: SmallInt;
    LineNum: Integer;
  end;
  TKernelElisionDescription = packed record
    ElisionType: Word;
    DescLen: Integer;
    BlockDesc: PAnsiChar;
  end;

const
  FoldDescription: AnsiString = 'bloco';

function TProbe.FoldMethod(const Name: string; ParamCount: Integer; FirstIsRecord: Boolean): TRttiMethod;
var Method: TRttiMethod; Params: TArray<TRttiParameter>;
begin
  for Method in FCtx.GetType(FEditor.ClassType).GetMethods do
  begin
    if not SameText(Method.Name, Name) then Continue;
    Params := Method.GetParameters;
    if Length(Params) <> ParamCount then Continue;
    if (ParamCount > 0) and ((Params[0].ParamType.TypeKind = tkRecord) <> FirstIsRecord) then Continue;
    Exit(Method);
  end;
  raise Exception.CreateFmt('Metodo interno nao encontrado: %s/%d', [Name, ParamCount]);
end;

function TProbe.CharPosArg(Method: TRttiMethod; ParamIndex, Index, Line: Integer): TValue;
var Position: TKernelCharPos; ParamType: TRttiType;
begin
  ParamType := Method.GetParameters[ParamIndex].ParamType;
  if (ParamType.Name <> 'TCharPos') or (ParamType.TypeSize <> SizeOf(TKernelCharPos)) or
    (ParamType.GetField('Index').Offset <> 0) or (ParamType.GetField('LineNum').Offset <> 2) then
    raise Exception.Create('TCharPos nao tem o formato esperado nesta IDE');
  Position.Index := Index; Position.LineNum := Line;
  TValue.Make(@Position, ParamType.Handle, Result);
end;

function TProbe.LineQuery(const Name: string; Line: Integer): Boolean;
begin
  Result := FoldMethod(Name, 1, False).Invoke(FEditor, [Line]).AsBoolean;
end;

function TProbe.BufferText: string;
var Reader: IOTAEditReader; Chunk: array[0..8191] of AnsiChar; Count, Position: Integer; Bytes: UTF8String;
begin
  Reader := FView.Buffer.CreateReader; Bytes := ''; Position := 0;
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

procedure TProbe.FoldObserve(const Title: string);
var Line: Integer; Inside, Starts, Elided: string; Screen: string;
begin
  FView.Paint;
  Pump(400);
  Screen := VisibleRows(1);
  Screen := Trim(Copy(Screen, Pos('|', Screen) + 1, MaxInt));
  Inside := ''; Starts := ''; Elided := '';
  for Line := 1 to FLines.Count + 3 do
  begin
    if LineQuery('IsInElisionBlock', Line) and (Line >= 24) and (Line <= 46) then Inside := Inside + IntToStr(Line) + ' ';
    if LineQuery('IsStartOfElisionBlock', Line) then Starts := Starts + IntToStr(Line) + ' ';
    if LineQuery('LineIsElided', Line) then Elided := Elided + IntToStr(Line) + ' ';
  end;
  Note('FOLD | ' + Title);
  Note('     tela: ' + Screen);
  Note(Format('     controle: inicios de bloco dobravel=[%s] | LineIsElided=[%s] | IsInElisionBlock entre 24 e 46=[%s]',
    [Trim(Starts), Trim(Elided), Trim(Inside)]));
end;

function TProbe.FoldExists: Boolean;
begin
  Result := LineQuery('IsStartOfElisionBlock', FFoldFirst);
end;

// The two ends of the block, from the text the buffer has now.
procedure TProbe.FoldArgs(out StartArg, EndArg: TValue);
var Text: TStringList; Add: TRttiMethod;
begin
  // One pass over many blocks reads the buffer once.
  Text := FArgLines;
  if Text = nil then
  begin
    Text := TStringList.Create;
    Text.Text := BufferText;
  end;
  try
    Add := FoldMethod('AddElisionBlock', 3, True);
    StartArg := CharPosArg(Add, 0, Length(Text[FFoldFirst - 1]), FFoldFirst);
    EndArg := CharPosArg(Add, 1, Length(Text[FFoldLast - 1]), FFoldLast);
  finally
    if Text <> FArgLines then Text.Free;
  end;
end;

procedure TProbe.FoldApply(Collapse: Boolean);
var StartArg, EndArg, DescArg: TValue; Description: TKernelElisionDescription; Add: TRttiMethod; DescType: TRttiType;
begin
  FoldArgs(StartArg, EndArg);
  Add := FoldMethod('AddElisionBlock', 3, True);
  DescType := Add.GetParameters[2].ParamType;
  if (DescType.TypeSize <> SizeOf(TKernelElisionDescription)) or (DescType.GetField('ElisionType').Offset <> 0) or
    (DescType.GetField('DescLen').Offset <> 2) or (DescType.GetField('BlockDesc').Offset <> 6) then
    raise Exception.Create('TElisionDescription nao tem o formato esperado nesta IDE');
  Description.ElisionType := rkRegion;
  Description.DescLen := Length(FoldDescription);
  Description.BlockDesc := PAnsiChar(FoldDescription);
  TValue.Make(@Description, DescType.Handle, DescArg);
  if not FoldExists then Add.Invoke(FEditor, [StartArg, EndArg, DescArg]);
  if Collapse then FoldMethod('Elide', 3, True).Invoke(FEditor, [StartArg, EndArg, False]);
end;

procedure TProbe.InsertLine(Line: Integer; const Text: AnsiString);
var Writer: IOTAEditWriter; Position: TOTACharPos;
begin
  Position.Line := Line; Position.CharIndex := 0;
  Writer := FView.Buffer.CreateUndoableWriter;
  Writer.CopyTo(FView.CharPosToPos(Position));
  Writer.Insert(PAnsiChar(Text + #13#10));
  Writer := nil;
end;

procedure TProbe.RunFold;
var Elide: IOTAElideActions; Original, Edited, AfterUndo, AfterRedo, FileName: string; StartArg, EndArg: TValue;
  Lost, Reapplied, Visible, I: Integer; Started: UInt64; Module: IOTAModule;

  procedure Step(const Title: string; const Action: TProc);
  begin
    // Announced first: if the IDE hangs or dies inside the call, the report says which one it was.
    Note('PASSO | ' + Title);
    try
      Action;
      FoldObserve(Title);
    except
      on E: Exception do Note('EXCECAO | ' + Title + ' | ' + E.ClassName + ': ' + E.Message);
    end;
  end;

  // Keeps the fold alive for a while: whenever the IDE discards the block it is registered and folded again.
  procedure Keep(Milliseconds: Integer; const Title: string);
  var Stop: UInt64; Checks: Integer;
  begin
    Reapplied := 0; Visible := 0; Checks := 0;
    Stop := GetTickCount64 + UInt64(Milliseconds);
    try
      repeat
        Pump(50);
        Inc(Checks);
        if not FoldExists then
        begin
          FoldApply(True);
          Inc(Reapplied);
        end;
        if not LineQuery('LineIsElided', FFoldFirst + 1) then Inc(Visible);
      until GetTickCount64 >= Stop;
      Note(Format('FOLD | %s | %d verificacoes em %d ms | bloco reaplicado %d vezes | verificacoes com o bloco aberto: %d',
        [Title, Checks, Milliseconds, Reapplied, Visible]));
    except
      on E: Exception do Note('EXCECAO | ' + Title + ' | ' + E.ClassName + ': ' + E.Message);
    end;
  end;

begin
  Note('== PERGUNTA 3: dobra em faixa arbitraria pelos metodos do controle do editor (observado)');
  Supports(FView, IOTAElideActions, Elide);
  FFoldFirst := Marker('if-begin').Line;
  FFoldLast := FFoldFirst;
  while Trim(FLines[FFoldLast - 1]) <> 'end' do Inc(FFoldLast);
  Note(Format('FOLD | bloco escolhido: begin..end do if, linhas %d..%d', [FFoldFirst, FFoldLast]));
  Original := BufferText;

  Step('estado inicial', procedure begin Elide.UnElideAllBlocks; end);
  Step('DOBRAR: AddElisionBlock + Elide(inicio, fim, False)', procedure begin FoldApply(True); end);
  Capture('fold-1-dobrado');
  Note('FOLD | texto do buffer igual ao original depois de dobrar: ' + BoolToStr(BufferText = Original, True));

  if SameText(FMode, 'foldrisk') then
  begin
    // Calls that stopped the IDE in an earlier run, one per run, chosen by BFPROBE_RISK.
    Note('-- chamada isolada: ' + GetEnvironmentVariable('BFPROBE_RISK'));
    if GetEnvironmentVariable('BFPROBE_RISK') = 'UnElide2True' then
      Step('desdobrar: UnElide(inicio, True)', procedure
        begin FoldArgs(StartArg, EndArg); FoldMethod('UnElide', 2, True).Invoke(FEditor, [StartArg, True]); end)
    else if GetEnvironmentVariable('BFPROBE_RISK') = 'UnElide2False' then
      Step('desdobrar: UnElide(inicio, False)', procedure
        begin FoldArgs(StartArg, EndArg); FoldMethod('UnElide', 2, True).Invoke(FEditor, [StartArg, False]); end)
    else if GetEnvironmentVariable('BFPROBE_RISK') = 'unElideLine' then
      Step('desdobrar: unElide(linha do begin)', procedure
        begin FoldMethod('unElide', 1, False).Invoke(FEditor, [FFoldFirst]); end);
    Step('5 segundos depois', procedure begin Pump(5000); end);
    Exit;
  end;
  Note('-- formas de desdobrar e dobrar de novo');
  Step('desdobrar: UnElide(inicio, fim, True)', procedure
    begin FoldArgs(StartArg, EndArg); FoldMethod('UnElide', 3, True).Invoke(FEditor, [StartArg, EndArg, True]); end);
  Step('desdobrar: UnElideNearestBlock da IDE, cursor na linha do begin', procedure
    begin SetCursor(FFoldFirst, 8); Elide.UnElideNearestBlock; end);
  Step('desdobrar: UnElideAllBlocks da IDE', procedure begin Elide.UnElideAllBlocks; end);
  Step('dobrar: Elide(linha do begin)', procedure
    begin FoldMethod('Elide', 1, False).Invoke(FEditor, [FFoldFirst]); end);
  Step('desdobrar: UnElideAllBlocks da IDE', procedure begin Elide.UnElideAllBlocks; end);
  Step('dobrar: Elide(inicio, False)', procedure
    begin FoldArgs(StartArg, EndArg); FoldMethod('Elide', 2, True).Invoke(FEditor, [StartArg, False]); end);
  Step('desdobrar: UnElideAllBlocks da IDE', procedure begin Elide.UnElideAllBlocks; end);
  Step('dobrar: ElideNearestBlock da IDE, cursor dentro do bloco', procedure
    begin SetCursor(FFoldFirst + 1, 10); Elide.ElideNearestBlock; end);
  Step('desdobrar: ToggleElisions da IDE, cursor na linha do begin', procedure
    begin SetCursor(FFoldFirst, 8); Elide.ToggleElisions; end);
  Step('desdobrar: UnElideAllBlocks da IDE', procedure begin Elide.UnElideAllBlocks; end);
  Step('dobrar de novo pelo controle', procedure begin FoldApply(True); end);
  Step('10 segundos sem mexer', procedure begin Pump(10000); end);

  Note('-- edicao com a dobra ativa');
  Step('linha inserida DENTRO da dobra (escondida), com Desfazer', procedure
    begin InsertLine(FFoldFirst + 2, '        X := X + 0;'); Inc(FFoldLast); end);
  Started := GetTickCount64; Lost := -1;
  for I := 1 to 150 do
  begin
    Pump(100);
    if not FoldExists then begin Lost := Integer(GetTickCount64 - Started); Break; end;
  end;
  Note(Format('FOLD | depois da edicao a IDE descartou o bloco em %d ms (-1 = nao descartou em 15 s)', [Lost]));
  FoldObserve('logo depois do descarte');
  Step('reaplicar nas linhas atualizadas: AddElisionBlock + Elide', procedure begin FoldApply(True); end);
  Step('linha inserida ACIMA da dobra (linha 26), com Desfazer', procedure
    begin InsertLine(26, '  // linha nova'); Inc(FFoldFirst); Inc(FFoldLast); end);
  Keep(12000, 'manter a dobra depois de editar acima');
  FoldObserve('depois de manter por 12 segundos');
  Edited := BufferText;
  Note(Format('FOLD | buffer tem %d caracteres a mais que o original (esperado 37)', [Length(Edited) - Length(Original)]));

  Note('-- desfazer e refazer com a dobra ativa');
  try
    FView.Buffer.Undo;
    AfterUndo := BufferText;
    FView.Buffer.Redo;
    AfterRedo := BufferText;
    Note(Format('FOLD | Desfazer mudou o texto: %s | Refazer devolveu o texto editado: %s', [BoolToStr(AfterUndo <> Edited, True),
      BoolToStr(AfterRedo = Edited, True)]));
    if AfterRedo <> Edited then
    begin
      // The last edit stayed undone: the block is one line up again.
      Dec(FFoldFirst); Dec(FFoldLast);
    end;
  except
    on E: Exception do Note('EXCECAO | desfazer/refazer | ' + E.ClassName + ': ' + E.Message);
  end;
  Keep(6000, 'manter a dobra depois de desfazer/refazer');
  FoldObserve('depois de desfazer/refazer');

  Note('-- salvar, fechar e reabrir');
  Module := FView.Buffer.Module;
  FileName := FView.Buffer.FileName;
  Edited := BufferText;
  Step('salvar com a dobra ativa', procedure begin Module.Save(False, True); end);
  Note('FOLD | arquivo em disco igual ao buffer: ' + BoolToStr(TFile.ReadAllText(FileName) = Edited, True));
  FFoldFile := FileName;
  Elide := nil; Module := nil;
end;
procedure TProbe.CloseSample(const FileName: string);
var Module: IOTAModule;
begin
  Module := (BorlandIDEServices as IOTAModuleServices).FindModule(FileName);
  if Module <> nil then Module.CloseModule(True);
end;

// Run after RunFold has returned, so that nothing of ours still refers to the buffer being closed.
procedure TProbe.RunFoldReopen;
begin
  Note('-- fechar e reabrir a unit');
  try
    FView := nil; FEditor := nil;
    CloseSample(FFoldFile);
    Pump(1500);
    if OpenAndBind(FFoldFile) then
    begin
      Pump(3000);
      FoldObserve('unit fechada e reaberta');
      Note('FOLD | texto reaberto igual ao arquivo em disco: ' + BoolToStr(BufferText = TFile.ReadAllText(FFoldFile), True));
      Note('PASSO | reaplicar depois de reabrir');
      FoldApply(True);
      FoldObserve('reaplicar depois de reabrir');
    end
    else Note('FOLD | a unit nao reabriu');
  except
    on E: Exception do Note('EXCECAO | fechar e reabrir | ' + E.ClassName + ': ' + E.Message);
  end;
  Note('FECHAR | a IDE recebe o pedido de fechamento com a dobra ativa');
end;

{ Debugging through the folded block. }

// Line where the debugged process is stopped; 0 while it runs, negative when there is none.
function TProbe.DebugLine: Integer;
var Process: IOTAProcess; Thread: IOTAThread;
begin
  Process := (BorlandIDEServices as IOTADebuggerServices).CurrentProcess;
  if Process = nil then Exit(-1);
  if Process.ProcessState <> psStopped then Exit(0);
  Thread := Process.CurrentThread;
  if Thread = nil then Exit(-2);
  Result := Thread.CurrentLine;
end;

function TProbe.WaitDebugStop(Seconds: Integer): Integer;
var I: Integer;
begin
  Result := 0;
  for I := 1 to Seconds * 4 do
  begin
    Pump(250);
    Result := DebugLine;
    if Result > 0 then Exit;
  end;
end;

procedure TProbe.DebugStep;
var Process: IOTAProcess;
begin
  Process := (BorlandIDEServices as IOTADebuggerServices).CurrentProcess;
  if Process <> nil then Process.Run(ormStmtStepOver);
end;

procedure TProbe.DebugTerminate;
var Process: IOTAProcess;
begin
  Process := (BorlandIDEServices as IOTADebuggerServices).CurrentProcess;
  if Process <> nil then Process.Terminate;
end;

procedure TProbe.RunFoldDebug;
var Project: IOTAProject; Actions: TCustomActionList; RunAction: TContainedAction; I, Line: Integer; Original: string;
begin
  Note('== PERGUNTA 3: depurar passando pelo bloco dobrado (observado)');
  Project := GetActiveProject;
  if Project = nil then begin Note('DEBUG | o projeto de teste nao abriu'); Exit; end;
  Note('DEBUG | projeto ' + ExtractFileName(Project.FileName));
  Original := BufferText;
  FFoldFirst := Marker('if-begin').Line;
  FFoldLast := FFoldFirst;
  while Trim(FLines[FFoldLast - 1]) <> 'end' do Inc(FFoldLast);
  FoldApply(True);
  FoldObserve(Format('bloco %d..%d dobrado antes de depurar', [FFoldFirst, FFoldLast]));
  (BorlandIDEServices as IOTADebuggerServices).NewSourceBreakpoint(FSample, FFoldFirst + 1, nil);
  Note(Format('DEBUG | breakpoint na linha %d, que esta escondida pela dobra', [FFoldFirst + 1]));
  RunAction := nil;
  Actions := (BorlandIDEServices as INTAServices).ActionList;
  for I := 0 to Actions.ActionCount - 1 do
    if SameText(Actions.Actions[I].Name, 'RunRunCommand') then RunAction := Actions.Actions[I];
  if RunAction = nil then begin Note('DEBUG | acao RunRunCommand nao encontrada'); Exit; end;
  Note('PASSO | executar o projeto no depurador');
  RunAction.Execute;
  Line := WaitDebugStop(90);
  Note(Format('DEBUG | processo parado na linha %d (0 = nao parou em 90 s, negativo = sem processo)', [Line]));
  if Line <= 0 then Exit;
  FoldObserve('parado no breakpoint dentro do bloco');
  Capture('debug-1-parado');
  for I := 1 to 3 do
  begin
    Note('PASSO | passo a passo (step over) ' + IntToStr(I));
    DebugStep;
    Pump(400);
    Line := WaitDebugStop(20);
    Note(Format('DEBUG | depois do passo %d: parado na linha %d', [I, Line]));
    FoldObserve('depois do passo ' + IntToStr(I));
  end;
  Note('PASSO | dobrar de novo com o processo parado');
  try
    FoldApply(True);
    FoldObserve(Format('dobra reaplicada com o processo parado na linha %d', [DebugLine]));
    Note('PASSO | passo a passo com a dobra reaplicada');
    DebugStep;
    Pump(400);
    Line := WaitDebugStop(20);
    Note(Format('DEBUG | depois do passo: parado na linha %d', [Line]));
    FoldObserve('depois do passo com a dobra reaplicada');
  except
    on E: Exception do Note('EXCECAO | dobra durante a depuracao | ' + E.ClassName + ': ' + E.Message);
  end;
  Note('PASSO | encerrar o processo depurado');
  DebugTerminate;
  for I := 1 to 80 do
  begin
    Pump(250);
    if DebugLine = -1 then Break;
  end;
  Note('DEBUG | processo encerrado: ' + BoolToStr(DebugLine = -1, True));
  Pump(1500);
  FoldObserve('depois de encerrar a depuracao');
  FoldApply(True);
  FoldObserve('dobra reaplicada depois da depuracao');
  Note('DEBUG | texto do buffer igual ao original: ' + BoolToStr(BufferText = Original, True));
end;

{ Keeping a fold while the text around it is edited. The IDE discards a block it
  did not create whenever it parses the unit again, so the block is followed by
  the line tracker of the ToolsAPI and registered again right before a repaint. }

const
  TrackFirst = 9001;
  TrackLast = 9002;

procedure TProbe.KeepStart;
begin
  FTracker := FView.Buffer.GetEditLineTracker;
  FTracker.AddLine(FFoldFirst, TrackFirst);
  FTracker.AddLine(FFoldLast, TrackLast);
  FKeepReapplied := 0; FKeepErrors := 0; FOpenLines := 0; FOpenEpisodes := 0; FKeepError := '';
  FKeep := True;
end;

procedure TProbe.KeepStop;
var Index: Integer;
begin
  FKeep := False;
  if FTracker = nil then Exit;
  Index := FTracker.IndexOfData(TrackFirst);
  if Index >= 0 then FTracker.Delete(Index);
  Index := FTracker.IndexOfData(TrackLast);
  if Index >= 0 then FTracker.Delete(Index);
  FTracker := nil;
end;

procedure TProbe.KeepCheck;
var First, Last: Integer;
begin
  if not FKeep or FKeepBusy or (FTracker = nil) then Exit;
  FKeepBusy := True;
  try
    try
      First := FTracker.IndexOfData(TrackFirst);
      Last := FTracker.IndexOfData(TrackLast);
      if (First < 0) or (Last < 0) then Exit;
      First := FTracker.GetLineNum(First);
      Last := FTracker.GetLineNum(Last);
      if (First < 1) or (Last <= First) then Exit;
      FFoldFirst := First; FFoldLast := Last;
      if not FoldExists then
      begin
        FoldApply(True);
        Inc(FKeepReapplied);
      end;
    except
      on E: Exception do
      begin
        Inc(FKeepErrors);
        FKeepError := E.ClassName + ': ' + E.Message;
      end;
    end;
  finally FKeepBusy := False; end;
end;

procedure TProbe.OnBeginPaint(const Editor: TWinControl; const ForceFullRepaint: Boolean);
begin
  if Editor = FEditor then
  begin
    KeepCheck;
    KeepCheckAll;
  end;
end;

// Text typed one character at a time at the end of a line, as a user would.
procedure TProbe.TypeAtEnd(Line: Integer; const Text: string; PauseMs: Integer);
var Position: IOTAEditPosition; Character: Char;
begin
  Position := FView.Buffer.EditPosition;
  Position.Move(Line, 1);
  Position.MoveEOL;
  for Character in Text do
  begin
    if Character = #13 then Position.InsertText(#13#10) else Position.InsertCharacter(Character);
    FView.Paint;
    Pump(PauseMs);
  end;
end;

procedure TProbe.DeleteLine(Line: Integer);
var Writer: IOTAEditWriter; Position: TOTACharPos; From, Upto: Integer;
begin
  Position.CharIndex := 0;
  Position.Line := Line; From := FView.CharPosToPos(Position);
  Position.Line := Line + 1; Upto := FView.CharPosToPos(Position);
  Writer := FView.Buffer.CreateUndoableWriter;
  Writer.CopyTo(From);
  Writer.DeleteTo(Upto);
  Writer := nil;
  FView.Paint;
end;

procedure TProbe.RunFoldKeep;
var Elide: IOTAElideActions; I: Integer; Line: string; Lines: TStringList;

  // One kind of edit, then what happened to the fold while and after it.
  procedure Phase(const Title: string; const Action: TProc);
  var Folded: Boolean;
  begin
    Note('PASSO | ' + Title);
    FKeepReapplied := 0; FOpenLines := 0; FOpenEpisodes := 0;
    try
      Action;
      FView.Paint;
      Pump(1500);
      KeepCheck;
      Folded := FoldExists and LineQuery('LineIsElided', FFoldFirst + 1) and LineQuery('LineIsElided', FFoldLast) and
        not LineQuery('LineIsElided', FFoldFirst) and not LineQuery('LineIsElided', FFoldLast + 1);
      Lines.Text := BufferText;
      Line := Trim(Lines[FFoldFirst - 1]) + ' ... ' + Trim(Lines[FFoldLast - 1]);
      Note(Format('KEEP | %s | bloco agora nas linhas %d..%d [%s] | dobrado exatamente nessa faixa: %s | reaplicado %d vezes | ' +
        'linhas do bloco pintadas abertas: %d em %d momentos | erros: %d %s', [Title, FFoldFirst, FFoldLast, Line,
        BoolToStr(Folded, True), FKeepReapplied, FOpenLines, FOpenEpisodes, FKeepErrors, FKeepError]));
    except
      on E: Exception do Note('EXCECAO | ' + Title + ' | ' + E.ClassName + ': ' + E.Message);
    end;
  end;

begin
  Note('== MANTER A DOBRA ENQUANTO SE EDITA ANTES E DEPOIS DELA (observado)');
  Supports(FView, IOTAElideActions, Elide);
  Elide.UnElideAllBlocks;
  Lines := TStringList.Create;
  try
    FFoldFirst := Marker('if-begin').Line;
    FFoldLast := FFoldFirst;
    while Trim(FLines[FFoldLast - 1]) <> 'end' do Inc(FFoldLast);
    FoldApply(True);
    KeepStart;
    Phase('sem editar, 1,5 s', procedure begin end);
    Phase('digitar 25 caracteres na linha logo acima da dobra', procedure
      begin TypeAtEnd(FFoldFirst - 1, ' // digitando acima da dob', 60); end);
    Phase('digitar 3 linhas novas no inicio do metodo, acima da dobra', procedure
      begin TypeAtEnd(26, #13'X := 1;'#13'X := 2;'#13'X := 3;', 60); end);
    Phase('digitar 25 caracteres na linha logo abaixo da dobra', procedure
      begin TypeAtEnd(FFoldLast + 1, ' // digitando abaixo da do', 60); end);
    Phase('digitar 2 linhas novas abaixo da dobra', procedure
      begin TypeAtEnd(FFoldLast + 3, #13'X := 4;'#13'X := 5;', 60); end);
    Phase('apagar 10 caracteres na linha logo acima da dobra', procedure
      var Position: IOTAEditPosition; K: Integer;
      begin
        Position := FView.Buffer.EditPosition;
        Position.Move(FFoldFirst - 1, 1); Position.MoveEOL;
        for K := 1 to 10 do begin Position.BackspaceDelete(1); FView.Paint; Pump(60); end;
      end);
    Phase('apagar uma linha inteira acima da dobra', procedure begin DeleteLine(27); end);
    Phase('apagar uma linha inteira abaixo da dobra', procedure begin DeleteLine(FFoldLast + 4); end);
    Phase('digitar 40 caracteres sem pausa acima da dobra', procedure
      begin TypeAtEnd(26, ' // rajada de digitacao sem pausa nenhuma', 0); end);
    Phase('salvar a unit', procedure begin FView.Buffer.Module.Save(False, True); end);
    Phase('digitar depois de salvar', procedure begin TypeAtEnd(26, ' depois', 60); end);
    Phase('Desfazer 5 vezes', procedure
      var K: Integer; begin for K := 1 to 5 do begin FView.Buffer.Undo; FView.Paint; Pump(200); end; end);
    Phase('Refazer 5 vezes', procedure
      var K: Integer; begin for K := 1 to 5 do begin FView.Buffer.Redo; FView.Paint; Pump(200); end; end);
    Phase('salvar de novo', procedure begin FView.Buffer.Module.Save(False, True); end);
    Capture('keep-1-final');
    Phase('10 segundos parado', procedure begin Pump(10000); end);
    Note('PASSO | desdobrar pelo comando da IDE e conferir que a dobra nao volta sozinha');
    FKeep := False;
    SetCursor(FFoldFirst, 8);
    Elide.UnElideNearestBlock;
    Pump(1500);
    Note('KEEP | depois de desdobrar com a manutencao desligada: linha escondida=' +
      BoolToStr(LineQuery('LineIsElided', FFoldFirst + 1), True));
    for I := 0 to Lines.Count - 1 do ;
  finally
    KeepStop;
    Lines.Free;
  end;
end;

{ Several blocks at once, found by the block analyser, each with its own state. }

function TProbe.LineQueryOn(Editor: TWinControl; const Name: string; Line: Integer): Boolean;
var Method: TRttiMethod;
begin
  for Method in FCtx.GetType(Editor.ClassType).GetMethods do
    if SameText(Method.Name, Name) and (Length(Method.GetParameters) = 1) then
      Exit(Method.Invoke(Editor, [Line]).AsBoolean);
  raise Exception.Create('Metodo interno nao encontrado: ' + Name);
end;

procedure TProbe.ApplyRange(First, Last: Integer; Collapse: Boolean);
var SavedFirst, SavedLast: Integer;
begin
  SavedFirst := FFoldFirst; SavedLast := FFoldLast;
  try
    FFoldFirst := First; FFoldLast := Last;
    FoldApply(Collapse);
  finally
    FFoldFirst := SavedFirst; FFoldLast := SavedLast;
  end;
end;

procedure TProbe.KeptStart;
begin
  FTracker := FView.Buffer.GetEditLineTracker;
  FKept.Clear;
  FKeepReapplied := 0; FKeepErrors := 0; FKeepError := ''; FKeepPasses := 0; FKeepMaxMs := 0;
  FKeepAll := True;
end;

procedure TProbe.KeptAdd(First, Last: Integer; Collapsed: Boolean);
var Item: TKept;
begin
  Item.Id := 9100 + 2 * FKept.Count;
  Item.First := First; Item.Last := Last; Item.Collapsed := Collapsed;
  FTracker.AddLine(First, Item.Id);
  FTracker.AddLine(Last, Item.Id + 1);
  FKept.Add(Item);
  ApplyRange(First, Last, Collapsed);
end;

procedure TProbe.KeptStop;
var Item: TKept; Index: Integer;
begin
  FKeepAll := False;
  if FTracker <> nil then
    for Item in FKept do
    begin
      Index := FTracker.IndexOfData(Item.Id);
      if Index >= 0 then FTracker.Delete(Index);
      Index := FTracker.IndexOfData(Item.Id + 1);
      if Index >= 0 then FTracker.Delete(Index);
    end;
  FKept.Clear;
  FTracker := nil;
end;

// Follows every kept block to its current lines. A block the IDE still has only
// tells its state (the user may have opened or closed it); one the IDE discarded
// is registered again in the state it had.
procedure TProbe.KeepCheckAll;
var I, A, B: Integer; Item: TKept; Watch: TStopwatch;
begin
  if not FKeepAll or FKeepBusy or (FTracker = nil) then Exit;
  FKeepBusy := True;
  Watch := TStopwatch.StartNew;
  try
    try
      for I := 0 to FKept.Count - 1 do
      begin
        Item := FKept[I];
        A := FTracker.IndexOfData(Item.Id);
        B := FTracker.IndexOfData(Item.Id + 1);
        if (A < 0) or (B < 0) then Continue;
        Item.First := FTracker.GetLineNum(A);
        Item.Last := FTracker.GetLineNum(B);
        if (Item.First >= 1) and (Item.Last > Item.First) then
        begin
          if LineQuery('IsStartOfElisionBlock', Item.First) then
          begin
            // Hidden inside a folded outer block: its own state cannot be read now.
            if not LineQuery('LineIsElided', Item.First) then
            begin
              Item.Collapsed := LineQuery('LineIsElided', Item.First + 1);
              // The cursor is on a hidden line of this block (Enter at the end of the folded line): open it.
              if Item.Collapsed and (FView.CursorPos.Line > Item.First) and (FView.CursorPos.Line <= Item.Last) then
              begin
                FoldMethod('unElide', 1, False).Invoke(FEditor, [Item.First]);
                Item.Collapsed := False;
              end;
            end;
          end
          else
          begin
            if FArgLines = nil then
            begin
              FArgLines := TStringList.Create;
              FArgLines.Text := BufferText;
            end;
            // The cursor went into the block (Enter at the end of the folded line, for one):
            // folding it again would leave the user typing on a hidden line.
            if Item.Collapsed and (FView.CursorPos.Line > Item.First) and (FView.CursorPos.Line <= Item.Last) then
              Item.Collapsed := False;
            ApplyRange(Item.First, Item.Last, Item.Collapsed);
            Inc(FKeepReapplied);
          end;
        end;
        FKept[I] := Item;
      end;
    except
      on E: Exception do
      begin
        Inc(FKeepErrors);
        FKeepError := E.ClassName + ': ' + E.Message;
      end;
    end;
  finally
    FreeAndNil(FArgLines);
    FKeepBusy := False;
    Inc(FKeepPasses);
    FKeepLastMs := Watch.ElapsedMilliseconds;
    if FKeepLastMs > FKeepMaxMs then FKeepMaxMs := FKeepLastMs;
  end;
end;

// Compares, line by line, what the editor hides with what the kept blocks say should be hidden.
function TProbe.KeptVerify(const Title: string): Boolean;
var Expected: TArray<Boolean>; Count, Line, Wrong, Folded: Integer; Item: TKept; Text: TStringList; Detail: string;
begin
  KeepCheckAll;
  Text := TStringList.Create;
  try
    Text.Text := BufferText;
    Count := Text.Count;
  finally Text.Free; end;
  SetLength(Expected, Count + 2);
  Folded := 0;
  for Item in FKept do
    if Item.Collapsed then
    begin
      Inc(Folded);
      for Line := Item.First + 1 to Item.Last do
        if Line <= Count then Expected[Line] := True;
    end;
  Wrong := 0; Detail := '';
  for Line := 1 to Count do
    if LineQuery('LineIsElided', Line) <> Expected[Line] then
    begin
      Inc(Wrong);
      if Wrong <= 8 then Detail := Detail + IntToStr(Line) + ' ';
    end;
  Result := Wrong = 0;
  Note(Format('MULTI | %s | blocos mantidos: %d (%d dobrados) | linhas escondidas conferem com o esperado: %s%s | reaplicacoes: %d | ' +
    'passagens: %d, a mais lenta %d ms | erros: %d %s', [Title, FKept.Count, Folded, BoolToStr(Result, True),
    IfThen(Wrong > 0, Format(' (%d linhas erradas: %s)', [Wrong, Trim(Detail)]), ''), FKeepReapplied, FKeepPasses, FKeepMaxMs,
    FKeepErrors, FKeepError]));
  FKeepReapplied := 0; FKeepPasses := 0; FKeepMaxMs := 0;
end;

// A real mouse click on the fold box in the gutter of a line.
procedure TProbe.ClickFoldBox(Line: Integer);
var Current: INTACodeEditorState; Row, X, Y: Integer; LineState: INTACodeEditorLineState;
begin
  Current := State;
  for Row := Current.TopLine to Current.BottomLine do
  begin
    LineState := Current.LineState[Row];
    if (LineState <> nil) and (LineState.LogicalLineNum = Line) then
    begin
      X := Current.CodeLeftEdge - 7;
      Y := (LineState.CodeRect.Top + LineState.CodeRect.Bottom) div 2;
      PostMessage(FEditor.Handle, WM_MOUSEMOVE, 0, MakeLParam(X, Y));
      PostMessage(FEditor.Handle, WM_LBUTTONDOWN, MK_LBUTTON, MakeLParam(X, Y));
      PostMessage(FEditor.Handle, WM_LBUTTONUP, 0, MakeLParam(X, Y));
      Pump(700);
      Exit;
    end;
  end;
  Note('MULTI | linha ' + IntToStr(Line) + ' nao esta na tela para clicar');
end;

// Characters and keys delivered to the editor window as the keyboard delivers them.
procedure TProbe.PostText(const Text: string);
var Character: Char;
begin
  for Character in Text do
  begin
    PostMessage(FEditor.Handle, WM_CHAR, Ord(Character), 1);
    Pump(60);
  end;
end;

procedure TProbe.PostKey(Key: Word);
var Scan: LPARAM;
begin
  Scan := MapVirtualKey(Key, 0) shl 16;
  PostMessage(FEditor.Handle, WM_KEYDOWN, Key, Scan or 1);
  PostMessage(FEditor.Handle, WM_KEYUP, Key, Scan or LPARAM($C0000001));
  Pump(150);
end;

procedure TProbe.RunFoldMulti;
var Blocks: TArray<TBlock>; Block: TBlock; Elide: IOTAElideActions; Text: TStringList; Inner, Line: Integer; Summary: string;

  function LineText(Number: Integer): string;
  begin
    Text.Text := BufferText;
    if (Number >= 1) and (Number <= Text.Count) then Result := Text[Number - 1] else Result := '';
  end;

  function HiddenNow(First, Last: Integer): string;
  var L: Integer;
  begin
    Result := '';
    for L := First to Last do
      if LineQuery('LineIsElided', L) then Result := Result + IntToStr(L) + ' ';
    Result := '[' + Trim(Result) + ']';
  end;

begin
  Note('== VARIAS DOBRAS, ANINHADAS, COM ENTRADA REAL DE MOUSE E TECLADO (observado)');
  Supports(FView, IOTAElideActions, Elide);
  Elide.UnElideAllBlocks;
  Pump(500);
  Text := TStringList.Create;
  try
    Blocks := FindBlocks(BufferText);
    Summary := '';
    for Block in Blocks do
      Summary := Summary + Format('%s(%d) %d..%d; ', [BlockKindName(Block.Kind), Block.Depth, Block.FirstLine, Block.LastLine]);
    Note(Format('MULTI | analisador: %d blocos | %s', [Length(Blocks), Summary]));

    Note('-- todos os blocos internos registrados; os mais internos dobrados');
    KeptStart;
    for Block in Blocks do
      if Block.Depth >= 1 then
        KeptAdd(Block.FirstLine, Block.LastLine, Block.Depth >= 3);
    for Block in Blocks do
      if (Block.Kind = bkBegin) and (Block.Depth = 2) and (Block.FirstLine > 50) then
        ApplyRange(Block.FirstLine, Block.LastLine, True);
    FView.Paint; Pump(600);
    KeptVerify('blocos internos dobrados (if, else, while, ramos do case)');
    Capture('multi-1-internos');

    Note('-- dobrar e abrir blocos externos por cima dos internos');
    for Block in Blocks do
      if (Block.Kind = bkBegin) and (Block.Depth = 2) and (Block.FirstLine < 50) then
      begin
        Inner := Block.FirstLine;
        ApplyRange(Block.FirstLine, Block.LastLine, True);
        FView.Paint; Pump(500);
        Note(Format('MULTI | bloco externo %d..%d dobrado por cima: escondidas %s', [Block.FirstLine, Block.LastLine,
          HiddenNow(Block.FirstLine, Block.LastLine + 1)]));
        FoldMethod('unElide', 1, False).Invoke(FEditor, [Inner]);
        FView.Paint; Pump(500);
        Note(Format('MULTI | bloco externo aberto de novo: escondidas %s (os internos devem continuar dobrados)',
          [HiddenNow(Block.FirstLine, Block.LastLine + 1)]));
      end;
    KeptVerify('depois de dobrar e abrir o bloco externo');
    for Block in Blocks do
      if Block.Kind in [bkTry, bkCase] then ApplyRange(Block.FirstLine, Block.LastLine, True);
    FView.Paint; Pump(600);
    KeptVerify('try e case dobrados inteiros');
    Capture('multi-2-try-case');

    Note('-- editar com todas as dobras ativas');
    TypeAtEnd(26, ' // acima de tudo', 60);
    Pump(1500);
    KeptVerify('digitar acima de todas as dobras');
    TypeAtEnd(26, #13'X := 9;'#13'X := 8;', 60);
    Pump(1500);
    KeptVerify('duas linhas novas acima de todas as dobras');
    Line := 0;
    for Block in Blocks do
      if Block.Kind = bkTry then Line := Block.LastLine + 2 + 1;
    TypeAtEnd(Line, ' // entre o try e o case', 60);
    Pump(1500);
    KeptVerify(Format('digitar na linha %d, entre o try e o case', [Line]));
    FView.Buffer.Module.Save(False, True);
    Pump(1500);
    KeptVerify('salvar');
    Elide.UnElideAllBlocks;
    Pump(1500);
    Note('MULTI | UnElideAllBlocks da IDE (o usuario pediu para abrir tudo): escondidas ' + HiddenNow(1, 80));
    KeptVerify('depois de abrir tudo pelo comando da IDE');
    KeptStop;

    Note('-- um bloco so, com clique real no quadradinho da margem');
    Elide.UnElideAllBlocks;
    Pump(500);
    Blocks := FindBlocks(BufferText);
    for Block in Blocks do
      if Block.Depth = 3 then begin Inner := Block.FirstLine; Line := Block.LastLine; Break; end;
    KeptStart;
    KeptAdd(Inner, Line, True);
    FView.Paint; Pump(600);
    KeptVerify(Format('bloco %d..%d dobrado', [Inner, Line]));
    ClickFoldBox(Inner);
    Note(Format('MULTI | clique no quadradinho da linha %d: escondidas %s | bloco ainda registrado: %s', [Inner,
      HiddenNow(Inner, Line + 1), BoolToStr(LineQuery('IsStartOfElisionBlock', Inner), True)]));
    KeptVerify('estado depois do clique (deve ter ficado aberto e ser lembrado aberto)');
    TypeAtEnd(26, ' x', 60);
    Pump(1500);
    KeptVerify('digitar acima com o bloco aberto pelo usuario (deve continuar aberto e registrado)');
    Note('MULTI | bloco ainda registrado depois da edicao: ' + BoolToStr(LineQuery('IsStartOfElisionBlock', FKept[0].First), True));
    ClickFoldBox(FKept[0].First);
    Note(Format('MULTI | segundo clique no quadradinho: escondidas %s', [HiddenNow(FKept[0].First, FKept[0].Last + 1)]));
    KeptVerify('estado depois do segundo clique (deve ter dobrado de novo)');
    TypeAtEnd(26, ' y', 60);
    Pump(1500);
    KeptVerify('digitar acima com o bloco dobrado pelo clique');

    Note('-- teclado real (mensagens de tecla para a janela do editor)');
    Winapi.Windows.SetFocus(FEditor.Handle);
    Note('MULTI | editor com o foco do teclado: ' + BoolToStr(GetFocus = FEditor.Handle, True));
    Inner := FKept[0].First;
    SetCursor(Inner - 1, Length(LineText(Inner - 1)) + 1);
    PostText('abc');
    Pump(1500);
    Note(Format('MULTI | "abc" digitado no fim da linha acima (%d): [%s]', [Inner - 1, Trim(LineText(Inner - 1))]));
    KeptVerify('teclado: digitar na linha logo acima');
    SetCursor(Inner - 1, 3);
    PostKey(VK_DOWN);
    Note(Format('MULTI | seta para baixo a partir da linha %d: cursor na linha %d', [Inner - 1, FView.CursorPos.Line]));
    PostKey(VK_DOWN);
    Note(Format('MULTI | seta para baixo de novo: cursor na linha %d (a dobra vai de %d a %d)', [FView.CursorPos.Line,
      FKept[0].First, FKept[0].Last]));
    KeptVerify('teclado: passar o cursor pela dobra com a seta');
    SetCursor(FKept[0].First, Length(LineText(FKept[0].First)) + 1);
    PostText('z');
    Pump(1500);
    Note(Format('MULTI | "z" digitado no fim da propria linha dobrada (%d): [%s] | escondidas %s | bloco registrado: %s',
      [FKept[0].First, Trim(LineText(FKept[0].First)), HiddenNow(FKept[0].First, FKept[0].Last + 1),
       BoolToStr(LineQuery('IsStartOfElisionBlock', FKept[0].First), True)]));
    KeptVerify('teclado: digitar na propria linha dobrada');
    PostKey(VK_RETURN);
    Pump(1500);
    Note(Format('MULTI | Enter no fim da linha dobrada: cursor na linha %d | bloco agora %d..%d | escondidas %s', [FView.CursorPos.Line,
      FKept[0].First, FKept[0].Last, HiddenNow(FKept[0].First, FKept[0].Last + 2)]));
    KeptVerify('teclado: Enter no fim da linha dobrada');
    Note(Format('MULTI | linhas do bloco agora: [%s] ... [%s]', [Trim(LineText(FKept[0].First)), Trim(LineText(FKept[0].Last))]));
    KeptStop;
    Elide.UnElideAllBlocks;
    FView.Buffer.Module.Save(False, True);
  finally
    Text.Free;
  end;
end;

// The same unit in a second editor window.
procedure TProbe.RunFoldViews;
var Actions: TCustomActionList; I, First, Last: Integer; Found: TContainedAction; Names: string; Blocks: TArray<TBlock>;
  Block: TBlock; Other: TWinControl; Editors: TList<TWinControl>; Editor: TWinControl;
begin
  Note('== A MESMA UNIT EM DUAS JANELAS DE EDICAO (observado)');
  try
    Found := nil; Names := '';
    Actions := (BorlandIDEServices as INTAServices).ActionList;
    for I := 0 to Actions.ActionCount - 1 do
      if TRegEx.IsMatch(Actions.Actions[I].Name, '(?i)new.*edit|edit.*window') then
      begin
        Names := Names + Actions.Actions[I].Name + ' ';
        if SameText(Actions.Actions[I].Name, 'ViewNewEditorCommand') then Found := Actions.Actions[I];
      end;
    Note('VIEWS | acoes candidatas: ' + Names);
    if Found = nil then begin Note('VIEWS | acao de nova janela de edicao nao encontrada; teste nao feito'); Exit; end;
    First := 0; Last := 0;
    SetCursor(1, 1);
    Blocks := FindBlocks(BufferText);
    for Block in Blocks do
      if Block.Depth = 3 then begin First := Block.FirstLine; Last := Block.LastLine; Break; end;
    KeptStart;
    KeptAdd(First, Last, True);
    FView.Paint; Pump(500);
    Found.Execute;
    Pump(2500);
    Other := nil;
    Editors := FServices.GetKnownEditors;
    try
      Note(Format('VIEWS | views do buffer: %d | editores conhecidos: %d', [FView.Buffer.EditViewCount, Editors.Count]));
      for Editor in Editors do
        if Editor <> FEditor then Other := Editor;
    finally Editors.Free; end;
    if Other = nil then begin Note('VIEWS | a segunda janela nao abriu'); KeptStop; Exit; end;
    Note(Format('VIEWS | na janela original: bloco registrado=%s linha %d escondida=%s | na segunda janela: bloco registrado=%s linha %d escondida=%s',
      [BoolToStr(LineQuery('IsStartOfElisionBlock', First), True), First + 1, BoolToStr(LineQuery('LineIsElided', First + 1), True),
       BoolToStr(LineQueryOn(Other, 'IsStartOfElisionBlock', First), True), First + 1,
       BoolToStr(LineQueryOn(Other, 'LineIsElided', First + 1), True)]));
    TypeAtEnd(26, ' v', 60);
    Pump(1500);
    KeptVerify('digitar com duas janelas abertas (janela original)');
    Note(Format('VIEWS | depois de editar, na segunda janela: linha %d escondida=%s', [FKept[0].First + 1,
      BoolToStr(LineQueryOn(Other, 'LineIsElided', FKept[0].First + 1), True)]));
    KeptStop;
    PostMessage(GetAncestor(Other.Handle, GA_ROOT), WM_CLOSE, 0, 0);
    Pump(2000);
    Editors := FServices.GetKnownEditors;
    try
      Note(Format('VIEWS | segunda janela fechada: editores conhecidos agora %d', [Editors.Count]));
    finally Editors.Free; end;
  except
    on E: Exception do Note('EXCECAO | duas janelas | ' + E.ClassName + ': ' + E.Message);
  end;
end;

// A unit of about ten thousand lines with hundreds of folds.
procedure TProbe.RunFoldBig;
var FileName: string; Blocks: TArray<TBlock>; Block: TBlock; Watch: TStopwatch; Count, Total: Integer; Elide: IOTAElideActions;
begin
  Note('== UNIT GRANDE (observado)');
  FileName := GetEnvironmentVariable('BFPROBE_BIG');
  try
    FView.Buffer.Module.Save(False, True);
    if (FileName = '') or not OpenAndBind(FileName) then begin Note('BIG | a unit grande nao abriu'); Exit; end;
    Pump(4000);
    Supports(FView, IOTAElideActions, Elide);
    Elide.UnElideAllBlocks;
    Watch := TStopwatch.StartNew;
    Blocks := FindBlocks(BufferText);
    Total := 0;
    for Block in Blocks do
      if Block.Depth >= 1 then Inc(Total);
    Note(Format('BIG | %s | ler o buffer e analisar: %d ms | %d blocos, %d internos', [ExtractFileName(FileName),
      Watch.ElapsedMilliseconds, Length(Blocks), Total]));
    KeptStart;
    Watch := TStopwatch.StartNew;
    Count := 0;
    FArgLines := TStringList.Create;
    try
      FArgLines.Text := BufferText;
      for Block in Blocks do
        if (Block.Depth = 3) and (Count < 400) then
        begin
          KeptAdd(Block.FirstLine, Block.LastLine, True);
          Inc(Count);
        end;
    finally FreeAndNil(FArgLines); end;
    Note(Format('BIG | registrar e dobrar %d blocos: %d ms', [Count, Watch.ElapsedMilliseconds]));
    FView.Paint; Pump(1000);
    KeptVerify('400 blocos dobrados');
    TypeAtEnd(8, ' // edicao no topo', 60);
    Pump(2500);
    KeptVerify('digitar no topo da unit, acima das 400 dobras');
    TypeAtEnd(8, #13'// linha nova', 60);
    Pump(2500);
    KeptVerify('linha nova no topo da unit');
    SetCursor(5000, 1);
    Pump(800);
    TypeAtEnd(5000, ' // meio', 60);
    Pump(2500);
    KeptVerify('ir para a linha 5000 e digitar la');
    Capture('big-1');
    FView.Buffer.Module.Save(False, True);
    Pump(2000);
    KeptVerify('salvar a unit grande');
    KeptStop;
  except
    on E: Exception do Note('EXCECAO | unit grande | ' + E.ClassName + ': ' + E.Message);
  end;
end;

{ The plugin itself, driven through its menu items and its keyboard shortcut. }

// After each repaint of the editor: was any block that should be folded left open on screen?
procedure TProbe.OnEndPaint(const Editor: TWinControl);
var Items: TArray<TFoldItem>; Item: TFoldItem; Wrong: Boolean; Top, Bottom, Cursor: Integer;
begin
  if not FCheckPaints or (Editor <> FEditor) or (FView = nil) then Exit;
  // While the plugin folds several blocks it turns the drawing of the editor off: a
  // repaint made then never reaches the screen, so it is not something the user saw.
  if not IsWindowVisible(FEditor.Handle) then Exit;
  // A command of the plugin is running: what it shows half way is the command itself.
  if FInCommand then Exit;
  Items := TFoldManager.Instance.Items(FView.Buffer.FileName);
  if Length(Items) > 80 then Exit;
  Wrong := False;
  try
    // Only what the user can see: a fold of a block that is on screen and was left open.
    Top := FView.TopPos.Line;
    Bottom := Top + FView.ViewSize.cy;
    Cursor := FView.CursorPos.Line;
    for Item in Items do
      // With the cursor inside it the block is opened on purpose.
      if Item.Collapsed and not ((Cursor > Item.First) and (Cursor <= Item.Last)) and (Item.First >= Top) and
        (Item.First <= Bottom) and not TFoldEngine.LineHidden(FEditor, Item.First) and
        not TFoldEngine.LineHidden(FEditor, Item.First + 1) then Wrong := True;
  except
    Wrong := True;
  end;
  Inc(FPaintsChecked);
  if Wrong then Inc(FPaintsWrong);
end;

function TProbe.MenuClick(const ItemName: string): Boolean;

  function Find(Parent: TMenuItem): TMenuItem;
  var I: Integer;
  begin
    for I := 0 to Parent.Count - 1 do
    begin
      if SameText(Parent[I].Name, ItemName) then Exit(Parent[I]);
      Result := Find(Parent[I]);
      if Result <> nil then Exit;
    end;
    Result := nil;
  end;

var Item: TMenuItem;
begin
  Item := Find((BorlandIDEServices as INTAServices).MainMenu.Items);
  Result := Item <> nil;
  FInCommand := True;
  try
    if Result then Item.Click;
    Pump(400);
  finally FInCommand := False; end;
end;

// A shortcut as the keyboard delivers it to the editor: the modifier keys are
// down in the keyboard state of the IDE's own thread while the key message is handled.
procedure TProbe.PressShortcut(Key: Word; Ctrl, Alt, Shift: Boolean);
var Saved, Pressed: TKeyboardState; Scan: LPARAM;
begin
  if FRealInput then
  begin
    if not BringToFront then begin Note('  atalho real nao enviado: a IDE de teste nao esta em primeiro plano'); Exit; end;
    if Ctrl then keybd_event(VK_CONTROL, 0, 0, 0);
    if Alt then keybd_event(VK_MENU, 0, 0, 0);
    if Shift then keybd_event(VK_SHIFT, 0, 0, 0);
    keybd_event(Key, 0, 0, 0);
    keybd_event(Key, 0, KEYEVENTF_KEYUP, 0);
    if Shift then keybd_event(VK_SHIFT, 0, KEYEVENTF_KEYUP, 0);
    if Alt then keybd_event(VK_MENU, 0, KEYEVENTF_KEYUP, 0);
    if Ctrl then keybd_event(VK_CONTROL, 0, KEYEVENTF_KEYUP, 0);
    Pump(500);
    Exit;
  end;
  Winapi.Windows.SetFocus(FEditor.Handle);
  // Whatever the previous command left in the queue is handled before the key goes in.
  Pump(400);
  GetKeyboardState(Saved);
  Pressed := Saved;
  if Ctrl then begin Pressed[VK_CONTROL] := $80; Pressed[VK_LCONTROL] := $80; end;
  if Alt then begin Pressed[VK_MENU] := $80; Pressed[VK_LMENU] := $80; end;
  if Shift then begin Pressed[VK_SHIFT] := $80; Pressed[VK_LSHIFT] := $80; end;
  SetKeyboardState(Pressed);
  FInCommand := True;
  try
    Scan := (LPARAM(MapVirtualKey(Key, 0)) shl 16) or 1;
    if Alt then Scan := Scan or (1 shl 29);
    PostMessage(FEditor.Handle, WM_KEYDOWN, Key, Scan);
    Pump(300);
    PostMessage(FEditor.Handle, WM_KEYUP, Key, Scan or LPARAM($C0000000));
    Pump(150);
  finally
    FInCommand := False;
    SetKeyboardState(Saved);
  end;
end;

function TProbe.PluginHidden(First, Last: Integer): string;
var Line, Start: Integer; Hidden: Boolean;
begin
  Result := ''; Start := 0;
  for Line := First to Last + 1 do
  begin
    Hidden := (Line <= Last) and TFoldEngine.LineHidden(FEditor, Line);
    if Hidden and (Start = 0) then Start := Line;
    if not Hidden and (Start > 0) then
    begin
      Result := Result + Format('%d..%d ', [Start, Line - 1]);
      Start := 0;
    end;
  end;
  Result := '[' + Trim(Result) + ']';
end;

// Compares, line by line, what the editor hides with what the plugin says it keeps folded.
function TProbe.PluginVerify(const Title: string): Boolean;
var Manager: TFoldManager; Items: TArray<TFoldItem>; Item: TFoldItem; Expected: TArray<Boolean>; Text: TStringList;
  Count, Line, Wrong, Folded, Listed: Integer; Ranges, Detail: string;
begin
  Manager := TFoldManager.Instance;
  FView.Paint;
  Pump(500);
  Text := TStringList.Create;
  try
    Text.Text := BufferText;
    Count := Text.Count;
  finally Text.Free; end;
  Items := Manager.Items(FView.Buffer.FileName);
  SetLength(Expected, Count + 2);
  Folded := 0; Ranges := ''; Listed := 0;
  for Item in Items do
  begin
    if Listed < 8 then
    begin
      Ranges := Ranges + Format('%d..%d%s ', [Item.First, Item.Last, IfThen(Item.Collapsed, '', '(aberta)')]);
      Inc(Listed);
    end;
    if Item.Collapsed then
    begin
      Inc(Folded);
      for Line := Item.First + 1 to Item.Last do
        if Line <= Count then Expected[Line] := True;
    end;
  end;
  Wrong := 0; Detail := '';
  for Line := 1 to Count do
    if TFoldEngine.LineHidden(FEditor, Line) <> Expected[Line] then
    begin
      Inc(Wrong);
      if Wrong <= 8 then Detail := Detail + IntToStr(Line) + ' ';
    end;
  Result := Wrong = 0;
  Note(Format('PLUGIN | %s | dobras: %d (%d fechadas) %s| escondidas: %s | confere: %s%s | reaplicadas: %d | passagens: %d, a mais lenta %d ms | ' +
    'pinturas conferidas: %d, com dobra aberta indevida: %d | erros: %d %s | eventos: %s', [Title, Length(Items), Folded, Ranges,
    IfThen(Count <= 120, PluginHidden(1, Count), '(unit grande)'), BoolToStr(Result, True),
    IfThen(Wrong > 0, Format(' (%d linhas erradas: %s)', [Wrong, Trim(Detail)]), ''), Manager.Reapplied, Manager.Passes,
    Manager.MaxPassMs, FPaintsChecked, FPaintsWrong, Manager.Errors, Manager.LastError,
    StringReplace(Manager.TakeLog, sLineBreak, '; ', [rfReplaceAll])]));
  Manager.ResetStatistics;
  FPaintsChecked := 0; FPaintsWrong := 0;
end;

procedure TProbe.PluginToggleAt(Line, Col: Integer; UseShortcut: Boolean; const Title: string);
var Expected, Actual: Boolean; Outcome: string;
begin
  Note('PASSO | ' + Title);
  SetCursor(Line, Col);
  Pump(150);
  if UseShortcut then PressShortcut(Ord('B'), True, True, False)
  else if not MenuClick(ToggleItemName) then Note('PLUGIN | item de menu nao encontrado');
  // What the user must see: after a fold the line below the cursor is hidden, after anything else it is not.
  FView.Paint;
  Pump(400);
  Outcome := '';
  if Pos('nativa', Title) = 0 then
  begin
    Expected := (Pos('abrir', Title) = 0) and (Pos('abre', Title) = 0) and (Pos('nao deve', Title) = 0) and (Pos('recusado', Title) = 0);
    Actual := TFoldEngine.LineHidden(FEditor, FView.CursorPos.Line + 1) and not TFoldEngine.LineHidden(FEditor, FView.CursorPos.Line);
    Outcome := ' | resultado esperado: ' + IfThen(Expected = Actual, 'sim', 'NAO');
  end;
  PluginVerify(Format('%s | cursor foi para a linha %d%s', [Title, FView.CursorPos.Line, Outcome]));
end;

procedure TProbe.RunPlugin;
var Elide: IOTAElideActions; Reason, Before: string; Items: TArray<TFoldItem>; First, Last: Integer; Position: IOTAEditPosition;
  K: Integer; AllKinds: TFoldSettings;
begin
  Note('== PLUGIN: COMANDOS REAIS NA UNIT DE EXEMPLO (observado)');
  Supports(FView, IOTAElideActions, Elide);
  Elide.UnElideAllBlocks;
  Pump(500);
  Note(Format('PLUGIN | motor disponivel nesta IDE: %s %s', [BoolToStr(TFoldEngine.Supported(FEditor, Reason), True), Reason]));
  // Every kind at once from here on, statements and isolated begin..end mixed.
  AllKinds := CurrentSettings;
  AllKinds.Kinds := [Low(TBlockKind)..High(TBlockKind)];
  ApplySettings(AllKinds);
  Note('PLUGIN | daqui em diante com todos os tipos ligados (comandos e begin..end isolados juntos)');
  FCheckPaints := True;
  TFoldManager.Instance.ResetStatistics;

  PluginToggleAt(Marker('if-body').Line, 10, False, 'menu: dobrar com o cursor dentro do bloco do if');
  PluginToggleAt(FView.CursorPos.Line, FView.CursorPos.Col, True, 'atalho Ctrl+Alt+B na linha dobrada: abrir');
  PluginToggleAt(FView.CursorPos.Line, FView.CursorPos.Col, True, 'atalho Ctrl+Alt+B de novo: dobrar');
  PluginToggleAt(Marker('if-head').Line, 8, False, 'menu: cursor na linha do if, dobra o bloco de fora (begin do for)');
  PluginToggleAt(FView.CursorPos.Line, FView.CursorPos.Col, False, 'menu: abrir o bloco de fora, o de dentro continua dobrado');
  PluginToggleAt(Marker('while-body').Line, 10, False, 'menu: dobrar o bloco do while');
  PluginToggleAt(Marker('else-body').Line, 10, False, 'menu: dobrar o bloco do else');
  PluginToggleAt(Marker('case1-body').Line, 10, False, 'menu: dobrar um ramo do case');
  PluginToggleAt(Marker('case-else').Line, 6, False, 'menu: cursor no else do case, dobra o case inteiro');
  PluginToggleAt(Marker('try-head').Line, 4, False, 'menu: cursor na linha do try, dobra o try inteiro');
  PluginToggleAt(FView.CursorPos.Line, FView.CursorPos.Col, False, 'menu: abrir o try, os blocos de dentro continuam dobrados');
  Capture('plugin-1-dobras');

  Note('-- editar com as dobras do plugin ativas');
  TypeAtEnd(26, ' // acima', 60);
  Pump(1500);
  PluginVerify('digitar acima de todas as dobras');
  TypeAtEnd(26, #13'X := 9;'#13'X := 8;', 60);
  Pump(1500);
  PluginVerify('duas linhas novas acima');
  DeleteLine(27);
  Pump(1500);
  PluginVerify('apagar uma linha acima');
  Items := TFoldManager.Instance.Items(FSample);
  TypeAtEnd(Items[High(Items)].Last + 4, ' // abaixo', 60);
  Pump(1500);
  PluginVerify('digitar abaixo de todas as dobras');
  FView.Buffer.Module.Save(False, True);
  Pump(1500);
  PluginVerify('salvar');
  for K := 1 to 3 do begin FView.Buffer.Undo; FView.Paint; Pump(250); end;
  Pump(1500);
  PluginVerify('Desfazer 3 vezes');
  for K := 1 to 3 do begin FView.Buffer.Redo; FView.Paint; Pump(250); end;
  Pump(1500);
  PluginVerify('Refazer 3 vezes');
  TypeAtEnd(26, ' // rajada sem pausa nenhuma entre as teclas', 0);
  Pump(1500);
  PluginVerify('digitacao em rajada');

  Note('-- clique no quadradinho de uma dobra do plugin');
  Items := TFoldManager.Instance.Items(FSample);
  First := Items[0].First;
  ClickFoldBox(First);
  PluginVerify(Format('clique no quadradinho da linha %d (abre)', [First]));
  TypeAtEnd(26, ' a', 60);
  Pump(1500);
  PluginVerify('digitar com essa dobra aberta pelo usuario (deve continuar aberta)');
  ClickFoldBox(TFoldManager.Instance.Items(FSample)[0].First);
  PluginVerify('segundo clique (fecha de novo)');

  Note('-- apagar a linha do begin e a linha do end de blocos dobrados');
  Items := TFoldManager.Instance.Items(FSample);
  First := Items[0].First; Last := Items[0].Last;
  Before := BufferText;
  DeleteLine(First);
  Pump(1500);
  PluginVerify(Format('linha do begin (%d) apagada: a dobra %d..%d deve ser abandonada', [First, First, Last]));
  FView.Buffer.Undo; FView.Paint;
  Pump(1500);
  PluginVerify('Desfazer a remocao do begin');
  Note('PLUGIN | texto igual ao de antes de apagar o begin: ' + BoolToStr(BufferText = Before, True));
  Items := TFoldManager.Instance.Items(FSample);
  First := Items[0].First; Last := Items[0].Last;
  Before := BufferText;
  DeleteLine(Last);
  Pump(1500);
  PluginVerify(Format('linha do end (%d, escondida) apagada: a dobra %d..%d deve ser abandonada', [Last, First, Last]));
  FView.Buffer.Undo; FView.Paint;
  Pump(1500);
  PluginVerify('Desfazer a remocao do end');
  Note('PLUGIN | texto igual ao de antes de apagar o end: ' + BoolToStr(BufferText = Before, True));

  Note('-- Enter no fim de uma linha dobrada, pelo teclado');
  Items := TFoldManager.Instance.Items(FSample);
  First := Items[0].First;
  Position := FView.Buffer.EditPosition;
  Position.Move(First, 1); Position.MoveEOL;
  Position := nil;
  Winapi.Windows.SetFocus(FEditor.Handle);
  PostKey(VK_RETURN);
  Pump(1500);
  PluginVerify(Format('Enter no fim da linha %d: cursor na linha %d, o bloco deve abrir', [First, FView.CursorPos.Line]));
  FView.Buffer.Module.Save(False, True);
  Pump(800);
end;

procedure TProbe.SaveCurrent;
begin
  FView.Buffer.Module.Save(False, True);
end;

procedure TProbe.UnfoldAllNative;
var Elide: IOTAElideActions;
begin
  if Supports(FView, IOTAElideActions, Elide) then Elide.UnElideAllBlocks;
end;

procedure TProbe.RunPluginSecondUnit;
var Second: string; Count: Integer;

  function LineOf(const Mark: string): Integer;
  var I: Integer;
  begin
    for I := 0 to FLines.Count - 1 do
      if Pos('//@' + Mark, FLines[I]) > 0 then Exit(I + 1);
    raise Exception.Create('Marcador nao encontrado: ' + Mark);
  end;

begin
  Note('== PLUGIN: SEGUNDA UNIT, COMANDOS SEM BEGIN, TROCAR E FECHAR UNITS (observado)');
  Second := GetEnvironmentVariable('BFPROBE_SAMPLE2');
  try
    FCheckPaints := False;
    if not OpenAndBind(Second) then begin Note('PLUGIN | a segunda unit nao abriu'); Exit; end;
    FLines.LoadFromFile(Second);
    Pump(2500);
    UnfoldAllNative;
    FCheckPaints := True;
    PluginToggleAt(LineOf('stmt-if') + 1, 6, False, 'menu: comando do if sem begin (3 linhas)');
    PluginToggleAt(LineOf('stmt-else') + 1, 6, False, 'menu: comando do else sem begin');
    PluginToggleAt(LineOf('stmt-inner') + 1, 8, False, 'menu: if de dentro do for, sem begin');
    PluginToggleAt(LineOf('stmt-for'), 4, True, 'atalho: for sem begin, por cima do if de dentro');
    PluginToggleAt(LineOf('stmt-while') + 1, 6, True, 'atalho: while sem begin');
    PluginToggleAt(LineOf('reg-outer') + 1, 6, False, 'menu: bloco com REGION dentro (deve ser recusado, sem dobrar nada)');
    Capture('plugin-2-sem-begin');
    TypeAtEnd(13, ' // acima', 60);
    Pump(1500);
    PluginVerify('segunda unit: digitar acima das dobras');
    TypeAtEnd(13, #13'X := 3;', 60);
    Pump(1500);
    PluginVerify('segunda unit: linha nova acima das dobras');

    Note('-- voltar para a primeira unit e ir de novo para a segunda');
    FCheckPaints := False;
    if not OpenAndBind(FSample) then begin Note('PLUGIN | a primeira unit nao voltou'); Exit; end;
    FCheckPaints := True;
    Pump(800);
    PluginVerify('primeira unit de volta: dobras como estavam');
    TypeAtEnd(26, ' b', 60);
    Pump(1500);
    PluginVerify('primeira unit: digitar depois de voltar');
    SaveCurrent;
    FCheckPaints := False;
    if not OpenAndBind(Second) then begin Note('PLUGIN | a segunda unit nao voltou'); Exit; end;
    FCheckPaints := True;
    Pump(800);
    PluginVerify('segunda unit de volta: dobras como estavam');
    SaveCurrent;

  except
    on E: Exception do Note('EXCECAO | plugin, segunda unit | ' + E.ClassName + ': ' + E.Message);
  end;
end;

// Apart from the procedure above, so that nothing of the probe still refers to the buffer being closed.
procedure TProbe.RunPluginReopen;
var Second: string; Count: Integer;
begin
  Second := GetEnvironmentVariable('BFPROBE_SAMPLE2');
  try
    Note('-- fechar a segunda unit com dobras ativas e abrir de novo');
    SaveCurrent;
    Count := Length(TFoldManager.Instance.Items(Second));
    FCheckPaints := False;
    FView := nil; FEditor := nil;
    CloseSample(Second);
    Pump(1500);
    if not OpenAndBind(Second) then begin Note('PLUGIN | a segunda unit nao reabriu'); Exit; end;
    Pump(2500);
    UnfoldAllNative;
    FCheckPaints := True;
    PluginVerify(Format('segunda unit fechada com %d dobras e reaberta: deve voltar sem dobra nenhuma', [Count]));
    PluginToggleAt(16, 6, False, 'menu: dobrar de novo na unit que foi fechada e voltou');

    Note('-- comando de abrir todas as dobras');
    FCheckPaints := False;
    if not OpenAndBind(FSample) then Exit;
    FCheckPaints := True;
    Pump(800);
    Note('PASSO | menu: abrir todas as minhas dobras desta unit');
    MenuClick(OpenAllItemName);
    PluginVerify('primeira unit depois de abrir todas (deve ficar sem dobra do plugin)');
    TypeAtEnd(26, ' c', 60);
    Pump(1500);
    PluginVerify('digitar depois de abrir todas (nada deve voltar a dobrar)');
    SaveCurrent;
  except
    on E: Exception do Note('EXCECAO | plugin, fechar e reabrir | ' + E.ClassName + ': ' + E.Message);
  end;
end;

procedure TProbe.RunPluginDebug;
var Actions: TCustomActionList; RunAction: TContainedAction; I, Line, First, Last: Integer; Blocks: TArray<TBlock>; Block: TBlock;
begin
  Note('== PLUGIN: DEPURAR COM DOBRAS DO PLUGIN (observado)');
  try
    FCheckPaints := False;
    if GetActiveProject = nil then begin Note('PLUGIN | o projeto de teste nao esta aberto'); Exit; end;
    if not OpenAndBind(FSample) then Exit;
    Pump(800);
    First := 0; Last := 0;
    Blocks := FindBlocks(BufferText);
    for Block in Blocks do
      if (Block.Kind = bkBegin) and (Block.Depth = 3) then begin First := Block.FirstLine; Last := Block.LastLine; Break; end;
    PluginToggleAt(First + 1, 10, False, Format('menu: dobrar o bloco %d..%d antes de depurar', [First, Last]));
    (BorlandIDEServices as IOTADebuggerServices).NewSourceBreakpoint(FSample, First + 1, nil);
    Note(Format('PLUGIN | breakpoint na linha %d, escondida pela dobra', [First + 1]));
    RunAction := nil;
    Actions := (BorlandIDEServices as INTAServices).ActionList;
    for I := 0 to Actions.ActionCount - 1 do
      if SameText(Actions.Actions[I].Name, 'RunRunCommand') then RunAction := Actions.Actions[I];
    Note('PASSO | executar o projeto no depurador');
    RunAction.Execute;
    Line := WaitDebugStop(90);
    Note(Format('PLUGIN | processo parado na linha %d', [Line]));
    if Line <= 0 then Exit;
    PluginVerify('parado no breakpoint dentro do bloco (deve estar aberto para mostrar a linha)');
    for I := 1 to 3 do
    begin
      DebugStep;
      Pump(400);
      Line := WaitDebugStop(20);
      PluginVerify(Format('passo %d: parado na linha %d', [I, Line]));
    end;
    Note('PASSO | encerrar o processo depurado');
    DebugTerminate;
    for I := 1 to 80 do
    begin
      Pump(250);
      if DebugLine = -1 then Break;
    end;
    Pump(1500);
    PluginVerify('depois de encerrar a depuracao');
    PluginToggleAt(First + 1, 10, False, 'menu: dobrar de novo depois da depuracao');
    MenuClick(OpenAllItemName);
    PluginVerify('abrir todas no fim');
  except
    on E: Exception do Note('EXCECAO | plugin, depuracao | ' + E.ClassName + ': ' + E.Message);
  end;
end;

procedure TProbe.RunPluginBig;
var FileName: string; Blocks: TArray<TBlock>; Block: TBlock; Watch: TStopwatch; Count, Total: Integer; Lines: TStringList;
begin
  Note('== PLUGIN: UNIT GRANDE (observado)');
  FileName := GetEnvironmentVariable('BFPROBE_BIG');
  try
    FCheckPaints := False;
    if (FileName = '') or not OpenAndBind(FileName) then begin Note('PLUGIN | a unit grande nao abriu'); Exit; end;
    Pump(4000);
    (FView as IOTAElideActions).UnElideAllBlocks;
    Lines := TStringList.Create;
    try
      Lines.Text := BufferText;
      Blocks := FindBlocks(Lines.Text);
      Total := 0;
      for Block in Blocks do
        if Block.Depth >= 1 then Inc(Total);
      Note(Format('PLUGIN | %s: %d linhas, %d blocos (%d internos)', [ExtractFileName(FileName), Lines.Count, Length(Blocks), Total]));
      // A realistic amount first, then far more than anyone folds by hand.
      Watch := TStopwatch.StartNew;
      Count := 0;
      for Block in Blocks do
        if (Block.Depth = 3) and (Block.FirstLine > 4000) and (Count < 20) then
        begin
          TFoldManager.Instance.FoldRange(FView, Block.FirstLine, Block.LastLine, Lines);
          Inc(Count);
        end;
      Note(Format('PLUGIN | dobrar %d blocos no meio da unit: %d ms', [Count, Watch.ElapsedMilliseconds]));
      TFoldManager.Instance.ResetStatistics;
      FCheckPaints := True;
      PluginVerify('20 dobras');
      TypeAtEnd(8, ' // topo', 60);
      Pump(2000);
      PluginVerify('20 dobras: digitar no topo da unit');
      SetCursor(5000, 1);
      Pump(600);
      TypeAtEnd(5000, ' // meio', 60);
      Pump(2000);
      PluginVerify('20 dobras: digitar na linha 5000, depois delas');
      FCheckPaints := False;
      Lines.Text := BufferText;
      Blocks := FindBlocks(Lines.Text);
      Watch := TStopwatch.StartNew;
      for Block in Blocks do
        if (Block.Depth = 3) and (Count < 400) and ((Block.FirstLine < 4000) or (Block.FirstLine > 4600)) then
        begin
          TFoldManager.Instance.FoldRange(FView, Block.FirstLine, Block.LastLine, Lines);
          Inc(Count);
        end;
    finally Lines.Free; end;
    Note(Format('PLUGIN | dobrar mais blocos, total %d: %d ms', [Count, Watch.ElapsedMilliseconds]));
    TFoldManager.Instance.ResetStatistics;
    PluginVerify('400 dobras');
    TypeAtEnd(8, ' x', 60);
    Pump(3000);
    PluginVerify('400 dobras: digitar no topo da unit');
    TypeAtEnd(8, #13'// linha nova', 60);
    Pump(3000);
    PluginVerify('400 dobras: linha nova no topo da unit');
    SetCursor(5000, 1);
    Pump(600);
    TypeAtEnd(5000, ' y', 60);
    Pump(3000);
    PluginVerify('400 dobras: digitar na linha 5000');
    FView.Buffer.Module.Save(False, True);
    Pump(2000);
    PluginVerify('400 dobras: salvar');
    Watch := TStopwatch.StartNew;
    MenuClick(OpenAllItemName);
    Note(Format('PLUGIN | abrir todas as 400: %d ms', [Watch.ElapsedMilliseconds]));
    PluginVerify('400 dobras abertas pelo comando');
  except
    on E: Exception do Note('EXCECAO | plugin, unit grande | ' + E.ClassName + ': ' + E.Message);
  end;
end;

{ The menu of the plugin and its settings window. }

function TProbe.MenuItemByName(const ItemName: string): TMenuItem;

  function Find(Parent: TMenuItem): TMenuItem;
  var I: Integer;
  begin
    for I := 0 to Parent.Count - 1 do
    begin
      if SameText(Parent[I].Name, ItemName) then Exit(Parent[I]);
      Result := Find(Parent[I]);
      if Result <> nil then Exit;
    end;
    Result := nil;
  end;

begin
  Result := Find((BorlandIDEServices as INTAServices).MainMenu.Items);
end;

function TProbe.MenuText(Parent: TMenuItem): string;
var I: Integer;
begin
  Result := '';
  if Parent = nil then Exit('(nao existe)');
  for I := 0 to Parent.Count - 1 do
  begin
    Result := Result + '[' + StringReplace(Parent[I].Caption, '&', '', [rfReplaceAll]);
    if Parent[I].ShortCut <> 0 then Result := Result + ' | ' + ShortCutToText(Parent[I].ShortCut);
    Result := Result + '] ';
  end;
end;

procedure TProbe.CaptureForm(Form: TCustomForm; const Name: string);
var Bounds: TRect; Bitmap: TBitmap; Png: TPngImage; Desktop: HDC;
begin
  SetWindowPos(Form.Handle, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE or SWP_NOSIZE or SWP_NOACTIVATE);
  Form.Update;
  Pump(500);
  GetWindowRect(Form.Handle, Bounds);
  Bitmap := TBitmap.Create; Png := TPngImage.Create;
  try
    Bitmap.PixelFormat := pf24bit;
    Bitmap.SetSize(Bounds.Width, Bounds.Height);
    Desktop := GetDC(0);
    try
      BitBlt(Bitmap.Canvas.Handle, 0, 0, Bounds.Width, Bounds.Height, Desktop, Bounds.Left, Bounds.Top, SRCCOPY);
    finally ReleaseDC(0, Desktop); end;
    Png.Assign(Bitmap);
    Png.SaveToFile(TPath.Combine(FDir, Name + '.png'));
    Note(Format('CAPTURA | %s.png | %dx%d', [Name, Bitmap.Width, Bitmap.Height]));
  finally Png.Free; Bitmap.Free; end;
end;

// Runs while the expected modal window is open: the picture, then what a user would do in it.
procedure TProbe.ModalTick(Sender: TObject);
var Form: TCustomForm; Action: TProc<TCustomForm>;
begin
  FModalTimer.Enabled := False;
  Form := Screen.ActiveCustomForm;
  if (Form = nil) or not Form.ClassNameIs(FModalClass) then
  begin
    Note('MODAL | a janela ' + FModalClass + ' nao esta aberta; janela ativa: ' + IfThen(Form = nil, '(nenhuma)', Form.ClassName));
    if (Form <> nil) and (fsModal in Form.FormState) then Form.ModalResult := mrCancel;
    Exit;
  end;
  try
    if FModalShot <> '' then CaptureForm(Form, FModalShot);
    // Held here: the action may set the next one, for a window opened from this one.
    Action := FModalAction;
    Action(Form);
  except
    on E: Exception do
    begin
      Note('EXCECAO | janela ' + Form.ClassName + ' | ' + E.ClassName + ': ' + E.Message);
      Form.ModalResult := mrCancel;
    end;
  end;
end;

procedure TProbe.WithSettingsForm(const Shot: string; const Action: TProc<TCustomForm>);
begin
  WithModal(SettingsItemName, 'TFoldSettingsForm', Shot, Action);
end;

// Clicks the menu item, which opens a modal window of the class, and runs the action in it.
procedure TProbe.WithModal(const ItemName, FormClass, Shot: string; const Action: TProc<TCustomForm>);
begin
  if FModalTimer = nil then
  begin
    FModalTimer := TTimer.Create(FTimer);
    FModalTimer.Enabled := False;
    FModalTimer.Interval := 700;
    FModalTimer.OnTimer := ModalTick;
  end;
  FModalAction := Action;
  FModalShot := Shot;
  FModalClass := FormClass;
  FModalTimer.Enabled := True;
  if not MenuClick(ItemName) then Note('MODAL | item ' + ItemName + ' nao encontrado no menu');
  FModalTimer.Enabled := False;
end;

procedure TProbe.RunPluginSettings;
var Root, Fake: TMenuItem; Settings: TFoldSettings; Registry: TRegistry; Elide: IOTAElideActions; Line: Integer;

  // What must be hidden at this point, then everything is opened for the next check.
  procedure Expect(const What, Hidden: string);
  var Actual: string;
  begin
    Actual := PluginHidden(1, FLines.Count);
    Note(Format('PADRAO | %s | escondidas %s | devia ser %s | resultado esperado: %s', [What, Actual, Hidden,
      IfThen(Actual = Hidden, 'sim', 'NAO')]));
    MenuClick(OpenAllItemName);
    Pump(300);
  end;

  procedure ShowSettings(const Title: string);
  begin
    Settings := CurrentSettings;
    Note(Format('SETTINGS | %s | ativo=%s | dobrar=%s | abrir todas=%s | tipos=%s | texto="%s"', [Title,
      BoolToStr(Settings.Enabled, True), ShortCutToText(Settings.ToggleKey), ShortCutToText(Settings.OpenAllKey),
      SetToString(PTypeInfo(TypeInfo(TBlockKinds)), Byte(Settings.Kinds), True), Settings.Marker]));
  end;

begin
  Note('== PLUGIN: MENU CS.CODER E TELA DE CONFIGURACOES (observado)');
  try
    Supports(FView, IOTAElideActions, Elide);
    Elide.UnElideAllBlocks;
    Root := MenuItemByName(SharedRootName);
    Note('MENU | menu principal tem o item CS.Coder: ' + BoolToStr(Root <> nil, True) + ' | dentro dele: ' + MenuText(Root));
    Note('MENU | dentro de Block Folding: ' + MenuText(MenuItemByName(BranchName)));

    WithSettingsForm('plugin-configuracoes', procedure(Form: TCustomForm)
      begin
        (Form.FindComponent('btnDefaults') as TButton).Click;
        (Form.FindComponent('btnOK') as TButton).Click;
      end);
    ShowSettings('depois de Restaurar padroes + OK');
    Note('MENU | dentro de Block Folding, com os atalhos: ' + MenuText(MenuItemByName(BranchName)));
    Line := Marker('if-body').Line;
    PluginToggleAt(Line, 10, True, 'atalho padrao Ctrl+Alt+B: dobrar');
    PluginToggleAt(FView.CursorPos.Line, FView.CursorPos.Col, True, 'atalho padrao Ctrl+Alt+B: abrir');

    WithSettingsForm('', procedure(Form: TCustomForm)
      begin
        (Form.FindComponent('hkToggle') as THotKey).HotKey := ShortCut(Ord('J'), [ssCtrl, ssAlt]);
        (Form.FindComponent('chkTry') as TCheckBox).Checked := False;
        (Form.FindComponent('edtMarker') as TEdit).Text := '<bloco>';
        (Form.FindComponent('btnOK') as TButton).Click;
      end);
    ShowSettings('atalho trocado para Ctrl+Alt+J, try desmarcado, texto <bloco>');
    Registry := TRegistry.Create(KEY_READ);
    try
      Registry.RootKey := HKEY_CURRENT_USER;
      if Registry.OpenKeyReadOnly(SettingsRegistryKey) then
        Note(Format('SETTINGS | gravado no registro em HKCU%s | Marker="%s" Kinds="%s" ToggleKey=%s', [SettingsRegistryKey,
          Registry.ReadString('Marker'), Registry.ReadString('Kinds'), ShortCutToText(TShortCut(Registry.ReadInteger('ToggleKey')))]))
      else Note('SETTINGS | chave do registro nao encontrada: ' + SettingsRegistryKey);
    finally Registry.Free; end;
    Note('MENU | dentro de Block Folding, depois da troca: ' + MenuText(MenuItemByName(BranchName)));
    PluginToggleAt(Line, 10, True, 'atalho antigo Ctrl+Alt+B: nao deve dobrar mais');
    Note('PASSO | atalho novo Ctrl+Alt+J');
    SetCursor(Line, 10);
    PressShortcut(Ord('J'), True, True, False);
    PluginVerify('atalho novo Ctrl+Alt+J: dobrar');
    Capture('plugin-0-texto-da-dobra');
    PressShortcut(Ord('J'), True, True, False);
    PluginVerify('atalho novo Ctrl+Alt+J: abrir');
    PluginToggleAt(Marker('try-head').Line, 4, False, 'menu na linha do try com try desmarcado: sobra so o metodo, que e dobrado pela dobra nativa da IDE');
    Note('PLUGIN | escondidas pela dobra nativa: ' + PluginHidden(1, FLines.Count));
    Elide.UnElideAllBlocks;
    Pump(500);

    WithSettingsForm('', procedure(Form: TCustomForm)
      begin
        (Form.FindComponent('chkEnabled') as TCheckBox).Checked := False;
        (Form.FindComponent('btnOK') as TButton).Click;
      end);
    ShowSettings('Block Folding desativado');
    PluginToggleAt(Line, 10, False, 'menu com o plugin desativado: nao deve dobrar');

    WithSettingsForm('', procedure(Form: TCustomForm)
      begin
        (Form.FindComponent('hkToggle') as THotKey).HotKey := ShortCut(Ord('Q'), [ssCtrl, ssAlt]);
        (Form.FindComponent('btnCancel') as TButton).Click;
      end);
    ShowSettings('mudanca cancelada com o botao Cancelar (nada deve mudar)');

    WithSettingsForm('', procedure(Form: TCustomForm)
      begin
        (Form.FindComponent('btnDefaults') as TButton).Click;
        (Form.FindComponent('btnOK') as TButton).Click;
      end);
    ShowSettings('padroes restaurados');
    PluginToggleAt(Line, 10, True, 'atalho padrao de volta: dobrar');
    PluginToggleAt(FView.CursorPos.Line, FView.CursorPos.Col, True, 'atalho padrao de volta: abrir');

    Note('-- padrao: a dobra acontece na linha do comando');
    MenuClick(OpenAllItemName);
    PluginToggleAt(Marker('if-body').Line, 10, False, 'padrao: cursor dentro do if dobra na linha do if, com o else junto');
    Expect('if com o else', '[31..38]');
    PluginToggleAt(Marker('else-body').Line, 10, False, 'padrao: cursor dentro do else dobra so a parte do else');
    Expect('parte do else', '[36..38]');
    PluginToggleAt(Marker('for-begin').Line, 8, False, 'padrao: cursor na linha do begin do for dobra na linha do for');
    Expect('for inteiro', '[29..43]');
    PluginToggleAt(Marker('while-body').Line, 10, False, 'padrao: cursor dentro do while dobra na linha do while');
    Expect('while', '[40..42]');
    PluginToggleAt(Marker('case1-body').Line, 10, False, 'padrao: cursor num ramo do case dobra o case');
    Expect('case', '[59..70]');
    WithSettingsForm('plugin-configuracoes-2', procedure(Form: TCustomForm)
      begin
        (Form.FindComponent('chkBegin') as TCheckBox).Checked := True;
        (Form.FindComponent('btnOK') as TButton).Click;
      end);
    ShowSettings('begin..end isolado ligado');
    PluginToggleAt(Marker('if-body').Line, 10, False, 'com begin isolado: cursor dentro do if dobra so o begin do if');
    PluginToggleAt(Marker('else-body').Line, 10, False, 'com begin isolado: o begin do else dobra em separado');
    Expect('os dois begins, cada um por si', '[32..34 37..38]');
    WithSettingsForm('', procedure(Form: TCustomForm)
      begin
        (Form.FindComponent('btnDefaults') as TButton).Click;
        (Form.FindComponent('btnOK') as TButton).Click;
      end);
    ShowSettings('padroes restaurados de novo');

    Note('PASSO | Sobre... e, de dentro dela, a janela da licenca');
    WithModal(AboutItemName, 'TFoldAboutForm', 'plugin-sobre', procedure(Form: TCustomForm)
      var I: Integer; Texts: string;
      begin
        Texts := '';
        for I := 0 to Form.ComponentCount - 1 do
          if Form.Components[I] is TLabel then Texts := Texts + TLabel(Form.Components[I]).Caption + ' // ';
        Note('SOBRE | titulo "' + Form.Caption + '" | ' + StringReplace(Texts, sLineBreak, ' ', [rfReplaceAll]));
        // The licence window is modal inside this one: its turn comes on the next tick.
        FModalClass := 'TFoldLicenseForm';
        FModalShot := 'plugin-sobre-licenca';
        FModalAction := procedure(License: TCustomForm)
          var J: Integer;
          begin
            for J := 0 to License.ComponentCount - 1 do
              if License.Components[J] is TMemo then
                Note(Format('SOBRE | licenca "%s" | %d linhas | primeira: %s', [License.Caption,
                  TMemo(License.Components[J]).Lines.Count, TMemo(License.Components[J]).Lines[0]]));
            License.ModalResult := mrOk;
          end;
        FModalTimer.Enabled := True;
        (Form.FindComponent('btnLicense') as TButton).Click;
        Form.ModalResult := mrCancel;
      end);

    Note('-- convivencia no menu CS.Coder com outra ferramenta (ramo simulado do Unit Styler)');
    Root := MenuItemByName(SharedRootName);
    Fake := TMenuItem.Create(nil);
    try
      Fake.Caption := 'Unit Styler';
      Root.Insert(0, Fake);
      Note('MENU | outra ferramenta presente: ' + MenuText(Root));
      BlockFolding.Register.Unregister;
      Root := MenuItemByName(SharedRootName);
      Note('MENU | Block Folding descarregado, a outra ferramenta continua: ' + MenuText(Root));
      BlockFolding.Register.Register;
      Root := MenuItemByName(SharedRootName);
      Note('MENU | Block Folding carregado depois da outra ferramenta: ' + MenuText(Root));
    finally
      Fake.Free;
    end;
    BlockFolding.Register.Unregister;
    Note('MENU | sem nenhuma ferramenta, o item CS.Coder sai do menu: ' + BoolToStr(MenuItemByName(SharedRootName) = nil, True));
    BlockFolding.Register.Register;
    Note('MENU | Block Folding carregado de novo: ' + MenuText(MenuItemByName(SharedRootName)) + '| ' +
      MenuText(MenuItemByName(BranchName)));
    PluginToggleAt(Line, 10, True, 'depois de recarregar: atalho dobra');
    PluginToggleAt(FView.CursorPos.Line, FView.CursorPos.Col, False, 'depois de recarregar: menu abre');
  except
    on E: Exception do Note('EXCECAO | menu e configuracoes | ' + E.ClassName + ': ' + E.Message);
  end;
end;

{ Rules of the editor kernel for nested blocks, tried one at a time with the engine. }

procedure TProbe.RunFoldNest;
var Lines: TStringList; Blocks: TArray<TBlock>; Block, Inner, Outer, Body: TBlock; Round: Integer; Risk: string;
  Elide: IOTAElideActions; Add, Close, Remove: TProc<TBlock>;

  procedure Show(const Title: string);
  var Line: Integer; Starts, Inside: string;
  begin
    FView.Paint;
    Pump(300);
    Starts := ''; Inside := '';
    for Line := 1 to Lines.Count do
    begin
      if TFoldEngine.BlockStartsAt(FEditor, Line) then Starts := Starts + IntToStr(Line) + ' ';
      if (Line >= 24) and (Line <= 46) and not LineQuery('IsInElisionBlock', Line) then Inside := Inside + IntToStr(Line) + ' ';
    end;
    Note(Format('NEST | %s | inicios=[%s] | escondidas=%s | linhas 24..46 fora de qualquer bloco=[%s]', [Title, Trim(Starts),
      PluginHidden(1, Lines.Count), Trim(Inside)]));
  end;

  procedure Step(const Title: string; const Action: TProc);
  begin
    Note('PASSO | ' + Title);
    try
      Action;
      Show(Title);
    except
      on E: Exception do Note('EXCECAO | ' + Title + ' | ' + E.ClassName + ': ' + E.Message);
    end;
  end;

begin
  Note('== REGRAS DO NUCLEO PARA BLOCOS ANINHADOS (observado)');
  Add := procedure(B: TBlock)
    begin
      TFoldEngine.RegisterBlock(FEditor, B.FirstLine, Length(Lines[B.FirstLine - 1]), B.LastLine, Length(Lines[B.LastLine - 1]));
    end;
  Close := procedure(B: TBlock)
    begin
      TFoldEngine.Collapse(FEditor, B.FirstLine, Length(Lines[B.FirstLine - 1]), B.LastLine, Length(Lines[B.LastLine - 1]));
    end;
  Remove := procedure(B: TBlock)
    begin
      TFoldEngine.RemoveBlock(FEditor, B.FirstLine, Length(Lines[B.FirstLine - 1]), B.LastLine, Length(Lines[B.LastLine - 1]));
    end;
  Risk := GetEnvironmentVariable('BFPROBE_RISK');
  Supports(FView, IOTAElideActions, Elide);
  Elide.UnElideAllBlocks;
  Pump(500);
  Lines := TStringList.Create;
  try
    Lines.Text := BufferText;
    Blocks := FindBlocks(Lines.Text);
    for Block in Blocks do
    begin
      if (Block.Kind = bkBegin) and (Block.Depth = 3) and (Inner.FirstLine = 0) then Inner := Block;
      if (Block.Kind = bkBegin) and (Block.Depth = 2) and (Outer.FirstLine = 0) then Outer := Block;
      if (Block.Kind = bkBegin) and (Block.Depth = 0) and (Block.FirstLine < Outer.FirstLine) or
        ((Block.Kind = bkBegin) and (Block.Depth = 0) and (Outer.FirstLine = 0) and (Block.LastLine > 40)) then Body := Block;
    end;
    Note(Format('NEST | interno %d..%d | externo %d..%d | corpo do metodo %d..%d | teste: %s', [Inner.FirstLine, Inner.LastLine,
      Outer.FirstLine, Outer.LastLine, Body.FirstLine, Body.LastLine, Risk]));
    Show('estado inicial');
    if Risk = 'outer-after-inner' then
    begin
      Step('registrar e dobrar o interno', procedure begin Add(Inner); Close(Inner); end);
      Step('registrar o EXTERNO depois, com o interno dobrado', procedure begin Add(Outer); end);
      Step('dobrar o externo', procedure begin Close(Outer); end);
      Step('abrir o externo', procedure begin TFoldEngine.Open(FEditor, Outer.FirstLine); end);
      Exit;
    end;
    if Risk = 'outer-after-open-inner' then
    begin
      Step('registrar o interno, aberto', procedure begin Add(Inner); end);
      Step('registrar o EXTERNO depois, com o interno aberto', procedure begin Add(Outer); end);
      Step('dobrar o externo', procedure begin Close(Outer); end);
      Step('abrir o externo', procedure begin TFoldEngine.Open(FEditor, Outer.FirstLine); end);
      Step('dobrar o interno', procedure begin Close(Inner); end);
      Exit;
    end;
    if (Risk = 'same-end') or (Risk = 'region-inside') then
    begin
      // These two use the second sample unit.
      if not OpenAndBind(GetEnvironmentVariable('BFPROBE_SAMPLE2')) then begin Note('NEST | a segunda unit nao abriu'); Exit; end;
      Pump(2500);
      Lines.Text := BufferText;
      Blocks := FindBlocks(Lines.Text);
      Inner := Default(TBlock); Outer := Default(TBlock);
      for Block in Blocks do
        if Risk = 'same-end' then
        begin
          if Pos('//@stmt-for', Lines[Block.FirstLine - 1]) > 0 then Outer := Block;
          if Pos('//@stmt-inner', Lines[Block.FirstLine - 1]) > 0 then Inner := Block;
        end
        else if Pos('//@reg-outer', Lines[Block.FirstLine - 1]) > 0 then Outer := Block;
      Show(Format('segunda unit: externo %d..%d interno %d..%d', [Outer.FirstLine, Outer.LastLine, Inner.FirstLine, Inner.LastLine]));
      if Risk = 'same-end' then
      begin
        Step('registrar externo e interno, que terminam na mesma linha', procedure begin Add(Outer); Add(Inner); end);
        Step('dobrar o interno', procedure begin Close(Inner); end);
        Step('dobrar o externo', procedure begin Close(Outer); end);
        Step('abrir o externo', procedure begin TFoldEngine.Open(FEditor, Outer.FirstLine); end);
        Step('abrir o interno', procedure begin TFoldEngine.Open(FEditor, Inner.FirstLine); end);
        Step('dobrar so o externo', procedure begin Close(Outer); end);
        Step('abrir o externo de novo', procedure begin TFoldEngine.Open(FEditor, Outer.FirstLine); end);
      end
      else
      begin
        Step('registrar o bloco que tem um REGION nativo dentro', procedure begin Add(Outer); end);
        Step('dobrar esse bloco', procedure begin Close(Outer); end);
        Step('abrir esse bloco', procedure begin TFoldEngine.Open(FEditor, Outer.FirstLine); end);
        Step('abrir tudo pela IDE', procedure begin (FView as IOTAElideActions).UnElideAllBlocks; end);
        Step('registrar e dobrar de novo com o REGION aberto', procedure begin Add(Outer); Close(Outer); end);
        Step('abrir', procedure begin TFoldEngine.Open(FEditor, Outer.FirstLine); end);
      end;
      Exit;
    end;
    if Risk = 'body-alone' then
    begin
      Step('registrar so o corpo do metodo', procedure begin Add(Body); end);
      Step('dobrar o corpo do metodo', procedure begin Close(Body); end);
      Step('abrir o corpo do metodo', procedure begin TFoldEngine.Open(FEditor, Body.FirstLine); end);
      Step('UnElideNearestBlock da IDE com o cursor na linha do begin', procedure
        begin SetCursor(Body.FirstLine, 2); (FView as IOTAElideActions).UnElideNearestBlock; end);
      Exit;
    end;
    if Risk = 'body-open' then
    begin
      // The body of the method ends on the same line as the IDE's own block of the method.
      Step('registrar o corpo do metodo, aberto', procedure begin Add(Body); end);
      Step('registrar externo e interno dentro dele', procedure begin Add(Outer); Add(Inner); end);
      Step('dobrar o interno', procedure begin Close(Inner); end);
      Step('dobrar o externo', procedure begin Close(Outer); end);
      Step('dobrar o corpo do metodo', procedure begin Close(Body); end);
      Step('abrir o corpo do metodo', procedure begin TFoldEngine.Open(FEditor, Body.FirstLine); end);
      Exit;
    end;
    // Default: remove and put back, the way an outer block can be added around inner ones.
    Step('registrar e dobrar o interno', procedure begin Add(Inner); Close(Inner); end);
    Step('remover o interno (RemoveElisionBlock com as posicoes exatas)', procedure begin Remove(Inner); end);
    Step('registrar o externo, depois o interno', procedure begin Add(Outer); Add(Inner); end);
    Step('dobrar o interno e o externo', procedure begin Close(Inner); Close(Outer); end);
    Step('abrir o externo', procedure begin TFoldEngine.Open(FEditor, Outer.FirstLine); end);
    for Round := 1 to 25 do
    begin
      try
        TFoldEngine.Open(FEditor, Inner.FirstLine);
        Remove(Inner);
        Remove(Outer);
        Add(Outer); Add(Inner);
        Close(Inner);
        if Odd(Round) then Close(Outer);
        FView.Paint;
        Pump(60);
        if Odd(Round) then TFoldEngine.Open(FEditor, Outer.FirstLine);
      except
        on E: Exception do begin Note(Format('EXCECAO | rodada %d de remover e recolocar | %s: %s', [Round, E.ClassName, E.Message])); Break; end;
      end;
    end;
    Show('depois de 25 rodadas de remover os dois e recolocar');
    Step('remover os dois no fim', procedure begin TFoldEngine.Open(FEditor, Inner.FirstLine); Remove(Inner); Remove(Outer); end);
    TypeAtEnd(26, ' // depois', 60);
    Pump(1500);
    Show('depois de editar');
    Note('NEST | texto do buffer: ' + IntToStr(Length(BufferText)) + ' caracteres');
  finally
    Lines.Free;
  end;
end;

{ The plugin next to CnPack, with code folding turned on or off in the editor options. }

// A mouse click on a character of a line, placed from the geometry the editor reports.
procedure TProbe.ClickAt(Line, Col: Integer);
var Current: INTACodeEditorState; First, Second: TRect; Row, L, X, Y: Integer; Screen: TPoint;
begin
  if not FRealInput then Winapi.Windows.SetFocus(FEditor.Handle);
  Current := State;
  // Screen row of the line: the lines above it that are not hidden.
  Row := 0;
  for L := FView.TopPos.Line to Line do
    if not TFoldEngine.LineHidden(FEditor, L) then Inc(Row);
  First := Current.GetCharacterPosPx(1, Current.TopLine);
  Second := Current.GetCharacterPosPx(2, Current.TopLine + 1);
  X := First.Left + (Col - 1) * (Second.Left - First.Left) + 2;
  Y := First.Top + (Row - 1) * (Second.Top - First.Top) + (Second.Top - First.Top) div 2;
  if FRealInput then
  begin
    if not BringToFront then begin Note('  clique real nao enviado: a IDE de teste nao esta em primeiro plano'); Exit; end;
    Screen := FEditor.ClientToScreen(Point(X, Y));
    SetCursorPos(Screen.X, Screen.Y);
    Pump(150);
    mouse_event(MOUSEEVENTF_LEFTDOWN, 0, 0, 0, 0);
    mouse_event(MOUSEEVENTF_LEFTUP, 0, 0, 0, 0);
  end
  else
  begin
    PostMessage(FEditor.Handle, WM_MOUSEMOVE, 0, MakeLParam(X, Y));
    PostMessage(FEditor.Handle, WM_LBUTTONDOWN, MK_LBUTTON, MakeLParam(X, Y));
    PostMessage(FEditor.Handle, WM_LBUTTONUP, 0, MakeLParam(X, Y));
  end;
  Pump(400);
  Note(Format('  clique na linha %d coluna %d (x=%d y=%d): cursor ficou na linha %d coluna %d', [Line, Col, X, Y,
    FView.CursorPos.Line, FView.CursorPos.Col]));
end;

// A mouse click on the - or + the plugin draws in the gutter of a line.
procedure TProbe.ClickSign(Line: Integer);
var Current: INTACodeEditorState; First, Second: TRect; Row, L, X, Y, Stride, Width, Height, Size, I, P, FromFirst, FromLast, Top, Bottom: Integer;
  Screen: TPoint; Bounds: TRect; Frames: TList<TBytes>; Times: TList<Integer>; Bitmap: TBitmap; Png: TPngImage; Watch: TStopwatch;
  Stop: Boolean; Thread: TThread; Detail: string; A, B, C: PByte;
begin
  Current := State;
  Row := 0;
  for L := FView.TopPos.Line to Line do
    if not TFoldEngine.LineHidden(FEditor, L) then Inc(Row);
  First := Current.GetCharacterPosPx(1, Current.TopLine);
  Second := Current.GetCharacterPosPx(2, Current.TopLine + 1);
  X := Current.GetCharacterPosPx(FView.LeftColumn, Current.TopLine).Left - 6;
  Y := First.Top + (Row - 1) * (Second.Top - First.Top) + (Second.Top - First.Top) div 2;
  if FRealInput then
  begin
    if not BringToFront then begin Note('  clique real nao enviado: a IDE de teste nao esta em primeiro plano'); Exit; end;
    Screen := FEditor.ClientToScreen(Point(X, Y));
    SetCursorPos(Screen.X, Screen.Y);
    Pump(400);
    // A person holds the button for a moment: the IDE runs between the press and the release.
    // Another thread reads the screen all along and keeps every picture that differs from
    // the one before, so what shows for an instant, even inside one message, is seen.
    Inc(FFilm);
    GetWindowRect(FEditor.Handle, Bounds);
    Width := 480; if Width > Bounds.Width then Width := Bounds.Width;
    Height := Bounds.Height;
    Stride := (Width * 3 + 3) and not 3;
    Size := Stride * Height;
    Frames := TList<TBytes>.Create; Times := TList<Integer>.Create;
    try
      Stop := False;
      Watch := TStopwatch.StartNew;
      Thread := TThread.CreateAnonymousThread(procedure
        var Desktop, Memory: HDC; Dib, Old: HBITMAP; Info: TBitmapInfo; Bits: Pointer; Copy: TBytes;
        begin
          FillChar(Info, SizeOf(Info), 0);
          Info.bmiHeader.biSize := SizeOf(TBitmapInfoHeader);
          Info.bmiHeader.biWidth := Width; Info.bmiHeader.biHeight := -Height;
          Info.bmiHeader.biPlanes := 1; Info.bmiHeader.biBitCount := 24; Info.bmiHeader.biCompression := BI_RGB;
          Desktop := GetDC(0);
          Memory := CreateCompatibleDC(Desktop);
          Dib := CreateDIBSection(Memory, Info, DIB_RGB_COLORS, Bits, 0, 0);
          Old := SelectObject(Memory, Dib);
          try
            while not Stop and (Frames.Count < 60) do
            begin
              BitBlt(Memory, 0, 0, Width, Height, Desktop, Bounds.Left, Bounds.Top, SRCCOPY);
              GdiFlush;
              if (Frames.Count = 0) or not CompareMem(Bits, @Frames.Last[0], Size) then
              begin
                SetLength(Copy, Size);
                Move(Bits^, Copy[0], Size);
                Times.Add(Watch.ElapsedMilliseconds);
                Frames.Add(Copy);
                Copy := nil;
              end;
            end;
          finally
            SelectObject(Memory, Old); DeleteObject(Dib); DeleteDC(Memory); ReleaseDC(0, Desktop);
          end;
        end);
      Thread.FreeOnTerminate := False;
      Thread.Start;
      try
        Pump(100);
        mouse_event(MOUSEEVENTF_LEFTDOWN, 0, 0, 0, 0);
        Detail := Format('apertou em %d ms', [Watch.ElapsedMilliseconds]);
        Pump(120);
        mouse_event(MOUSEEVENTF_LEFTUP, 0, 0, 0, 0);
        Detail := Detail + Format(', soltou em %d ms', [Watch.ElapsedMilliseconds]);
        Pump(900);
      finally
        Stop := True;
        Thread.WaitFor;
        Thread.Free;
      end;
      Note(Format('  FILME %d | linha %d | %s | imagens diferentes: %d', [FFilm, Line, Detail, Frames.Count]));
      Bitmap := TBitmap.Create; Png := TPngImage.Create;
      try
        Bitmap.PixelFormat := pf24bit;
        Bitmap.SetSize(Width, Height);
        for I := 0 to Frames.Count - 1 do
        begin
          // How far the picture is from the first and from the last one, and the rows that changed.
          FromFirst := 0; FromLast := 0; Top := -1; Bottom := -1;
          A := @Frames[I][0]; B := @Frames[0][0]; C := @Frames[Frames.Count - 1][0];
          for P := 0 to Size - 1 do
          begin
            if A[P] <> B[P] then Inc(FromFirst);
            if A[P] <> C[P] then Inc(FromLast);
          end;
          if I > 0 then
          begin
            B := @Frames[I - 1][0];
            for P := 0 to Size - 1 do
              if A[P] <> B[P] then
              begin
                if Top < 0 then Top := P div Stride;
                Bottom := P div Stride;
              end;
          end;
          Note(Format('    imagem %.2d em %d ms | difere da primeira em %d, da ultima em %d | mudou da anterior nas linhas de pixel %d..%d',
            [I, Times[I], FromFirst, FromLast, Top, Bottom]));
          for L := 0 to Height - 1 do Move(Frames[I][L * Stride], Bitmap.ScanLine[L]^, Stride);
          Png.Assign(Bitmap);
          Png.SaveToFile(TPath.Combine(FDir, Format('filme-%d-%.2d.png', [FFilm, I])));
        end;
      finally Png.Free; Bitmap.Free; end;
    finally Times.Free; Frames.Free; end;
  end
  else
  begin
    PostMessage(FEditor.Handle, WM_MOUSEMOVE, 0, MakeLParam(X, Y));
    PostMessage(FEditor.Handle, WM_LBUTTONDOWN, MK_LBUTTON, MakeLParam(X, Y));
    PostMessage(FEditor.Handle, WM_LBUTTONUP, 0, MakeLParam(X, Y));
  end;
  PumpIdle(1200);
  Note(Format('  clique no sinal da linha %d (x=%d y=%d) | escondidas: %s | eventos: %s', [Line, X, Y, PluginHidden(1, FLines.Count),
    StringReplace(TFoldManager.Instance.TakeLog, sLineBreak, '; ', [rfReplaceAll])]));
end;

// What CnPack asks the editor kernel to find where the text starts: the pixel position
// of column 1 of line 1. Every highlight it draws is placed from this value.
function TProbe.KernelGutter: string;
var Method, Found: TRttiMethod; Position: TOTAEditPos; Argument, Point: TValue; ParamType: TRttiType; X: Integer;
begin
  Found := nil;
  for Method in FCtx.GetType(FEditor.ClassType).GetMethods do
    if SameText(Method.Name, 'PointFromEdPos') and (Length(Method.GetParameters) = 3) then Found := Method;
  if Found = nil then Exit('(PointFromEdPos nao encontrado)');
  ParamType := Found.GetParameters[0].ParamType;
  if ParamType.TypeSize <> SizeOf(TOTAEditPos) then Exit('(TEdPos com tamanho inesperado)');
  Position.Col := 1; Position.Line := 1;
  TValue.Make(@Position, ParamType.Handle, Argument);
  Point := Found.Invoke(FEditor, [Argument, True, True]);
  X := Point.AsType<TPoint>.X;
  Result := Format('X(col 1, linha 1)=%d coluna-esquerda=%d topo=%d cursor=%d,%d', [X, FView.LeftColumn, FView.TopPos.Line,
    FView.CursorPos.Line, FView.CursorPos.Col]);
end;

procedure TProbe.RunCnPack;
var Menu: TMainMenu; I, Line: Integer; Names, Value: string; Registry: TRegistry; Field: TRttiField;

  procedure Look(const Name: string);
  begin
    // A real click on the text, which is what makes CnPack highlight the identifier
    // under the cursor and the begin/end pair around it.
    ClickAt(Line, 10);
    PumpIdle(3000);
    Capture(Name);
    Note(Format('CNPACK | %s | margem: %s | dobras do plugin: %d | escondidas: %s | eventos: %s', [Name, KernelGutter,
      Length(TFoldManager.Instance.Items(FSample)), PluginHidden(1, FLines.Count),
      StringReplace(TFoldManager.Instance.TakeLog, sLineBreak, '; ', [rfReplaceAll])]));
  end;

begin
  Note('== PLUGIN AO LADO DO CNPACK (observado)');
  try
    Menu := (BorlandIDEServices as INTAServices).MainMenu;
    Names := '';
    for I := 0 to Menu.Items.Count - 1 do
      Names := Names + '[' + StringReplace(Menu.Items[I].Caption, '&', '', [rfReplaceAll]) + '] ';
    Note('CNPACK | menu principal: ' + Names);
    Note('CNPACK | CnPack carregado: ' + BoolToStr((GetModuleHandle('CnWizards_D110A.dll') <> 0) or
      (GetModuleHandle('CnWizards_D120A.dll') <> 0) or (Pos('CnPack', Names) > 0), True));
    Value := '(sem valor)';
    Registry := TRegistry.Create(KEY_READ);
    try
      Registry.RootKey := HKEY_CURRENT_USER;
      if Registry.OpenKeyReadOnly((BorlandIDEServices as IOTAServices).GetBaseRegistryKey + '\Editor\Options') and
        Registry.ValueExists('Enable Elisions') then Value := Registry.ReadString('Enable Elisions');
    finally Registry.Free; end;
    Field := FCtx.GetType(FEditor.ClassType).GetField('FElisionGutter');
    Note(Format('CNPACK | opcao do editor "Enable Elisions" no registro: %s | campo FElisionGutter do controle: %s', [Value,
      IfThen(Field = nil, '(nao existe)', Field.GetValue(FEditor).ToString)]));
    Line := Marker('case1-body').Line;
    Look('cn-1-antes-de-dobrar');
    Note('PASSO | menu: dobrar o bloco do if');
    SetCursor(Marker('if-body').Line, 10);
    MenuClick(ToggleItemName);
    Look('cn-2-com-dobra');
    // What the IDE tells a painting plugin about each row, with one fold of the plugin active.
    Note('PASSO | mais duas dobras (else e while) e digitar acima delas');
    SetCursor(Marker('else-body').Line, 10);
    MenuClick(ToggleItemName);
    SetCursor(Marker('while-body').Line, 10);
    MenuClick(ToggleItemName);
    TypeAtEnd(26, ' // texto', 60);
    PumpIdle(2000);
    Line := Marker('case1-body').Line;
    Look('cn-3-tres-dobras-depois-de-digitar');
    TypeAtEnd(26, ' mais', 60);
    PumpIdle(2000);
    Note('PASSO | clicar em outra linha (begin de um ramo do case)');
    Line := Marker('case1-body').Line - 1;
    Look('cn-4-cursor-no-begin');
    Note('PASSO | menu: abrir todas');
    MenuClick(OpenAllItemName);
    Look('cn-5-tudo-aberto');
    Field := FCtx.GetType(FEditor.ClassType).GetField('FElisionGutter');
    if Field <> nil then Note('CNPACK | campo FElisionGutter no fim: ' + Field.GetValue(FEditor).ToString);

    Note('-- sinais - e + desenhados pelo plugin na margem');
    Line := Marker('case1-body').Line;
    Look('sinal-1-tudo-aberto');
    Note('PASSO | clique no sinal do while');
    ClickSign(Marker('while-head').Line);
    Note('PASSO | clique no sinal do if (dobra com o else junto)');
    ClickSign(Marker('if-head').Line);
    Note('PASSO | clique no sinal do try (por cima dos dois)');
    ClickSign(Marker('try-head').Line);
    Line := Marker('case1-body').Line;
    Look('sinal-2-try-dobrado');
    Note('PASSO | clique no sinal do try de novo (abre; os de dentro continuam dobrados)');
    ClickSign(Marker('try-head').Line);
    Look('sinal-3-try-aberto');
    Note('PASSO | clique no sinal do if (abre)');
    ClickSign(Marker('if-head').Line);
    Line := Marker('case1-body').Line - 1;
    Look('sinal-4-if-aberto');
    MenuClick(OpenAllItemName);
    PumpIdle(800);

    Note('-- unit grande, com o cursor longe do topo');
    if not OpenAndBind(GetEnvironmentVariable('BFPROBE_BIG')) then begin Note('CNPACK | a unit grande nao abriu'); Exit; end;
    PumpIdle(3000);
    Note('CNPACK | unit grande aberta | margem: ' + KernelGutter);
    SetCursor(4018, 9);
    PumpIdle(1500);
    Note('CNPACK | cursor na linha 4018 | margem: ' + KernelGutter);
    ClickAt(4040, 12);
    PumpIdle(2500);
    Capture('cn-6-grande-antes');
    Note('CNPACK | clique na linha 4040, antes de dobrar | margem: ' + KernelGutter);
    Note('PASSO | menu: dobrar o bloco da linha 4018');
    SetCursor(4018, 9);
    MenuClick(ToggleItemName);
    PumpIdle(1500);
    Note('CNPACK | depois de dobrar | margem: ' + KernelGutter + ' | eventos: ' +
      StringReplace(TFoldManager.Instance.TakeLog, sLineBreak, '; ', [rfReplaceAll]));
    ClickAt(4040, 12);
    PumpIdle(2500);
    Capture('cn-7-grande-com-dobra');
    Note('CNPACK | clique na linha 4040, com dobra | margem: ' + KernelGutter);
    Note('PASSO | mais duas dobras e digitar acima');
    SetCursor(4022, 9);
    MenuClick(ToggleItemName);
    SetCursor(4050, 9);
    MenuClick(ToggleItemName);
    PumpIdle(1000);
    Note('CNPACK | tres dobras | margem: ' + KernelGutter + ' | eventos: ' +
      StringReplace(TFoldManager.Instance.TakeLog, sLineBreak, '; ', [rfReplaceAll]));
    TypeAtEnd(4012, ' // texto', 60);
    PumpIdle(2500);
    Note('CNPACK | depois de digitar acima | margem: ' + KernelGutter);
    ClickAt(4040, 12);
    PumpIdle(2500);
    Capture('cn-8-grande-depois-de-digitar');
    Note('CNPACK | clique na linha 4040 depois de digitar | margem: ' + KernelGutter);
    ClickAt(4035, 8);
    PumpIdle(2500);
    Capture('cn-9-grande-outro-clique');
    Note('CNPACK | clique na linha 4035 | margem: ' + KernelGutter);
    MenuClick(OpenAllItemName);
    PumpIdle(1500);
    Note('CNPACK | tudo aberto | margem: ' + KernelGutter);
  except
    on E: Exception do Note('EXCECAO | cnpack | ' + E.ClassName + ': ' + E.Message);
  end;
end;

procedure TProbe.CaptureWindow(Window: HWND; const Name: string);
var Bounds: TRect; Bitmap: TBitmap; Png: TPngImage; Desktop: HDC;
begin
  try
    SetWindowPos(Window, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE or SWP_NOSIZE or SWP_NOACTIVATE);
    Sleep(300);
    GetWindowRect(Window, Bounds);
    Bitmap := TBitmap.Create; Png := TPngImage.Create;
    try
      Bitmap.PixelFormat := pf24bit;
      Bitmap.SetSize(Bounds.Width, Bounds.Height);
      Desktop := GetDC(0);
      try
        BitBlt(Bitmap.Canvas.Handle, 0, 0, Bounds.Width, Bounds.Height, Desktop, Bounds.Left, Bounds.Top, SRCCOPY);
      finally ReleaseDC(0, Desktop); end;
      Png.Assign(Bitmap);
      Png.SaveToFile(TPath.Combine(FDir, Name + '.png'));
    finally Png.Free; Bitmap.Free; end;
    SetWindowPos(Window, HWND_NOTOPMOST, 0, 0, 0, 0, SWP_NOMOVE or SWP_NOSIZE or SWP_NOACTIVATE);
  except
  end;
end;

// The IDE under test as the foreground window; real input is only sent while it is.
function TProbe.BringToFront: Boolean;
var Main: HWND;
begin
  Main := Application.MainForm.Handle;
  if GetForegroundWindow <> Main then
  begin
    // Windows only lets a process take the foreground right after input: a tap on Alt counts.
    keybd_event(VK_MENU, 0, 0, 0);
    SetForegroundWindow(Main);
    keybd_event(VK_MENU, 0, KEYEVENTF_KEYUP, 0);
    Pump(300);
  end;
  Result := GetForegroundWindow = Main;
end;

// A unit with a form opens on the form designer: bring its code to the front.
procedure TProbe.ShowCode;
begin
  FView.Buffer.Show;
end;

{ A unit of a real project, in the IDE as the user has it: fold a block in the
  middle of the unit, then click on a begin and on an identifier below it. }

procedure TProbe.RunReal;
var Lines: TStringList; Blocks: TArray<TBlock>; Block, Chosen: TBlock; I, Target, TargetCol, NameLine, NameCol: Integer;
  Text: string; Project: IOTAProject;

  function FirstColumn(Line: Integer): Integer;
  var S: string;
  begin
    S := Lines[Line - 1];
    Result := 1;
    while (Result <= Length(S)) and CharInSet(S[Result], [' ', #9]) do Inc(Result);
  end;

  procedure Shot(const Name, What: string);
  begin
    PumpIdle(2500);
    Capture(Name);
    Note(Format('REAL | %s | %s | margem: %s | dobras do plugin: %d | escondidas no bloco: %s | eventos: %s', [Name, What, KernelGutter,
      Length(TFoldManager.Instance.Items(FSample)), PluginHidden(Chosen.FirstLine, Chosen.LastLine),
      StringReplace(TFoldManager.Instance.TakeLog, sLineBreak, '; ', [rfReplaceAll])]));
  end;

begin
  Note('== UNIT DE UM PROJETO REAL, NA IDE COMO O USUARIO USA (observado)');
  Lines := TStringList.Create;
  try
    PumpIdle(8000);
    ShowCode;
    PumpIdle(2000);
    Project := GetActiveProject;
    Note('REAL | projeto ativo: ' + IfThen(Project = nil, '(nenhum)', ExtractFileName(Project.FileName)) + ' | unit: ' +
      ExtractFileName(FSample));
    Project := nil;
    Lines.Text := BufferText;
    Blocks := FindBlocks(Lines.Text);
    Chosen := Default(TBlock);
    for Block in Blocks do
      if (Block.Kind = bkBegin) and (Block.Depth >= 2) and (Block.FirstLine > 300) and (Block.LastLine - Block.FirstLine >= 4) and
        (Block.LastLine - Block.FirstLine <= 25) and (Chosen.FirstLine = 0) then Chosen := Block;
    if Chosen.FirstLine = 0 then begin Note('REAL | nenhum bloco adequado encontrado'); Exit; end;
    // Below the block: a line that is just "begin", and the line after it for an identifier.
    Target := 0;
    for I := Chosen.LastLine + 2 to Chosen.LastLine + 45 do
      if (I < Lines.Count) and SameText(Trim(Lines[I - 1]), 'begin') and (Target = 0) then Target := I;
    if Target = 0 then begin Note('REAL | nenhuma linha begin abaixo do bloco'); Exit; end;
    TargetCol := FirstColumn(Target) + 2;
    NameLine := Target + 1;
    NameCol := FirstColumn(NameLine) + 2;
    Text := Lines[Chosen.FirstLine - 1];
    CaptureWindow(Application.MainForm.Handle, 'real-0-ide-inteira');
    Note(Format('REAL | editor do teste: visivel=%s tamanho=%dx%d | editores conhecidos: %d | view do topo e a da unit: %s',
      [BoolToStr(IsWindowVisible(FEditor.Handle), True), FEditor.Width, FEditor.Height, FServices.GetKnownEditors.Count,
       BoolToStr((BorlandIDEServices as IOTAEditorServices).TopView.SameView(FView), True)]));
    Note(Format('REAL | unit com %d linhas, %d blocos | bloco escolhido %d..%d [%s] | begin abaixo na linha %d | tem TAB na unit: %s',
      [Lines.Count, Length(Blocks), Chosen.FirstLine, Chosen.LastLine, Trim(Text), Target, BoolToStr(Pos(#9, Lines.Text) > 0, True)]));
    SetCursor(Chosen.FirstLine - 6, 1);
    PumpIdle(2500);
    ClickAt(Target, TargetCol);
    Shot('real-1-antes-clique-no-begin', 'antes de dobrar');
    ClickAt(NameLine, NameCol);
    Shot('real-2-antes-clique-no-identificador', 'antes de dobrar');

    Note('PASSO | dobrar o bloco: clique dentro dele e ' + IfThen(FRealInput, 'atalho Ctrl+Alt+B de verdade', 'comando do menu'));
    if FRealInput then
    begin
      ClickAt(Chosen.FirstLine + 1, FirstColumn(Chosen.FirstLine + 1) + 3);
      PumpIdle(800);
      PressShortcut(Ord('B'), True, True, False);
    end
    else
    begin
      SetCursor(Chosen.FirstLine + 1, FirstColumn(Chosen.FirstLine + 1) + 1);
      PumpIdle(500);
      MenuClick(ToggleItemName);
    end;
    PumpIdle(1500);
    ClickAt(Target, TargetCol);
    Shot('real-3-dobrado-clique-no-begin', 'dobrado pelo menu');
    ClickAt(NameLine, NameCol);
    Shot('real-4-dobrado-clique-no-identificador', 'dobrado pelo menu');
    ClickAt(Chosen.FirstLine - 2, FirstColumn(Chosen.FirstLine - 2) + 2);
    Shot('real-5-dobrado-clique-acima', 'clique acima da dobra');

    Note('PASSO | abrir todas e dobrar de novo pelo atalho Ctrl+Alt+B');
    MenuClick(OpenAllItemName);
    PumpIdle(1000);
    SetCursor(Chosen.FirstLine + 1, FirstColumn(Chosen.FirstLine + 1) + 1);
    PumpIdle(500);
    PressShortcut(Ord('B'), True, True, False);
    PumpIdle(1500);
    ClickAt(Target, TargetCol);
    Shot('real-6-atalho-clique-no-begin', 'dobrado pelo atalho');
    ClickAt(NameLine, NameCol);
    Shot('real-7-atalho-clique-no-identificador', 'dobrado pelo atalho');

    Note('PASSO | abrir todas');
    MenuClick(OpenAllItemName);
    PumpIdle(1000);
    ClickAt(Target, TargetCol);
    Shot('real-8-aberto-clique-no-begin', 'tudo aberto');
  except
    on E: Exception do Note('EXCECAO | projeto real | ' + E.ClassName + ': ' + E.Message);
  end;
  Lines.Free;
end;

procedure TProbe.Run;
begin
  Note('SONDA | inicio ' + FormatDateTime('yyyy-mm-dd hh:nn:ss', Now));
  if not Supports(BorlandIDEServices, INTACodeEditorServices, FServices) then
  begin
    Note('SONDA | INTACodeEditorServices indisponivel nesta IDE');
    Exit;
  end;
  Application.MainForm.WindowState := wsMaximized;
  LoadSample;
  FNotifier := TProbeNotifier.Create;
  FNotifier.OnEditorElided := OnElided;
  FNotifier.OnEditorUnElided := OnUnElided;
  FNotifier.OnEditorPaintLine := OnPaintLine;
  FNotifier.OnEditorBeginPaint := OnBeginPaint;
  FNotifier.OnEditorEndPaint := OnEndPaint;
  // Next to CnPack the plugin must be the only one of ours taking part in the painting, as in a real installation.
  if not SameText(FMode, 'cnpack') and not SameText(FMode, 'real') then
    FNotifierIndex := FServices.AddEditorEventsNotifier(FNotifier);
  if SameText(FMode, 'folddebug') or SameText(FMode, 'plugin') or SameText(FMode, 'real') then
  begin
    (BorlandIDEServices as IOTAActionServices).OpenProject(GetEnvironmentVariable('BFPROBE_PROJECT'), True);
    Pump(4000);
  end;
  if not OpenAndBind(FSample) then
  begin
    Note('SONDA | a unit de exemplo nao abriu no editor');
    Exit;
  end;
  Pump(1500);
  RunEnvironment;
  if SameText(FMode, 'layout') then
  begin
    RunLayout;
    Exit;
  end;
  if SameText(FMode, 'folddebug') then
  begin
    RunFoldDebug;
    Exit;
  end;
  if SameText(FMode, 'foldkeep') then
  begin
    RunFoldKeep;
    Exit;
  end;
  if SameText(FMode, 'cnpack') then
  begin
    RunCnPack;
    Exit;
  end;
  if SameText(FMode, 'real') then
  begin
    RunReal;
    Exit;
  end;
  if SameText(FMode, 'foldnest') then
  begin
    RunFoldNest;
    Exit;
  end;
  if SameText(FMode, 'plugin') then
  begin
    RunPluginSettings;
    RunPlugin;
    RunPluginSecondUnit;
    RunPluginReopen;
    RunPluginDebug;
    RunPluginBig;
    Exit;
  end;
  if SameText(FMode, 'foldmulti') then
  begin
    RunFoldMulti;
    RunFoldViews;
    RunFoldBig;
    Exit;
  end;
  if SameText(FMode, 'fold') or SameText(FMode, 'foldrisk') then
  begin
    RunRegionsOfView;
    RunFold;
    if SameText(FMode, 'fold') then RunFoldReopen;
    Exit;
  end;
  RunRegionsOfView;
  try RunNearestBlock; except on E: Exception do Note('EXCECAO | pergunta 1 | ' + E.ClassName + ': ' + E.Message); end;
  try RunPainting; except on E: Exception do Note('EXCECAO | pergunta 5 | ' + E.ClassName + ': ' + E.Message); end;
  try RunRtti; except on E: Exception do Note('EXCECAO | pergunta 2 | ' + E.ClassName + ': ' + E.Message); end;
  try RunHighlighter; except on E: Exception do Note('EXCECAO | pergunta 4 | ' + E.ClassName + ': ' + E.Message); end;
end;

procedure Register;
var ReportFile: string;
begin
  ReportFile := GetEnvironmentVariable('BFPROBE_REPORT');
  if (ReportFile <> '') and (Probe = nil) then Probe := TProbe.Create(ReportFile);
end;

initialization

finalization
  FreeAndNil(Probe);

end.
