unit Sample;

interface

type
  TDemo = class
  public
    procedure Run(A: Integer);
    function Calc(A: Integer): Integer;
  end;

implementation

{ TDemo }

procedure TDemo.Run(A: Integer);
var
  I, X: Integer;

  procedure Nested;
  begin
    X := -1; //@nested-body
  end;

begin
  X := 0; //@method-body
  try //@try-head
    for I := 0 to A do //@for-head
    begin //@for-begin
      if I > 3 then //@if-head
      begin //@if-begin
        X := X + I; //@if-body
        X := X * 2;
      end
      else
      begin
        X := X - 1; //@else-body
      end;
      while X > 100 do //@while-head
      begin
        X := X div 2; //@while-body
      end;
    end; //@for-end
  finally
    X := 0; //@finally-body
  end;
  {$REGION 'reg'}
  X := 5; //@region-body
  X := 6;
  {$ENDREGION}
  {$IFDEF DEBUG}
  X := 7; //@ifdef-body
  {$ENDIF}
end;

function TDemo.Calc(A: Integer): Integer;
begin
  case A of //@case-head
    1:
      begin
        Result := 10; //@case1-body
        Result := Result + 1;
      end;
    2:
      begin
        Result := 20; //@case2-body
      end;
  else
    Result := 0; //@case-else
  end;
end;

end.
