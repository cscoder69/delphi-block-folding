unit BlockFolding.Engine;

// Folds a range of lines in the IDE's code editor. The ToolsAPI has no call for
// this, so the public methods of the editor control are reached through RTTI:
// nothing is hooked or patched. The methods and the layout of their arguments
// are checked once per editor class; when they are not what is expected here
// the engine reports itself as unsupported and never calls anything.

interface

uses Vcl.Controls;

type
  TFoldEngine = class
  public
    // False, with the reason, when this IDE's editor cannot be driven safely.
    class function Supported(Editor: TWinControl; out Reason: string): Boolean;
    // True when a foldable block (of the IDE or ours) starts on the line.
    class function BlockStartsAt(Editor: TWinControl; Line: Integer): Boolean;
    class function LineHidden(Editor: TWinControl; Line: Integer): Boolean;
    // Makes First..Last a foldable block. The lengths are those of the two lines.
    class procedure RegisterBlock(Editor: TWinControl; First, FirstLength, Last, LastLength: Integer);
    class procedure Collapse(Editor: TWinControl; First, FirstLength, Last, LastLength: Integer);
    // Makes First..Last stop being a foldable block.
    class procedure RemoveBlock(Editor: TWinControl; First, FirstLength, Last, LastLength: Integer);
    // Opens the block that starts on the line.
    class procedure Open(Editor: TWinControl; Line: Integer);
    // Text the editor shows after the first line of a block folded from now on.
    class procedure SetMarker(const Text: AnsiString);
    // For diagnosis: where the editor says column 1 of line 1 is, in pixels, and the
    // width of its folding gutter. -1 when it cannot be read. Nothing is changed.
    class function TextOriginX(Editor: TWinControl): Integer;
    class function FoldGutterWidth(Editor: TWinControl): Integer;
  end;

implementation

uses System.SysUtils, System.Types, System.Rtti, System.TypInfo, System.Generics.Collections, ToolsAPI;

type
  // Ek.TCharPos and Ek.TElisionDescription as the editor kernel declares them.
  TKernelCharPos = packed record
    Index: SmallInt;
    LineNum: Integer;
  end;

  TKernelElisionDescription = packed record
    ElisionType: Word;
    DescLen: Integer;
    BlockDesc: PAnsiChar;
  end;

  TEditorMethods = record
    Valid: Boolean;
    Reason: string;
    Add, Elide, UnElideLine, IsStart, IsHidden, Remove: TRttiMethod;
    PositionType, DescriptionType: PTypeInfo;
  end;

const
  RegionKind = 0;

var
  // Kept alive here: the editor is handed a pointer to it.
  Description: AnsiString = '...';
  Context: TRttiContext;
  Known: TDictionary<TClass, TEditorMethods>;

function FieldAt(RttiType: TRttiType; const Name: string; Offset: Integer): Boolean;
var Field: TRttiField;
begin
  Field := RttiType.GetField(Name);
  Result := (Field <> nil) and (Field.Offset = Offset);
end;

function MethodsOf(Editor: TWinControl): TEditorMethods;
var Method: TRttiMethod; Params: TArray<TRttiParameter>; Position, Desc: TRttiType;
begin
  if Known.TryGetValue(Editor.ClassType, Result) then Exit;
  Result := Default(TEditorMethods);
  for Method in Context.GetType(Editor.ClassType).GetMethods do
  begin
    Params := Method.GetParameters;
    if SameText(Method.Name, 'AddElisionBlock') and (Length(Params) = 3) then Result.Add := Method
    else if (Method.Name = 'Elide') and (Length(Params) = 3) and (Params[0].ParamType <> nil) and
      (Params[0].ParamType.TypeKind = tkRecord) then Result.Elide := Method
    else if SameText(Method.Name, 'UnElide') and (Length(Params) = 1) and (Params[0].ParamType <> nil) and
      (Params[0].ParamType.TypeKind = tkInteger) then Result.UnElideLine := Method
    else if SameText(Method.Name, 'RemoveElisionBlock') and (Length(Params) = 2) then Result.Remove := Method
    else if SameText(Method.Name, 'IsStartOfElisionBlock') and (Length(Params) = 1) then Result.IsStart := Method
    else if SameText(Method.Name, 'LineIsElided') and (Length(Params) = 1) then Result.IsHidden := Method;
  end;
  if (Result.Add = nil) or (Result.Remove = nil) or (Result.Elide = nil) or (Result.UnElideLine = nil) or (Result.IsStart = nil) or
    (Result.IsHidden = nil) then
    Result.Reason := 'the editor control of this IDE does not have the expected folding methods'
  else
  begin
    Position := Result.Add.GetParameters[0].ParamType;
    Desc := Result.Add.GetParameters[2].ParamType;
    if (Position = nil) or (Position.TypeSize <> SizeOf(TKernelCharPos)) or not FieldAt(Position, 'Index', 0) or
      not FieldAt(Position, 'LineNum', 2) then
      Result.Reason := 'TCharPos does not have the expected layout in this IDE'
    else if (Desc = nil) or (Desc.TypeSize <> SizeOf(TKernelElisionDescription)) or not FieldAt(Desc, 'ElisionType', 0) or
      not FieldAt(Desc, 'DescLen', 2) or not FieldAt(Desc, 'BlockDesc', 6) then
      Result.Reason := 'TElisionDescription does not have the expected layout in this IDE'
    else if Result.Elide.GetParameters[0].ParamType <> Position then
      Result.Reason := 'Elide does not take the expected arguments in this IDE'
    else
    begin
      Result.PositionType := Position.Handle;
      Result.DescriptionType := Desc.Handle;
      Result.Valid := True;
    end;
  end;
  Known.Add(Editor.ClassType, Result);
end;

function Checked(Editor: TWinControl): TEditorMethods;
begin
  Result := MethodsOf(Editor);
  if not Result.Valid then raise ENotSupportedException.Create('Block folding: ' + Result.Reason);
end;

function PositionValue(const Methods: TEditorMethods; Index, Line: Integer): TValue;
var Position: TKernelCharPos;
begin
  Position.Index := Index; Position.LineNum := Line;
  TValue.Make(@Position, Methods.PositionType, Result);
end;

class function TFoldEngine.Supported(Editor: TWinControl; out Reason: string): Boolean;
var Methods: TEditorMethods;
begin
  if Editor = nil then begin Reason := 'no editor'; Exit(False); end;
  Methods := MethodsOf(Editor);
  Reason := Methods.Reason;
  Result := Methods.Valid;
end;

class function TFoldEngine.BlockStartsAt(Editor: TWinControl; Line: Integer): Boolean;
begin
  Result := Checked(Editor).IsStart.Invoke(Editor, [Line]).AsBoolean;
end;

class function TFoldEngine.LineHidden(Editor: TWinControl; Line: Integer): Boolean;
begin
  Result := Checked(Editor).IsHidden.Invoke(Editor, [Line]).AsBoolean;
end;

class procedure TFoldEngine.RegisterBlock(Editor: TWinControl; First, FirstLength, Last, LastLength: Integer);
var Methods: TEditorMethods; Desc: TKernelElisionDescription; DescValue: TValue;
begin
  Methods := Checked(Editor);
  Desc.ElisionType := RegionKind;
  Desc.DescLen := Length(Description);
  Desc.BlockDesc := PAnsiChar(Description);
  TValue.Make(@Desc, Methods.DescriptionType, DescValue);
  Methods.Add.Invoke(Editor, [PositionValue(Methods, FirstLength, First), PositionValue(Methods, LastLength, Last), DescValue]);
end;

class procedure TFoldEngine.Collapse(Editor: TWinControl; First, FirstLength, Last, LastLength: Integer);
var Methods: TEditorMethods;
begin
  Methods := Checked(Editor);
  Methods.Elide.Invoke(Editor, [PositionValue(Methods, FirstLength, First), PositionValue(Methods, LastLength, Last), False]);
end;

class procedure TFoldEngine.RemoveBlock(Editor: TWinControl; First, FirstLength, Last, LastLength: Integer);
var Methods: TEditorMethods;
begin
  Methods := Checked(Editor);
  Methods.Remove.Invoke(Editor, [PositionValue(Methods, FirstLength, First), PositionValue(Methods, LastLength, Last)]);
end;

class procedure TFoldEngine.Open(Editor: TWinControl; Line: Integer);
begin
  Checked(Editor).UnElideLine.Invoke(Editor, [Line]);
end;

class function TFoldEngine.TextOriginX(Editor: TWinControl): Integer;
var Method, Found: TRttiMethod; Position: TOTAEditPos; Argument: TValue; ParamType: TRttiType;
begin
  Result := -1;
  try
    Found := nil;
    for Method in Context.GetType(Editor.ClassType).GetMethods do
      if SameText(Method.Name, 'PointFromEdPos') and (Length(Method.GetParameters) = 3) then Found := Method;
    if Found = nil then Exit;
    ParamType := Found.GetParameters[0].ParamType;
    if (ParamType = nil) or (ParamType.TypeSize <> SizeOf(TOTAEditPos)) then Exit;
    Position.Col := 1; Position.Line := 1;
    TValue.Make(@Position, ParamType.Handle, Argument);
    Result := Found.Invoke(Editor, [Argument, True, True]).AsType<TPoint>.X;
  except
    Result := -1;
  end;
end;

class function TFoldEngine.FoldGutterWidth(Editor: TWinControl): Integer;
var Field: TRttiField;
begin
  Result := -1;
  try
    Field := Context.GetType(Editor.ClassType).GetField('FElisionGutter');
    if Field <> nil then Result := Field.GetValue(Editor).AsInteger;
  except
    Result := -1;
  end;
end;

class procedure TFoldEngine.SetMarker(const Text: AnsiString);
begin
  Description := Text;
  UniqueString(Description);
end;

initialization
  Context := TRttiContext.Create;
  Known := TDictionary<TClass, TEditorMethods>.Create;

finalization
  Known.Free;
  Context.Free;

end.
