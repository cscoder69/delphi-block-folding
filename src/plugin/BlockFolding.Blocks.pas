unit BlockFolding.Blocks;

// Finds what can be folded in a Delphi unit, when it spans more than one line:
//
// - a statement, from the line of its if / for / while / with / on to its last
//   line; for an if that includes the else part, which is also found on its own
//   when "else" starts a line;
// - the blocks begin..end, try..end, case..end, repeat..until and asm..end.
//
// It only reads the text. Comments, strings and compiler directives are skipped,
// and the "end" of record and class declarations is told apart from the end of
// a block.

interface

type
  TBlockKind = (bkBegin, bkTry, bkCase, bkRepeat, bkAsm, bkStatement);

  TBlock = record
    Kind: TBlockKind;
    // 1-based lines. For a block: the opening keyword and the closing end/until.
    // For a statement: the line of its keyword and its last line.
    FirstLine, LastLine: Integer;
    // 0 for the body of a routine, 1 for what is directly inside it, and so on.
    Depth: Integer;
  end;

// Sorted by first line; of two that start on the same line the longer comes first.
function FindBlocks(const Source: string): TArray<TBlock>;
function BlockKindName(Kind: TBlockKind): string;

implementation

uses System.SysUtils, System.Generics.Collections, System.Generics.Defaults;

type
  TOpenKind = (okBegin, okTry, okCase, okRepeat, okAsm, okType);

  TOpen = record
    Kind: TOpenKind;
    Line: Integer;
  end;

  // A statement being read: "if ... then S [else S]" or "for/while/with/on ... do S".
  TPhase = (phCondition, phWaitBody, phSimpleBody, phBlockBody, phNestedBody, phAfterBody);

  TFrame = record
    IsIf: Boolean;
    StartLine: Integer;
    Phase: TPhase;
    // Open blocks when the body started; the body is over when a block body is
    // back to this, and a simple body ends on a semicolon at this level.
    BodyDepth: Integer;
    // Last line of what was read so far.
    EndLine: Integer;
    // Line of an "else" that starts its line, 0 when there is none.
    ElseLine: Integer;
    // Open blocks when the statement started: one left unfinished inside a block
    // that closes is dropped.
    OpenDepth: Integer;
  end;

function BlockKindName(Kind: TBlockKind): string;
const Names: array[TBlockKind] of string = ('begin', 'try', 'case', 'repeat', 'asm', 'statement');
begin
  Result := Names[Kind];
end;

function FindBlocks(const Source: string): TArray<TBlock>;
var
  Position, Line, Size, Paren, LastTokenLine: Integer;
  Stack: TList<TOpen>;
  Frames: TList<TFrame>;
  Found: TList<TBlock>;
  Previous, Word: string;
  FirstOnLine: Boolean;

  function IsNameChar(Character: Char): Boolean;
  begin
    Result := CharInSet(Character, ['A'..'Z', 'a'..'z', '0'..'9', '_']) or (Character > #127);
  end;

  function BlockDepth: Integer;
  var I: Integer;
  begin
    Result := 0;
    for I := 0 to Stack.Count - 1 do
      if Stack[I].Kind <> okType then Inc(Result);
  end;

  procedure Emit(Kind: TBlockKind; First, Last, Depth: Integer);
  var Block: TBlock; I: Integer;
  begin
    if Last <= First then Exit;
    for I := Found.Count - 1 downto 0 do
      if (Found[I].Kind = Kind) and (Found[I].FirstLine = First) and (Found[I].LastLine = Last) then Exit;
    Block.Kind := Kind;
    Block.FirstLine := First;
    Block.LastLine := Last;
    Block.Depth := Depth;
    Found.Add(Block);
  end;

  procedure Push(Kind: TOpenKind);
  var Item: TOpen;
  begin
    Item.Kind := Kind; Item.Line := Line;
    Stack.Add(Item);
  end;

  function TopKind: Integer;
  begin
    if Stack.Count = 0 then Result := -1 else Result := Ord(Stack.Last.Kind);
  end;

  procedure SetTop(const Frame: TFrame);
  begin
    Frames[Frames.Count - 1] := Frame;
  end;

  // The body of the top statement ended on EndLine.
  procedure BodyEnded(EndLine: Integer);
  var Frame: TFrame;
  begin
    Frame := Frames.Last;
    Frame.EndLine := EndLine;
    Frame.Phase := phAfterBody;
    SetTop(Frame);
  end;

  // The top statement is complete: it is recorded, and the statement around it,
  // when this one was its whole body, has its body ended too.
  procedure Complete;
  var Frame, Outer: TFrame; Depth: Integer;
  begin
    Frame := Frames.Last;
    Frames.Delete(Frames.Count - 1);
    Depth := BlockDepth;
    Emit(bkStatement, Frame.StartLine, Frame.EndLine, Depth);
    if Frame.ElseLine > Frame.StartLine then Emit(bkStatement, Frame.ElseLine, Frame.EndLine, Depth);
    if Frames.Count > 0 then
    begin
      Outer := Frames.Last;
      if Outer.Phase = phNestedBody then BodyEnded(Frame.EndLine);
    end;
  end;

  // Every token goes through here before it opens or closes a block.
  procedure Statement(const Token: string; IsWord: Boolean);
  var Frame: TFrame; Again, Closer: Boolean;
  begin
    if Token = '(' then Inc(Paren)
    else if Token = '[' then Inc(Paren)
    else if ((Token = ')') or (Token = ']')) and (Paren > 0) then Dec(Paren);
    Closer := IsWord and ((Token = 'end') or (Token = 'until') or (Token = 'finally') or (Token = 'except'));
    repeat
      Again := False;
      if Frames.Count = 0 then Break;
      Frame := Frames.Last;
      case Frame.Phase of
        phWaitBody:
          begin
            if IsWord and ((Token = 'begin') or (Token = 'try') or (Token = 'case') or (Token = 'repeat') or (Token = 'asm')) then
            begin
              Frame.Phase := phBlockBody;
              Frame.BodyDepth := Stack.Count;
              SetTop(Frame);
            end
            else if IsWord and ((Token = 'if') or (Token = 'for') or (Token = 'while') or (Token = 'with')) then
            begin
              // The statement that follows is the whole body; it is opened below.
              Frame.Phase := phNestedBody;
              SetTop(Frame);
            end
            else if (Token = ';') or Closer or (IsWord and (Token = 'else')) then
            begin
              // An empty body.
              BodyEnded(LastTokenLine);
              Again := True;
            end
            else
            begin
              Frame.Phase := phSimpleBody;
              Frame.BodyDepth := Stack.Count;
              SetTop(Frame);
            end;
          end;
        phSimpleBody:
          if Stack.Count = Frame.BodyDepth then
          begin
            if (Token = ';') and (Paren = 0) then
            begin
              BodyEnded(Line);
              Again := True;
            end
            else if Closer or (IsWord and (Token = 'else')) then
            begin
              BodyEnded(LastTokenLine);
              Again := True;
            end;
          end;
        phAfterBody:
          begin
            if Frame.IsIf and IsWord and (Token = 'else') then
            begin
              // The else part of this if. It folds on its own only when it starts a line.
              if FirstOnLine and (Frame.ElseLine = 0) then Frame.ElseLine := Line;
              Frame.Phase := phWaitBody;
              Frame.EndLine := Line;
              SetTop(Frame);
              Exit;
            end;
            Complete;
            Again := True;
          end;
      end;
    until not Again;
    // A new statement opens.
    if IsWord then
    begin
      if (Token = 'if') or (Token = 'for') or (Token = 'while') or (Token = 'with') or (Token = 'on') then
      begin
        // "on" only opens one inside the except part of a try.
        if (Token <> 'on') or (TopKind = Ord(okTry)) then
        begin
          Frame := Default(TFrame);
          Frame.IsIf := Token = 'if';
          Frame.StartLine := Line;
          Frame.Phase := phCondition;
          Frame.EndLine := Line;
          Frame.OpenDepth := Stack.Count;
          Frames.Add(Frame);
        end;
      end
      else if ((Token = 'then') or (Token = 'do')) and (Frames.Count > 0) then
      begin
        Frame := Frames.Last;
        if (Frame.Phase = phCondition) and (Frame.IsIf = (Token = 'then')) then
        begin
          Frame.Phase := phWaitBody;
          Frame.EndLine := Line;
          SetTop(Frame);
        end;
      end;
    end;
  end;

  // A block closed: the statement whose body it was has its body ended.
  procedure BlockClosed;
  var Frame: TFrame;
  begin
    if Frames.Count = 0 then Exit;
    Frame := Frames.Last;
    if (Frame.Phase = phBlockBody) and (Stack.Count = Frame.BodyDepth) then BodyEnded(Line);
  end;

  procedure Pop;
  const Kinds: array[okBegin..okAsm] of TBlockKind = (bkBegin, bkTry, bkCase, bkRepeat, bkAsm);
  var Item: TOpen;
  begin
    if Stack.Count = 0 then Exit;
    Item := Stack.Last;
    Stack.Delete(Stack.Count - 1);
    // A statement that started inside the block that closes and is still open can never complete.
    while (Frames.Count > 0) and (Frames.Last.OpenDepth > Stack.Count) do
      Frames.Delete(Frames.Count - 1);
    if Item.Kind <> okType then Emit(Kinds[Item.Kind], Item.Line, Line, BlockDepth);
    BlockClosed;
  end;

  // What follows a class/interface keyword, after an optional ancestor list:
  // ';' means a declaration without a body, and 'of' a class reference type.
  function DeclarationHasBody: Boolean;
  var Ahead, Depth: Integer; Next: string;
  begin
    Ahead := Position;
    while (Ahead <= Size) and CharInSet(Source[Ahead], [' ', #9, #13, #10]) do Inc(Ahead);
    if (Ahead <= Size) and (Source[Ahead] = '(') then
    begin
      Depth := 0;
      repeat
        if Source[Ahead] = '(' then Inc(Depth) else if Source[Ahead] = ')' then Dec(Depth);
        Inc(Ahead);
      until (Depth = 0) or (Ahead > Size);
      while (Ahead <= Size) and CharInSet(Source[Ahead], [' ', #9, #13, #10]) do Inc(Ahead);
    end;
    if Ahead > Size then Exit(False);
    if Source[Ahead] = ';' then Exit(False);
    Next := '';
    while (Ahead <= Size) and IsNameChar(Source[Ahead]) do
    begin
      Next := Next + Source[Ahead];
      Inc(Ahead);
    end;
    Result := not SameText(Next, 'of');
  end;

  procedure SkipString;
  var Start: Integer;
  begin
    // A multi-line string opens with three quotes at the end of a line.
    if (Position + 2 <= Size) and (Source[Position + 1] = '''') and (Source[Position + 2] = '''') and
      ((Position + 3 > Size) or CharInSet(Source[Position + 3], [#13, #10])) then
    begin
      Inc(Position, 3);
      while Position <= Size do
      begin
        if Source[Position] = #10 then
        begin
          Inc(Line);
          Start := Position + 1;
          while (Start <= Size) and CharInSet(Source[Start], [' ', #9]) do Inc(Start);
          if (Start + 2 <= Size) and (Source[Start] = '''') and (Source[Start + 1] = '''') and (Source[Start + 2] = '''') then
          begin
            Position := Start + 3;
            Exit;
          end;
        end;
        Inc(Position);
      end;
      Exit;
    end;
    Inc(Position);
    while Position <= Size do
    begin
      if Source[Position] = '''' then
      begin
        if (Position < Size) and (Source[Position + 1] = '''') then Inc(Position, 2)
        else begin Inc(Position); Exit; end;
      end
      else if CharInSet(Source[Position], [#13, #10]) then Exit
      else Inc(Position);
    end;
  end;

  // A token was read: the statements see it, then it is remembered.
  procedure Token(const Text: string; IsWord: Boolean);
  begin
    Statement(Text, IsWord);
    LastTokenLine := Line;
    FirstOnLine := False;
  end;

begin
  Stack := TList<TOpen>.Create;
  Frames := TList<TFrame>.Create;
  Found := TList<TBlock>.Create;
  try
    Position := 1; Line := 1; Size := Length(Source); Previous := '';
    Paren := 0; LastTokenLine := 1; FirstOnLine := True;
    while Position <= Size do
    begin
      case Source[Position] of
        #10: begin Inc(Line); Inc(Position); FirstOnLine := True; end;
        #13, ' ', #9: Inc(Position);
        '''': begin Token('''', False); SkipString; Previous := ''''; end;
        '{':
          begin
            while (Position <= Size) and (Source[Position] <> '}') do
            begin
              if Source[Position] = #10 then Inc(Line);
              Inc(Position);
            end;
            Inc(Position);
          end;
        '/':
          if (Position < Size) and (Source[Position + 1] = '/') then
            while (Position <= Size) and (Source[Position] <> #10) do Inc(Position)
          else begin Token('/', False); Previous := '/'; Inc(Position); end;
        '(':
          if (Position < Size) and (Source[Position + 1] = '*') then
          begin
            Inc(Position, 2);
            while (Position < Size) and not ((Source[Position] = '*') and (Source[Position + 1] = ')')) do
            begin
              if Source[Position] = #10 then Inc(Line);
              Inc(Position);
            end;
            Inc(Position, 2);
          end
          else begin Token('(', False); Previous := '('; Inc(Position); end;
        '&':
          begin
            // An escaped identifier is never a keyword.
            Inc(Position);
            while (Position <= Size) and IsNameChar(Source[Position]) do Inc(Position);
            Token('&', False);
            Previous := '&';
          end;
      else
        if IsNameChar(Source[Position]) then
        begin
          Word := '';
          while (Position <= Size) and IsNameChar(Source[Position]) do
          begin
            Word := Word + Source[Position];
            Inc(Position);
          end;
          Word := LowerCase(Word);
          // A keyword after a dot is a member name, as in Something.End.
          Token(Word, Previous <> '.');
          if Previous <> '.' then
          begin
            if Word = 'begin' then Push(okBegin)
            else if Word = 'try' then Push(okTry)
            else if Word = 'asm' then Push(okAsm)
            else if Word = 'repeat' then Push(okRepeat)
            else if Word = 'case' then
            begin
              // The variant part of a record has no end of its own.
              if TopKind <> Ord(okType) then Push(okCase);
            end
            else if Word = 'record' then Push(okType)
            else if (Word = 'class') or (Word = 'interface') or (Word = 'object') or (Word = 'dispinterface') then
            begin
              if ((Previous = '=') or (Previous = 'packed')) and DeclarationHasBody then Push(okType);
            end
            else if Word = 'until' then
            begin
              if TopKind = Ord(okRepeat) then Pop;
            end
            else if Word = 'end' then Pop;
          end;
          Previous := Word;
        end
        else
        begin
          Token(Source[Position], False);
          Previous := Source[Position];
          Inc(Position);
        end;
      end;
    end;
    Found.Sort(TComparer<TBlock>.Construct(
      function(const A, B: TBlock): Integer
      begin
        Result := A.FirstLine - B.FirstLine;
        if Result = 0 then Result := B.LastLine - A.LastLine;
        // The statement before the block that is its body.
        if Result = 0 then Result := Ord(B.Kind) - Ord(A.Kind);
      end));
    Result := Found.ToArray;
  finally
    Found.Free; Frames.Free; Stack.Free;
  end;
end;

end.
