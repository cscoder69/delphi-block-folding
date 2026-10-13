unit Sample2;

interface

procedure Work(A: Integer);

implementation

procedure Work(A: Integer);
var
  I, X: Integer;
begin
  X := 0;
  if A > 0 then //@stmt-if
    X := X +
      A +
      1
  else //@stmt-else
    X := X -
      A;
  for I := 0 to A do //@stmt-for
    if I > 2 then //@stmt-inner
      X := X + 1;
  while X > 100 do //@stmt-while
    X := X div
      2;
  with TObject.Create do
    Free;
  if X = 1 then X := 2;
end;

procedure Regions(A: Integer);
var
  X: Integer;
begin
  X := 0;
  if A > 0 then
  begin //@reg-outer
    X := 1;
    {$REGION 'dentro'}
    X := 2;
    X := 3;
    {$ENDREGION}
    X := 4;
  end;
end;

end.
